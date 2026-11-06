# wayvnc-headless

Создаёт headless Wayland-вывод и поднимает на нём `wayvnc` —
графический доступ к хосту по VNC без монитора.

## Использование

```bash
wayvnc-headless start [опции]   # поднять headless-вывод + wayvnc
wayvnc-headless status          # состояние
wayvnc-headless stop            # остановить (и убрать за собой)
```

Подключение: любой VNC-клиент на `vnc://<host>:5900`
(TigerVNC, wlvncc, RealVNC и т.д.).

## Бэкенды

### Hyprland

```bash
wayvnc-headless start --backend hyprland --mode 1920x1080@60
```

- На **живой сессии** — просто создаёт `HEADLESS-N` через
  `hyprctl output create headless` и цепляет wayvnc.
- **С нуля** (нет сессии) — запускает `hyprland`; для этого нужен
  GPU/DRM и seat (logind). Полноценного headless-бэкенда у Hyprland
  нет, поэтом на машине совсем без GPU используйте wlroots-бэкенд
  или запустите Hyprland внутри другой сессии.

### wlroots (sway / labwc / cage / umbriel / ...)

```bash
wayvnc-headless start --backend wlroots            # sway → labwc → cage → umbriel
wayvnc-headless start --backend wlroots --compositor cage
```

Запускает композитор с `WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1`
и цепляет wayvnc к `HEADLESS-1`. Если wayland-сессия уже есть —
wayvnc подключится к ней (headless-вывод должен существовать).

## Опции

| Опция            | Default   | Что делает                                  |
|------------------|-----------|---------------------------------------------|
| `--backend`      | auto      | `hyprland` / `wlroots` / auto               |
| `--compositor`   | авто      | какой wlroots-композитор спавнить           |
| `--output`       | HEADLESS-1| имя вывода                                  |
| `--mode`         | —         | `WxH@R`, напр. `1920x1080@60` (hyprland)    |
| `--port`         | 5900      | порт VNC                                    |
| `--bind`         | 0.0.0.0   | адрес прослушивания                        |
| `--fps`          | 30        | лимит fps                                   |
| `--desktop`      | hostname  | имя desktop в VNC                           |
| `--no-input`     | —         | запретить ввод (`wayvnc -d`)                |
| `--attach-only`  | —         | не создавать вывод, только подключить wayvnc|
| `--keep-output`  | —         | при stop не удалять headless-вывод          |

## Состояние и логи

`${XDG_RUNTIME_DIR}/wayvnc-headless/`:

- `compositor.pid`, `wayvnc.pid`, `output`
- `logs/hyprland.log`, `logs/compositor.log`, `logs/wayvnc.log`

## Примеры

```bash
# на Hyprland-машине с живой сессией — дополнительный headless-экран
wayvnc-headless start --backend hyprland --output HEADLESS-2 --mode 2560x1440@60

# на сервере без монитора (wlroots-композитор установлен)
wayvnc-headless start --backend wlroots --port 5900

# read-only просмотр
wayvnc-headless start --no-input
```
