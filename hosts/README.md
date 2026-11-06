# hosts/

Per-machine заметки: особенности конкретных машин, на которых
развёрнуто окружение.

Один файл на машину: `hosts/<hostname>.md` или `hosts/<alias>.md`.

Что полезно записывать:

- ОС, архитектура, что нестандартно (kernel, immutable distro и т.п.)
- какие части окружения применимы / пропущены и почему
- локальные пути, если remenv живёт не в `~/code/remenv`
- доступ: ssh-алиас, tunnel-интерфейс (если появится)

Пример минимального файла:

```markdown
# workstation

- Manjaro, x86_64
- dotfiles применяются через xstow home
- remenv: ~/code/remenv
```
