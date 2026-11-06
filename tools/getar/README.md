# Getar - Cross-Platform iSCSI Mounter

Кроссплатформенный скрипт для автоматического монтирования iSCSI таргета с Proxmox, работающий на Windows и Linux.

## Особенности

- **Кроссплатформенность**: работает на Windows и Linux через PowerShell 7+
- **Автоматическое монтирование**: определяет платформу и использует соответствующие утилиты (iscsicli.exe на Windows, iscsiadm на Linux)
- **Фоновый монитор активности**: отдельный процесс отслеживает файловую активность
- **Авто-отключение**: отключает таргет через Proxmox API при 15 минутах неактивности
- **Graceful shutdown**: корректное размонтирование при Ctrl+C

## Требования

### Windows
- PowerShell 7+ (pwsh)
- Администраторские права
- Windows 8+ (поддержка iSCSI)

### Linux
- PowerShell 7+ (pwsh)
- Права root/sudo
- Пакет open-iscsi или iscsi-initiator-utils

### Установка PowerShell 7+

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install -y wget apt-transport-https software-properties-common
wget -q https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt update
sudo apt install -y powershell
```

**CentOS/RHEL:**
```bash
sudo yum install -y https://github.com/PowerShell/PowerShell/releases/download/v7.4.5/powershell-7.4.5-1.rh.x86_64.rpm
```

**macOS:**
```bash
brew install powershell
```

## Настройка Proxmox

### 1. Создание iSCSI таргета

На Proxmox сервере создайте LVM или ZFS том для iSCSI:

```bash
# Создайте том (пример для LVM)
lvcreate -L 100G -n it-share pve
```

### 2. Настройка iSCSI Target Server

Установите и настройте iSCSI target software (например, targetcli-fb):

```bash
apt install targetcli-fb
```

Создайте конфигурацию таргета:

```bash
targetcli
backstores/block create name=it-share dev=/dev/pve/it-share
iscsi/ create iqn.2024-10.com.proxmox:it-share
iscsi/iqn.2024-10.com.proxmox:it-share/tpg1/luns create /backstores/block/it-share
iscsi/iqn.2024-10.com.proxmox:it-share/tpg1/acls create iqn.2024-10.com.it174:client1
iscsi/iqn.2024-10.com.proxmox:it-share/tpg1/portals create 0.0.0.0
exit
```

### 3. Настройка Proxmox API Token

Создайте API токен для автоматического отключения:

1. Откройте Proxmox web interface
2. Перейдите в Datacenter → Permissions → API Tokens
3. Создайте токен для пользователя (например, root@pam)
4. Сохраните токен в формате: `user@realm!token-id=secret-token`

### 4. Настройка файрвола

Откройте порты на Proxmox:
- TCP 3260 (iSCSI)
- TCP 8006 (Proxmox API)

```bash
# Если используете iptables
iptables -A INPUT -p tcp --dport 3260 -j ACCEPT
iptables -A INPUT -p tcp --dport 8006 -j ACCEPT
```

## Конфигурация скрипта

Отредактируйте параметры в начале файла `mount-iscsi.ps1`:

```powershell
$script:ISCSI_TARGET_IP = "192.168.1.100"              # IP Proxmox сервера
$script:ISCSI_IQN = "iqn.2024-10.com.proxmox:it-share"  # IQN таргета
$script:PROXMOX_API_URL = "https://192.168.1.100:8006/api2/json"  # Proxmox API URL
$script:PROXMOX_API_TOKEN = "root@pam!token-id=YOUR-TOKEN-HERE"  # API токен
$script:INACTIVITY_TIMEOUT_MINUTES = 15               # Таймаут неактивности
$script:MOUNT_POINT_LINUX = "/mnt/it-share"           # Путь монтирования на Linux
$script:MOUNT_LETTER_WINDOWS = "Z:"                   # Буква диска на Windows
```

## Использование

### Локальный запуск

**Монтирование с монитором активности:**
```bash
pwsh ./mount-iscsi.ps1 --mount
```

**Монтирование без монитора:**
```bash
pwsh ./mount-iscsi.ps1 --mount --no-monitor
```

**Размонтирование:**
```bash
pwsh ./mount-iscsi.ps1 --unmount
```

### Удаленный запуск (однострочник)

После развертывания скрипта на HTTPS сервере:

**PowerShell (Windows):**
```powershell
irm https://share.it174.pro/mount.ps1 | iex
```

**Bash (Linux):**
```bash
curl -fsSL https://share.it174.pro/mount.sh | bash
```

## Как это работает

1. **Монтирование:**
   - Скрипт определяет платформу (Windows/Linux)
   - На Windows использует `iscsicli.exe` для подключения к iSCSI таргету
   - На Linux использует `iscsiadm` для подключения
   - Автоматически инициализирует и форматирует диск при первом подключении
   - Монтирует диск в указанное место (Z: на Windows, /mnt/it-share на Linux)

2. **Монитор активности:**
   - Запускает отдельный фоновый процесс PowerShell
   - Отслеживает файловую I/O активность на смонтированном диске
   - Сбрасывает таймер при обнаружении активности
   - Проверяет родительский процесс и завершается при его смерти

3. **Авто-отключение:**
   - При достижении таймаута (15 минут по умолчанию) отправляет запрос на Proxmox API
   - Proxmox отключает iSCSI сессию на стороне сервера
   - Клиент корректно обрабатывает отключение

4. **Graceful Shutdown:**
   - При нажатии Ctrl+C скрипт останавливает монитор
   - Корректно размонтирует диск
   - Отключается от iSCSI таргета

## Доставка скрипта

Варианты доставки для однострочника:

### 1. HTTPS сервер

Разместите скрипт на HTTPS сервере:
```nginx
server {
    listen 443 ssl;
    server_name share.it174.pro;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location /mount.ps1 {
        root /var/www/share;
        default_type application/x-powershell;
    }
}
```

### 2. GitHub Pages / GitLab Pages

Загрузите скрипт в репозиторий и включите Pages:
- Выдается бесплатно
- Автоматический HTTPS
- Доступен по URL вида `https://username.github.io/repo/mount.ps1`

