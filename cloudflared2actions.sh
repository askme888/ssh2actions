#!/usr/bin/env bash
#
# Copyright (c) 2020 P3TERX <https://p3terx.com>
# Modified for Cloudflared by GitHub User
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# File name：cloudflared-ssh.sh
# Description: Connect to GitHub Actions VM via SSH using Cloudflared
# Version: 1.1

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Yellow_font_prefix="\033[33m"
Font_color_suffix="\033[0m"
INFO="[${Green_font_prefix}INFO${Font_color_suffix}]"
ERROR="[${Red_font_prefix}ERROR${Font_color_suffix}]"
WARN="[${Yellow_font_prefix}WARN${Font_color_suffix}]"

LOG_FILE='/tmp/cloudflared.log'
CONTINUE_FILE="/tmp/continue"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"

# 检查必要的环境变量
if [[ -z "${SSH_PASSWORD}" && -z "${SSH_PUBKEY}" && -z "${GH_SSH_PUBKEY}" ]]; then
    echo -e "${ERROR} 请设置至少一个认证方式: SSH_PASSWORD, SSH_PUBKEY 或 GH_SSH_PUBKEY"
    exit 3
fi

# 安装 Cloudflared
install_cloudflared() {
    echo -e "${INFO} 正在安装 Cloudflared..."
    
    # 确定系统架构
    local ARCH="amd64"
    if [[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]]; then
        ARCH="arm64"
    fi
    
    # 下载对应平台的 Cloudflared
    if [[ "$(uname -s)" == "Linux" ]]; then
        echo -e "${INFO} 下载 Linux (${ARCH}) 版本的 Cloudflared..."
        curl -L --retry 3 --retry-delay 5 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "${CLOUDFLARED_BIN}"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        echo -e "${INFO} 下载 macOS (${ARCH}) 版本的 Cloudflared..."
        curl -L --retry 3 --retry-delay 5 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${ARCH}.tgz" -o cloudflared.tgz
        tar -xzf cloudflared.tgz cloudflared
        mv cloudflared "${CLOUDFLARED_BIN}"
        rm cloudflared.tgz
    else
        echo -e "${ERROR} 不支持的操作系统: $(uname -s)"
        exit 1
    fi
    
    # 设置执行权限
    chmod +x "${CLOUDFLARED_BIN}"
    echo -e "${INFO} Cloudflared 安装完成: $(${CLOUDFLARED_BIN} --version)"
}

# 配置 SSH 服务
configure_ssh() {
    echo -e "${INFO} 配置 SSH 服务..."
    
    # 解决 SSH 连接兼容性问题
    echo -e "${INFO} 更新 SSH 配置以解决兼容性问题..."
    sudo tee -a /etc/ssh/sshd_config > /dev/null << 'EOF'
# 添加更多密钥交换算法
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha1

# 添加更多加密算法
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

# 添加更多 MAC 算法
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha1

# 允许更多认证方式
PubkeyAuthentication yes
PasswordAuthentication yes
EOF

    # 设置用户密码
    if [[ -n "${SSH_PASSWORD}" ]]; then
        echo -e "${INFO} 设置用户 ${USER} 的密码..."
        echo -e "${SSH_PASSWORD}\n${SSH_PASSWORD}" | sudo passwd "${USER}" >/dev/null 2>&1
    else
        # 禁用密码认证
        echo "PasswordAuthentication no" | sudo tee -a /etc/ssh/sshd_config >/dev/null
    fi

    # 配置公钥认证
    if [[ -n "${SSH_PUBKEY}" ]] || [[ -n "${GH_SSH_PUBKEY}" ]]; then
        echo -e "${INFO} 配置 SSH 公钥..."
        SSH_DIR="${HOME}/.ssh"
        mkdir -p "${SSH_DIR}"
        chmod 700 "${SSH_DIR}"
        touch "${SSH_DIR}/authorized_keys"
        chmod 600 "${SSH_DIR}/authorized_keys"
        
        [[ -n "${SSH_PUBKEY}" ]] && echo "${SSH_PUBKEY}" >> "${SSH_DIR}/authorized_keys"
        [[ -n "${GH_SSH_PUBKEY}" ]] && echo "${GH_SSH_PUBKEY}" >> "${SSH_DIR}/authorized_keys"
    fi

    # macOS 特殊配置
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo -e "${INFO} 配置 macOS SSH 服务..."
        echo 'PermitRootLogin yes' | sudo tee -a /etc/ssh/sshd_config >/dev/null
        sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist
        sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist
    else
        # Linux 系统重启 SSH 服务
        echo -e "${INFO} 重启 SSH 服务..."
        sudo service ssh restart || sudo systemctl restart ssh
    fi
    
    # 显示 SSH 服务状态
    echo -e "${INFO} SSH 服务状态:"
    sudo service ssh status || sudo systemctl status ssh
}

