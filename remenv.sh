# remenv.sh — подключается из shell rc:
#   [ -f ~/code/remenv/remenv.sh ] && . ~/code/remenv/remenv.sh
#
# Держите REMENV_ROOT синхронным с реальным расположением репо.

export REMENV_ROOT="${REMENV_ROOT:-$HOME/code/remenv}"

# ~/.local/bin — сюда bootstrap кладёт свои бинарники и линки на скрипты
case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH

# Обновить окружение на этой машине
remenv-update() {
  git -C "$REMENV_ROOT" pull --ff-only && "$REMENV_ROOT/bootstrap.sh"
}

# Открыть рецепт/заметку: remenv-recipe iscsi-mount
remenv-recipe() {
  local f="$REMENV_ROOT/recipes/$1.md"
  [ -f "$f" ] && "${EDITOR:-less}" "$f" || ls "$REMENV_ROOT/recipes"
}