### 3. Прокси-сервер

Используйте промежуточный сервер для кэширования и логирования:
```bash
# На прокси сервере
curl -o /var/www/mount.ps1 https://source.example.com/mount.ps1
```

## Troubleshooting

### Windows

**Ошибка "Access Denied":**
```
Solution: Запустите PowerShell от имени администратора
```

**Диск не монтируется:**
```
Solution: Проверьте работу iSCSI initiator:
iscsicli.exe ListTargets
iscsicli.exe ListSessions
```

### Linux

**Ошибка "iscsiadm not found":**
```bash
# Ubuntu/Debian
sudo apt install open-iscsi

# CentOS/RHEL
sudo yum install iscsi-initiator-utils
```

**Ошибка доступа:**
```bash
# Запустите с sudo
sudo pwsh ./mount-iscsi.ps1 --mount
```

### Proxmox API

**Ошибка сертификата:**
```powershell
# Скрипт использует -SkipCertificateCheck
# Для продакшена настройте валидный SSL сертификат на Proxmox
```

**Ошибка авторизации:**
```
Solution: Проверьте формат токена: user@realm!token-id=secret
```

## Безопасность

⚠️ **Важные замечания по безопасности:**

1. **API токен в открытом виде:** Токен хранится в скрипте в открытом виде. Рекомендуется:
   - Ограничить права токена в Proxmox (только отключение iSCSI)
   - Использовать отдельного пользователя с минимальными правами
   - Регулярно обновлять токен

2. **Доставка скрипта:** Убедитесь что:
   - HTTPS сервер использует валидный SSL сертификат
   - URL для загрузки проверен и доверен
   - Рассмотрите возможность подписи скрипта (code signing)

3. **Сетевой доступ:** Ограничьте доступ к:
   - iSCSI порту (3260) только для доверенных сетей
   - Proxmox API (8006) только для доверенных сетей

## Лицензия

MIT License - свободное использование и модификация.

## Контакты

Для вопросов и поддержки обращайтесь к IT команде.
