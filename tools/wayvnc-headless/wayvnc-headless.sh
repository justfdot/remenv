#!/usr/bin/env bash
# wayvnc-headless — headless Wayland-вывод + wayvnc для графического
# доступа к хосту по VNC.
#
# Сценарии:
#   * Hyprland: создаёт виртуальный headless output через
#     `hyprctl output create headless`. Работает на живой сессии.
#     Для запуска с нуля нужен GPU/seat — headless-бэкенда у Hyprland нет.
#   * wlroots (sway/labwc/cage/umbriel/...): запускает композитор с
#     WLR_BACKENDS=headless и цепляет wayvnc к HEADLESS-1.
#
# Использование:
#   wayvnc-headless start [опции]
#   wayvnc-headless stop
#   wayvnc-headless status
#
# Опции start:
#   --backend auto|hyprland|wlroots   бэкенд (по умолчанию auto)
#   --compositor CMD                  композитор для wlroots-режима
#                                     (по умолчанию sway → labwc → cage → umbriel)
#   --output NAME                     имя headless-вывода
#   --mode WxH@R                      режим вывода, напр. 1920x1080@60 (hyprland)
#   --port N                          порт VNC (по умолчанию 5900)
#   --bind ADDR                       адрес прослушивания (0.0.0.0)
#   --fps N                           лимит fps wayvnc (30)
#   --desktop NAME                    имя desktop в VNC (по умолчанию hostname)
#   --no-input                        отключить ввод (wayvnc -d)
#   --attach-only                     не создавать headless-вывод,
#                                     wayvnc подключится к существующему
#   --keep-output                     при stop не удалять headless-вывод
set -euo pipefail

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/wayvnc-headless"
COMP_PID_FILE="$STATE_DIR/compositor.pid"
VNC_PID_FILE="$STATE_DIR/wayvnc.pid"
OUT_FILE="$STATE_DIR/output"
LOG_DIR="$STATE_DIR/logs"

BACKEND="auto"
COMPOSITOR=""
OUTPUT=""
MODE=""
PORT="5900"
BIND="0.0.0.0"
FPS="30"
DESKTOP="$(hostname 2>/dev/null || echo wayland)"
WAYVNC_EXTRA=()
ATTACH_ONLY=0
KEEP_OUTPUT=0
SPAWNED_COMPOSITOR=0

log()  { printf '\033[1;34m[wayvnc-headless]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[wayvnc-headless]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[wayvnc-headless]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;/^$/d;$d'; exit "${1:-0}"; }

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
read_pid()  { [ -f "$1" ] && cat "$1" || true; }

# --- обнаружение окружения -----------------------------------------------

