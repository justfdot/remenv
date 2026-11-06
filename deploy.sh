#!/usr/bin/env bash
# deploy.sh — обновить remenv и прогнать bootstrap на удалённой машине.
# Использование:
#   ./deploy.sh user@host [remote-dir] [--clone]
# remote-dir по умолчанию: code/remenv (относительно $HOME)
set -euo pipefail

HOST="${1:?usage: deploy.sh <ssh-host> [remote-dir]}"
REMOTE_DIR="${2:-code/remenv}"
REPO_URL="${REMENV_REPO:-https://github.com/justfdot/remenv.git}"

if ssh "$HOST" "test -d ~/$REMOTE_DIR/.git"; then
  echo "== updating $HOST:$REMOTE_DIR"
  ssh "$HOST" "cd ~/$REMOTE_DIR && git pull --ff-only && ./bootstrap.sh"
else
  echo "== cloning $REPO_URL -> $HOST:~/$REMOTE_DIR"
  ssh "$HOST" "mkdir -p ~/$REMOTE_DIR && git clone $REPO_URL ~/$REMOTE_DIR && ~/$REMOTE_DIR/bootstrap.sh"
fi