# 启动 Cloudflared 隧道
start_cloudflared_tunnel() {
    echo -e "${INFO} 启动 Cloudflared SSH 隧道..."
    
    # 清理旧日志
    rm -f "${LOG_FILE}"
    
    # 生成随机隧道主机名
    local RANDOM_ID=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)
    local TUNNEL_HOST="${TUNNEL_HOSTNAME:-ssh-${GITHUB_RUN_ID}-${RANDOM_ID}.trycloudflare.com}"
    
    echo -e "${INFO} 使用隧道主机名: ${TUNNEL_HOST}"
    
    # 启动隧道
    screen -dmS cloudflared \
        sudo ${CLOUDFLARED_BIN} access tcp \
        --hostname "${TUNNEL_HOST}" \
        --url tcp://localhost:22 \
        --logfile "${LOG_FILE}" \
        --loglevel "debug"
    
    echo -e "${INFO} 等待隧道初始化 (20 秒)..."
    sleep 20
    
    # 检查隧道状态
    if [[ ! -e "${LOG_FILE}" ]]; then
        echo -e "${ERROR} Cloudflared 日志文件未找到"
        exit 4
    fi
    
    # 获取连接信息
    SSH_CMD=$(grep -Eo "ssh .+@.+ -p [0-9]+" "${LOG_FILE}" | tail -1)
    
    if [[ -z "${SSH_CMD}" ]]; then
        echo -e "${ERROR} 无法提取 SSH 连接命令"
        echo -e "${WARN} Cloudflared 日志内容:"
        cat "${LOG_FILE}"
        exit 5
    fi
    
    echo -e "${INFO} SSH 连接命令已获取: ${SSH_CMD}"
}

# 发送 Telegram 通知
send_telegram_notification() {
    if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
        echo -e "${INFO} 发送 Telegram 通知..."
        
        # 创建通知消息
        local MSG="*GitHub Actions - Cloudflared SSH 会话信息:*

🏗️ *仓库:* \`$GITHUB_REPOSITORY\`
🔧 *工作流:* \`$GITHUB_WORKFLOW\`
🆔 *运行 ID:* \`$GITHUB_RUN_ID\`

⚡ *SSH 命令:*
\`${SSH_CMD}\`"

        if [[ -n "${SSH_PASSWORD}" ]]; then
            MSG+="
🔑 *密码:* \`${SSH_PASSWORD}\`"
        fi

        MSG+="

🔔 *下一步:*
在工作流运行器中执行 \`touch ${CONTINUE_FILE}\` 继续

💡 *提示:*
会话将在 30 分钟后自动终止"
        
        # 发送通知
        TELEGRAM_RESPONSE=$(curl -sSX POST \
            "${TELEGRAM_API_URL:-https://api.telegram.org}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "disable_web_page_preview=true" \
            -d "parse_mode=Markdown" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${MSG}" 2>&1)
        
        # 检查发送结果
        if echo "${TELEGRAM_RESPONSE}" | grep -q '"ok":true'; then
            echo -e "${INFO} Telegram 通知发送成功"
        else
            echo -e "${WARN} Telegram 通知发送失败: ${TELEGRAM_RESPONSE}"
        fi
    fi
}

# 显示连接信息
display_connection_info() {
    echo -e "\n${Green_font_prefix}=============================================="
    echo "=           SSH 连接信息               ="
    echo "=============================================="
    echo -e "命令: ${SSH_CMD}${Font_color_suffix}"
    
    if [[ -n "${SSH_PASSWORD}" ]]; then
        echo -e "${Yellow_font_prefix}密码: ${SSH_PASSWORD}${Font_color_suffix}"
    fi
    
    echo -e "\n${Green_font_prefix}连接后执行以下命令继续工作流:"
    echo -e "touch ${CONTINUE_FILE}${Font_color_suffix}"
    echo -e "${Green_font_prefix}==============================================${Font_color_suffix}\n"
}

# 等待继续信号
wait_for_continue() {
    echo -e "${INFO} 等待继续信号 (${CONTINUE_FILE})..."
    echo -e "${INFO} 会话将在 30 分钟后自动终止"
    
    local start_time=$(date +%s)
    local timeout=1800  # 30 分钟超时
    
    while [[ ! -e "${CONTINUE_FILE}" ]]; do
        # 检查隧道是否仍在运行
        if ! screen -list | grep -q "cloudflared"; then
            echo -e "${ERROR} Cloudflared 隧道意外终止"
            exit 6
        fi
        
        # 计算已过时间和剩余时间
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        local remaining=$((timeout - elapsed))
        
        # 检查是否超时
        if [[ $remaining -le 0 ]]; then
            echo -e "${ERROR} 等待超时，工作流将继续"
            break
        fi
        
        # 显示剩余时间
        local minutes=$((remaining / 60))
        local seconds=$((remaining % 60))
        printf "${INFO} 剩余时间: %02d分%02d秒\r" "$minutes" "$seconds"
        sleep 5
    done
    
    echo -e "${INFO} 检测到继续信号，退出..."
}

# 主函数
main() {
    # 安装必要组件
    install_cloudflared
    
    # 配置 SSH 服务
    configure_ssh
    
    # 启动隧道
    start_cloudflared_tunnel
    
    # 发送通知
    send_telegram_notification
    
    # 显示连接信息
    display_connection_info
    
    # 等待继续信号
    wait_for_continue
    
    exit 0
}

# 执行主函数
main
