#!/usr/bin/env bash
# remenv bootstrap — идемпотентная установка окружения на новой машине.
# Использование: git clone <repo> ~/code/remenv && ~/code/remenv/bootstrap.sh
set -euo pipefail

REMENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/justfdot/dotfiles.git}"
TOOLS_DIR="$REMENV_DIR/tools"
LOCAL_BIN="$HOME/.local/bin"

info() { printf '\033[1;34m[remenv]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[remenv]\033[0m %s\n' "$*"; }

mkdir -p "$LOCAL_BIN"

# --- 1. x-cmd -------------------------------------------------------------
if [ ! -f "$HOME/.x-cmd.root/X" ]; then
  info "installing x-cmd..."
  curl -fsSL https://get.x-cmd.com | bash
else
  info "x-cmd already installed"
fi

# --- 2. dotfiles ----------------------------------------------------------
if [ ! -d "$DOTFILES_DIR/.git" ]; then
  info "cloning dotfiles -> $DOTFILES_DIR"
  git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
fi
if command -v xstow >/dev/null 2>&1; then
  info "applying dotfiles (xstow home)"
  (cd "$DOTFILES_DIR" && xstow -a home)
else
  warn "xstow not found — dotfiles cloned but not applied"
fi

# --- 3. tools -------------------------------------------------------------
for tool_dir in "$TOOLS_DIR"/*/; do
  [ -d "$tool_dir" ] || continue
  name="$(basename "$tool_dir")"

  if [ -f "$tool_dir/Cargo.toml" ]; then
    info "building rust tool: $name"
    (cd "$tool_dir" && cargo build --release)
    bin="$tool_dir/target/release/$name"
    if [ -f "$bin" ]; then
      install -m 0755 "$bin" "$LOCAL_BIN/$name"
      info "installed $name -> $LOCAL_BIN/$name"
    fi
  fi

  # линкуем *.sh скрипты верхнего уровня в ~/.local/bin
  for script in "$tool_dir"/*.sh; do
    [ -f "$script" ] || continue
    link_name="$(basename "${script%.sh}")"
    ln -sfn "$script" "$LOCAL_BIN/$link_name"
    info "linked $link_name -> $script"
  done
done

cat <<EOF

Done. Add to your shell rc (~/.bashrc or ~/.zshrc):

    [ -f $REMENV_DIR/remenv.sh ] && . $REMENV_DIR/remenv.sh

Useful commands after that:
    remenv-update      # git pull + bootstrap
    remenv-recipe NAME # open recipes/NAME.md
EOF