hyprland_instances() {
  # signature'ы живых экземпляров hyprland: $XDG_RUNTIME_DIR/hypr/<sig>/
  ls -d "${XDG_RUNTIME_DIR}"/hypr/*/ 2>/dev/null | xargs -r -n1 basename
}

hyprland_running() {
  [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && return 0
  hyprland_instances | grep -q .
}

hypr_env() {
  # выставить HYPRLAND_INSTANCE_SIGNATURE на последний запущенный экземпляр
  local his
  his="$(hyprland_instances | tail -1)"
  [ -n "$his" ] && export HYPRLAND_INSTANCE_SIGNATURE="$his"
}

hypr_wayland_socket() {
  # wayland-сокет экземпляра hyprland: сначала внутри hypr/<sig>/, затем top-level
  local his dir sock
  his="${HYPRLAND_INSTANCE_SIGNATURE:-$(hyprland_instances | tail -1)}"
  dir="${XDG_RUNTIME_DIR}/hypr/$his"
  sock="$(ls "$dir"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1 | xargs -r -n1 basename)"
  [ -n "$sock" ] && { echo "$sock"; return; }
  # fallback: самый свежий top-level сокет
  ls -t "${XDG_RUNTIME_DIR}"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1 | xargs -r -n1 basename
}

newest_wayland_socket() {
  ls -t "${XDG_RUNTIME_DIR}"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1 | xargs -r -n1 basename
}

pick_compositor() {
  if [ -n "$COMPOSITOR" ]; then
    command -v "$COMPOSITOR" >/dev/null || die "compositor not found: $COMPOSITOR"
    echo "$COMPOSITOR"; return
  fi
  local c
  for c in sway labwc cage umbriel; do
    command -v "$c" >/dev/null && { echo "$c"; return; }
  done
  die "no wlroots compositor found (sway/labwc/cage/umbriel) — pass --compositor"
}

detect_backend() {
  case "$BACKEND" in
    hyprland|wlroots) echo "$BACKEND"; return ;;
  esac
  if hyprland_running; then echo hyprland; return; fi
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then echo wlroots; return; fi
  if command -v hyprland >/dev/null; then echo hyprland; else echo wlroots; fi
}

# --- hyprland ---------------------------------------------------------------

hypr_headless_outputs() {
  hyprctl monitors -j 2>/dev/null | python3 -c '
import json,sys
try: ms=json.load(sys.stdin)
except Exception: sys.exit(0)
for m in ms:
    if str(m.get("name","")).startswith("HEADLESS") or m.get("backend","")=="headless":
        print(m["name"])
' 2>/dev/null
}

hypr_ensure_output() {
  local name="${OUTPUT:-HEADLESS-1}"
  if [ -z "$OUTPUT" ]; then
    local existing
    existing="$(hypr_headless_outputs | head -1)"
    [ -n "$existing" ] && { echo "$existing"; return; }
  fi
  if [ -n "$MODE" ]; then
    hyprctl output create headless "$name" "$MODE" >/dev/null 2>&1 || \
    hyprctl output create headless "$name" >/dev/null 2>&1 || true
  else
    hyprctl output create headless "$name" >/dev/null 2>&1 || true
  fi
  sleep 0.3
  hyprctl monitors -j 2>/dev/null | python3 -c '
import json,sys
name=sys.argv[1]
try: ms=json.load(sys.stdin)
except Exception: sys.exit(1)
for m in ms:
    if m.get("name")==name: print(name); sys.exit(0)
sys.exit(1)
' "$name" 2>/dev/null || die "failed to create/find headless output $name"
}

hypr_spawn_session() {
  # У Hyprland нет headless-бэкенда: запускаем обычный экземпляр.
  # Нужен GPU/DRM + seat (logind) — на машине без GPU используйте
  # wlroots-бэкенд или запустите Hyprland внутри другой сессии.
  log "starting Hyprland (нужен GPU/seat; headless-выводы добавим после)"
  setsid hyprland >>"$LOG_DIR/hyprland.log" 2>&1 &
  echo $! > "$COMP_PID_FILE"
  SPAWNED_COMPOSITOR=1
  local i
  for i in $(seq 1 50); do
    hypr_env
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && hyprctl monitors >/dev/null 2>&1 && break
    sleep 0.2
  done
  hypr_env
  [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || \
    die "hyprland did not start (see $LOG_DIR/hyprland.log)"
}

# --- wlroots -------------------------------------------------------------------

wlroots_spawn_session() {
  local comp; comp="$(pick_compositor)"
  # запоминаем существующие сокеты — ищем только НОВЫЙ
  local before; before="$(ls "${XDG_RUNTIME_DIR}"/wayland-* 2>/dev/null | grep -v '\.lock$')"
  log "starting headless $comp (WLR_BACKENDS=headless)"
  setsid env WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 "$comp" \
      >>"$LOG_DIR/compositor.log" 2>&1 &
  echo $! > "$COMP_PID_FILE"
  SPAWNED_COMPOSITOR=1
  local i sock
  for i in $(seq 1 50); do
    for sock in "${XDG_RUNTIME_DIR}"/wayland-*; do
      [ -e "$sock" ] || continue
      case "$sock" in *.lock) continue ;; esac
      if ! grep -qx "$sock" <<<"$before"; then
        WAYLAND_DISPLAY="$(basename "$sock")"; export WAYLAND_DISPLAY; break 2
      fi
    done
    sleep 0.2
  done
  [ -n "${WAYLAND_DISPLAY:-}" ] || \
    die "compositor did not create wayland socket (see $LOG_DIR/compositor.log)"
  OUTPUT="${OUTPUT:-HEADLESS-1}"
}

# --- wayvnc ---------------------------------------------------------------------

start_wayvnc() {
  local out="${OUTPUT:-}"
  [ -z "$out" ] && out="HEADLESS-1"
  echo "$out" > "$OUT_FILE"

  local args=(-o "$out" -f "$FPS" -n "$DESKTOP" "$BIND" "$PORT" "${WAYVNC_EXTRA[@]}")
  log "starting wayvnc ${args[*]} (WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>})"
  setsid wayvnc "${args[@]}" >>"$LOG_DIR/wayvnc.log" 2>&1 &
  echo $! > "$VNC_PID_FILE"
  sleep 0.5
  pid_alive "$(read_pid "$VNC_PID_FILE")" || die "wayvnc exited (see $LOG_DIR/wayvnc.log)"
  log "wayvnc up: vnc://$BIND:$PORT  output=$out"
}

# --- commands -------------------------------------------------------------------

cmd_start() {
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  BACKEND="$(detect_backend)"
  log "backend: $BACKEND"

  case "$BACKEND" in
    hyprland)
      if hyprland_running; then
        hypr_env
        local sock; sock="$(hypr_wayland_socket)"
        [ -n "$sock" ] && { WAYLAND_DISPLAY="$sock"; export WAYLAND_DISPLAY; }
      else
        hypr_spawn_session
      fi
      if [ "$ATTACH_ONLY" = 0 ]; then
        OUTPUT="$(hypr_ensure_output)"
      else
        OUTPUT="${OUTPUT:-$(hypr_headless_outputs | head -1)}"
      fi
      ;;
    wlroots)
      if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        OUTPUT="${OUTPUT:-HEADLESS-1}"
        warn "using existing session $WAYLAND_DISPLAY — headless output $OUTPUT must already exist"
      else
        wlroots_spawn_session
      fi
      ;;
  esac

  if [ "$BACKEND" = hyprland ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    local sock; sock="$(hypr_wayland_socket)"
    [ -n "$sock" ] && { WAYLAND_DISPLAY="$sock"; export WAYLAND_DISPLAY; }
  fi

  start_wayvnc
}

cmd_stop() {
  mkdir -p "$STATE_DIR"
  local pid out
  pid="$(read_pid "$VNC_PID_FILE")"
  pid_alive "$pid" && { kill "$pid" 2>/dev/null; log "wayvnc stopped (pid $pid)"; } || log "wayvnc not running"

  pid="$(read_pid "$COMP_PID_FILE")"
  if pid_alive "$pid"; then
    kill "$pid" 2>/dev/null; log "compositor stopped (pid $pid)"; SPAWNED_COMPOSITOR=1
  fi

  out="$(cat "$OUT_FILE" 2>/dev/null || true)"
  if [ "$KEEP_OUTPUT" = 0 ] && [ -n "$out" ] && [ "$SPAWNED_COMPOSITOR" = 0 ] && hyprland_running; then
    hypr_env; hyprctl output remove "$out" >/dev/null 2>&1 || true
    log "headless output $out removed"
  fi
  rm -f "$VNC_PID_FILE" "$COMP_PID_FILE" "$OUT_FILE"
}

cmd_status() {
  local pid
  pid="$(read_pid "$VNC_PID_FILE")"
  if pid_alive "$pid"; then log "wayvnc: running (pid $pid)"; else log "wayvnc: not running"; fi
  pid="$(read_pid "$COMP_PID_FILE")"
  pid_alive "$pid" && log "spawned compositor: running (pid $pid)"
  [ -s "$OUT_FILE" ] && log "output: $(cat "$OUT_FILE")"
  if hyprland_running; then hypr_env; hyprctl monitors 2>/dev/null | grep -iE "Monitor|HEADLESS" | head -10; fi
}

# --- arg parse -------------------------------------------------------------------

CMD="${1:-}"; shift || true
case "$CMD" in
  start|stop|status) ;;
  -h|--help|"") usage ;;
  *) die "unknown command: $CMD (start|stop|status)" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --backend)      BACKEND="$2"; shift 2 ;;
    --compositor)   COMPOSITOR="$2"; shift 2 ;;
    --output)       OUTPUT="$2"; shift 2 ;;
    --mode)         MODE="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --bind)         BIND="$2"; shift 2 ;;
    --fps)          FPS="$2"; shift 2 ;;
    --desktop)      DESKTOP="$2"; shift 2 ;;
    --no-input)     WAYVNC_EXTRA+=(-d); shift ;;
    --attach-only)  ATTACH_ONLY=1; shift ;;
    --keep-output)  KEEP_OUTPUT=1; shift ;;
    *)              die "unknown option: $1" ;;
  esac
done

case "$CMD" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
esac
