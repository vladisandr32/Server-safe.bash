#!/bin/bash

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════╗"
echo "║     Автоматическая защита сервера     ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"

# ==============================
# Параметры
# ==============================
read -p "Имя нового пользователя [rena]: " USERNAME
USERNAME=${USERNAME:-rena}

read -p "SSH порт [41488]: " SSH_PORT
SSH_PORT=${SSH_PORT:-41488}

read -p "Открыть порт 443? (yes/no) [yes]: " OPEN_443
OPEN_443=${OPEN_443:-yes}

read -p "Включить форвардинг IPv4/IPv6? (yes/no) [yes]: " FORWARDING
FORWARDING=${FORWARDING:-yes}

read -p "Время бана fail2ban [1h]: " BAN_TIME
BAN_TIME=${BAN_TIME:-1h}

read -p "Время бана SSH [24h]: " SSH_BAN_TIME
SSH_BAN_TIME=${SSH_BAN_TIME:-24h}

read -p "Количество попыток SSH [3]: " SSH_MAX_RETRY
SSH_MAX_RETRY=${SSH_MAX_RETRY:-3}

read -p "Окно поиска попыток [10m]: " FIND_TIME
FIND_TIME=${FIND_TIME:-10m}

echo ""
read -p "Настроить SSH уведомления в Telegram? (yes/no) [yes]: " SETUP_TG
SETUP_TG=${SETUP_TG:-yes}

if [ "$SETUP_TG" = "yes" ]; then
    read -p "Telegram Bot Token: " TG_TOKEN
    read -p "Telegram Chat ID: " TG_CHAT_ID
    read -p "Использовать SOCKS5 прокси для Telegram? (yes/no) [no]: " USE_SOCKS
    USE_SOCKS=${USE_SOCKS:-no}
    if [ "$USE_SOCKS" = "yes" ]; then
        read -p "SOCKS5 адрес [127.0.0.1:10808]: " SOCKS_ADDR
        SOCKS_ADDR=${SOCKS_ADDR:-127.0.0.1:10808}
    fi
fi

# Итоговые настройки
echo ""
echo -e "${YELLOW}Настройки:${NC}"
echo "  Пользователь:       $USERNAME"
echo "  SSH порт:           $SSH_PORT"
echo "  Открыть 443:        $OPEN_443"
echo "  Форвардинг:         $FORWARDING"
echo "  Бан по умолчанию:   $BAN_TIME"
echo "  Бан SSH:            $SSH_BAN_TIME"
echo "  Попыток SSH:        $SSH_MAX_RETRY"
echo "  Окно попыток:       $FIND_TIME"
echo "  TG уведомления:     $SETUP_TG"
echo ""
read -p "Продолжить? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}Отменено${NC}"
    exit 0
fi

# ==============================
# 1. Обновление системы
# ==============================
echo -e "\n${YELLOW}[1/7] Обновление системы...${NC}"
apt update && apt upgrade -y
apt install -y sudo curl
echo -e "${GREEN}Готово${NC}"

# ==============================
# 2. Создание пользователя
# ==============================
echo -e "\n${YELLOW}[2/7] Создание пользователя ${USERNAME}...${NC}"

if id "$USERNAME" &>/dev/null; then
    echo -e "${GREEN}Пользователь ${USERNAME} уже существует${NC}"
else
    adduser --gecos "" $USERNAME --allow-bad-names
    usermod -aG sudo $USERNAME
    echo -e "${GREEN}Пользователь ${USERNAME} создан${NC}"
fi

# ==============================
# 3. SSH ключ
# ==============================
echo -e "\n${YELLOW}[3/7] Настройка SSH ключа...${NC}"

if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    echo -e "${GREEN}Ключ найден у root, копируем в ${USERNAME}...${NC}"
    mkdir -p /home/$USERNAME/.ssh
    cp /root/.ssh/authorized_keys /home/$USERNAME/.ssh/
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
    chmod 700 /home/$USERNAME/.ssh
    chmod 600 /home/$USERNAME/.ssh/authorized_keys
    echo -e "${GREEN}Ключ скопирован${NC}"
else
    echo -e "${RED}Ключ не найден у root!${NC}"
    echo -e "${YELLOW}Сгенерируй ключ на локальной машине:${NC}"
    echo -e "  ssh-keygen -t ed25519 -f ~/.ssh/$(hostname) -C 'server-${USERNAME}'"
    echo -e "${YELLOW}Скопируй публичный ключ:${NC}"
    echo -e "  ssh-copy-id -i ~/.ssh/$(hostname).pub root@$(curl -s ifconfig.me 2>/dev/null)"
    echo ""
    read -p "Нажми Enter когда добавишь ключ..."

    mkdir -p /home/$USERNAME/.ssh
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
    chmod 700 /home/$USERNAME/.ssh
    chmod 600 /home/$USERNAME/.ssh/authorized_keys 2>/dev/null || true
fi

if [ ! -f /home/$USERNAME/.ssh/authorized_keys ] || [ ! -s /home/$USERNAME/.ssh/authorized_keys ]; then
    echo -e "${RED}Ключ не найден! Прерываем.${NC}"
    exit 1
fi
echo -e "${GREEN}Ключ на месте:${NC}"
cat /home/$USERNAME/.ssh/authorized_keys

SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo -e "${RED}ВАЖНО! Проверь вход в новом терминале:${NC}"
echo -e "  ssh -i ~/.ssh/КЛЮЧ ${USERNAME}@${SERVER_IP}"
echo ""
read -p "Вход успешен? (yes/no): " CONFIRM_KEY
if [ "$CONFIRM_KEY" != "yes" ]; then
    echo -e "${RED}Прерываем — исправь ключ и запусти снова${NC}"
    exit 1
fi

# ==============================
# 4. Настройка SSHD
# ==============================
echo -e "\n${YELLOW}[4/7] Настройка SSH...${NC}"

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

cat > /etc/ssh/sshd_config << EOF
Include /etc/ssh/sshd_config.d/*.conf

Port ${SSH_PORT}
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

PermitRootLogin no
StrictModes yes
MaxAuthTries ${SSH_MAX_RETRY}
MaxSessions 5

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no

UsePAM yes
X11Forwarding no
PrintMotd no

AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

KexAlgorithms curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
EOF

systemctl restart sshd
echo -e "${GREEN}SSH настроен на порту ${SSH_PORT}${NC}"

echo ""
echo -e "${RED}ВАЖНО! Проверь вход по новому порту в новом терминале:${NC}"
echo -e "  ssh -i ~/.ssh/КЛЮЧ -p ${SSH_PORT} ${USERNAME}@${SERVER_IP}"
echo ""
read -p "Вход успешен? (yes/no): " CONFIRM_SSH
if [ "$CONFIRM_SSH" != "yes" ]; then
    echo -e "${RED}Восстанавливаем старый конфиг...${NC}"
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    systemctl restart sshd
    exit 1
fi

# ==============================
# 5. Fail2ban
# ==============================
echo -e "\n${YELLOW}[5/7] Установка fail2ban...${NC}"

apt install -y fail2ban

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = ${BAN_TIME}
findtime = ${FIND_TIME}
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = ${SSH_MAX_RETRY}
bantime = ${SSH_BAN_TIME}
EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo -e "${GREEN}Fail2ban настроен${NC}"

# ==============================
# 6. UFW
# ==============================
echo -e "\n${YELLOW}[6/7] Настройка ufw...${NC}"

apt install -y ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp

if [ "$OPEN_443" = "yes" ]; then
    ufw allow 443/tcp
    ufw allow 443/udp
fi

ufw --force enable
echo -e "${GREEN}UFW настроен${NC}"

# BBR и форвардинг
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.all.forwarding/d' /etc/sysctl.conf

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

if [ "$FORWARDING" = "yes" ]; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
fi

sysctl -p
echo -e "${GREEN}BBR включён${NC}"

# ==============================
# 7. Telegram уведомления
# ==============================
if [ "$SETUP_TG" = "yes" ]; then
    echo -e "\n${YELLOW}[7/7] Настройка Telegram уведомлений...${NC}"

    cat > /etc/ssh/ssh_login_notify.sh << EOF
#!/bin/bash

BOT_TOKEN="${TG_TOKEN}"
CHAT_ID="${TG_CHAT_ID}"

MESSAGE="🔐 SSH вход на \$(hostname)
👤 Пользователь: \$PAM_USER
🌐 IP: \$PAM_RHOST
📅 Время: \$(date '+%Y-%m-%d %H:%M:%S %Z')"

EOF

    if [ "$USE_SOCKS" = "yes" ]; then
        cat >> /etc/ssh/ssh_login_notify.sh << EOF
curl -s --max-time 10 \\
    --proxy socks5h://${SOCKS_ADDR} \\
    -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
    -d chat_id="\${CHAT_ID}" \\
    -d text="\${MESSAGE}" > /dev/null 2>&1 &
EOF
    else
        cat >> /etc/ssh/ssh_login_notify.sh << EOF
curl -s --max-time 10 \\
    -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
    -d chat_id="\${CHAT_ID}" \\
    -d text="\${MESSAGE}" > /dev/null 2>&1 &
EOF
    fi

    chmod +x /etc/ssh/ssh_login_notify.sh

    # Добавляем в PAM если ещё нет
    if ! grep -q "ssh_login_notify" /etc/pam.d/sshd; then
        echo "session optional pam_exec.so seteuid /etc/ssh/ssh_login_notify.sh" >> /etc/pam.d/sshd
    fi

    systemctl restart sshd

    # Тест
    echo -e "${YELLOW}Отправляем тестовое сообщение...${NC}"
    PAM_USER=$USERNAME PAM_RHOST="test" bash /etc/ssh/ssh_login_notify.sh
    sleep 3
    echo -e "${GREEN}Проверь Telegram — должно прийти уведомление${NC}"
fi

# ==============================
# Итог
# ==============================
echo -e "\n${BLUE}"
echo "╔═══════════════════════════════════════╗"
echo "║              Всё готово!              ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Пользователь: ${GREEN}${USERNAME}${NC}"
echo -e "  SSH порт:     ${GREEN}${SSH_PORT}${NC}"
echo -e "  IP сервера:   ${GREEN}${SERVER_IP}${NC}"
echo ""
echo -e "${YELLOW}Подключение:${NC}"
echo -e "  ssh -i ~/.ssh/КЛЮЧ -p ${SSH_PORT} ${USERNAME}@${SERVER_IP}"
echo ""
echo -e "${YELLOW}Статус:${NC}"
ufw status
echo ""
fail2ban-client status
