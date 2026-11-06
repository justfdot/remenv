# remenv — личное окружение

Источник истины для рабочего окружения: свои утилиты, dotfiles-связка,
записки/рецепты и конфиги AI-агентов. Разворачивается на любой машине
одной командой.

## Структура

```
remenv/
  bootstrap.sh    — one-shot установка окружения на новой машине
  deploy.sh       — обновление окружения на удалённой машине по ssh
  remenv.sh       — env-хелперы, подключается из shell rc
  tools/          — свои утилиты (getar, wgtun, ...)
  recipes/        — записки и рецепты (runbook'и)
  agents/         — заметки по общим конфигам агентов
  hosts/          — per-machine заметки и особенности
```

Агентские конфиги (`.mcp.json`, `AGENTS.md`, `GEMINI.md`, `opencode.json`,
`.claude/`, `.gemini/`, `.grok/`) лежат в корне репо — они и есть общий
слой для всех машин.

Dotfiles живут отдельно: <https://github.com/justfdot/dotfiles>
(xstow-структура `home/` + `system/`). remenv их не дублирует, а
подключает через bootstrap.

## Быстрый старт на новой машине

```bash
git clone https://github.com/justfdot/remenv.git ~/code/remenv
~/code/remenv/bootstrap.sh
```

Затем добавь в `~/.bashrc` / `~/.zshrc`:

```bash
[ -f ~/code/remenv/remenv.sh ] && . ~/code/remenv/remenv.sh
```

## Что делает bootstrap.sh

- ставит x-cmd, если его нет
- клонирует `justfdot/dotfiles` и применяет `xstow` (если установлен)
- собирает Rust-утилиты из `tools/` (`cargo build --release`) и кладёт
  бинарники в `~/.local/bin`
- линкует shell-скрипты из `tools/*/` в `~/.local/bin`

Скрипт идемпотентен — можно запускать повторно для обновления.

## Деплой на удалённую машину

```bash
./deploy.sh user@host            # обновит ~/code/remenv и прогонит bootstrap
./deploy.sh user@host work/remenv  # другой путь на удалённой машине
```

## Свои инструменты

- `tools/getar` — кроссплатформенный iSCSI-маунтер (PowerShell + Bash)
- `tools/wgtun` — Rust-утилита для WireGuard (см. `tools/wgtun/README.md`)

Сборка: `make -C tools/wgtun install-local` или общий `./bootstrap.sh`.

## Записки и рецепты

`recipes/` — markdown-файлы, один рецепт на файл. Формат описан в
`recipes/README.md`. Идея: runbook'и, которые должны быть под рукой на
любой машине — без поиска по всем `~/code`.

## Безопасность

Репозиторий публичный. Не коммитьте секреты: токены, ключи, пароли.
Реальные значения держите в `~/.config/`, `.env` (в .gitignore) или
переменных окружения. В `tools/` все креды — плейсхолдеры.
