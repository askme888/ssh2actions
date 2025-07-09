#!/usr/bin/env bash
#
# Copyright (c) 2020 P3TERX <https://p3terx.com>
# Modified by Your Name for cloudflared support
#
# Description: Connect to Github Actions VM via SSH using cloudflared
# Version: 2.1 (cloudflared edition)
#

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"
INFO="[${Green_font_prefix}INFO${Font_color_suffix}]"
ERROR="[${Red_font_prefix}ERROR${Font_color_suffix}]"
LOG_FILE='/tmp/cloudflared.log'
TELEGRAM_LOG="/tmp/telegram.log"
CONTINUE_FILE="/tmp/continue"

if [[ -z "${SSH_PASSWORD}" && -z "${SSH_PUBKEY}" && -z "${GH_SSH_PUBKEY}" ]]; then
    echo -e "${ERROR} Please set 'SSH_PASSWORD' environment variable."
    exit 3
fi

install_cloudflared() {
    echo -e "${INFO} Installing cloudflared..."
    if [[ -n "$(uname | grep -i Linux)" ]]; then
        curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
        chmod +x cloudflared
        sudo mv cloudflared /usr/local/bin/
    elif [[ -n "$(uname | grep -i Darwin)" ]]; then
        curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz -o cloudflared.tgz
        tar -xvzf cloudflared.tgz
        rm cloudflared.tgz
        chmod +x cloudflared
        sudo mv cloudflared /usr/local/bin/
        USER=root
        echo 'PermitRootLogin yes' | sudo tee -a /etc/ssh/sshd_config >/dev/null
        sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist
        sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist
    else
        echo -e "${ERROR} Unsupported system!"
        exit 1
    fi
    cloudflared --version
}

setup_ssh() {
    if [[ -n "${SSH_PASSWORD}" ]]; then
        echo -e "${INFO} Setting user password..."
        echo -e "${SSH_PASSWORD}\n${SSH_PASSWORD}" | sudo passwd "${USER}"
    fi
    if [[ -n "${SSH_PUBKEY}" ]]; then
        echo -e "${INFO} Setting SSH public key..."
        mkdir -p ~/.ssh
        echo "${SSH_PUBKEY}" >> ~/.ssh/authorized_keys
    fi
    if [[ -n "${GH_SSH_PUBKEY}" ]]; then
        echo -e "${INFO} Setting GitHub SSH public key..."
        mkdir -p ~/.ssh
        curl -sSL "https://github.com/${GH_SSH_PUBKEY}.keys" >> ~/.ssh/authorized_keys
    fi
}

start_cloudflared() {
    echo -e "${INFO} Starting cloudflared tunnel..."
    screen -dmS cloudflared \
        cloudflared tunnel --url ssh://localhost:22 --logfile $LOG_FILE --metrics localhost:49589
    
    echo -e "${INFO} Waiting for tunnel connection..."
    sleep 10
    while ! grep -q "Connection" $LOG_FILE; do
        sleep 2
        if [[ $SECONDS -gt 60 ]]; then
            echo -e "${ERROR} Tunnel connection timeout"
            exit 4
        fi
    done
    
    TUNNEL_URL=$(grep -oE "https://[0-9a-z\-]+\.trycloudflare.com" $LOG_FILE | head -n1)
    SSH_CMD="ssh ${USER}@${TUNNEL_URL#https://} -p 22"
}

send_telegram() {
    local MSG="
*GitHub Actions - cloudflared session info:*

⚡ *CLI:*
\`${SSH_CMD}\`

🔔 *TIPS:*
Run \`touch ${CONTINUE_FILE}\` to continue.
"
    curl -sSX POST "${TELEGRAM_API_URL:-https://api.telegram.org}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=Markdown" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${MSG}" > $TELEGRAM_LOG
}

# Main process
install_cloudflared
setup_ssh
start_cloudflared

if [[ -n "${TUNNEL_URL}" ]]; then
    echo -e "${INFO} SSH Command: ${Green_font_prefix}${SSH_CMD}${Font_color_suffix}"
    
    if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
        echo -e "${INFO} Sending Telegram notification..."
        send_telegram
        if grep -q '"ok":true' $TELEGRAM_LOG; then
            echo -e "${INFO} Telegram notification sent!"
        else
            echo -e "${ERROR} Telegram notification failed: $(cat $TELEGRAM_LOG)"
        fi
    fi
    
    for i in {1..10}; do
        echo "========================================"
        echo "Use this command to connect:"
        echo -e "${Green_font_prefix}${SSH_CMD}${Font_color_suffix}"
        echo "Run 'touch ${CONTINUE_FILE}' to continue"
        echo "========================================"
        sleep 10
    done
    
    while :; do
        sleep 5
        if [[ -e $CONTINUE_FILE ]]; then
            echo -e "${INFO} Continue triggered, exiting..."
            break
        fi
    done
else
    echo -e "${ERROR} Failed to get tunnel URL"
    cat $LOG_FILE
    exit 5
fi
