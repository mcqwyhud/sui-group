#!/bin/bash
# ==============================
# SUI + SUI-Agent 一键安装脚本
# ==============================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log(){ echo -e "${GREEN}[INFO]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------
# 1. 基础依赖
# ------------------------------
install_base() {
    log "安装基础依赖..."
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y curl wget jq sqlite3
    else
        yum install -y curl wget jq sqlite
    fi
}

# ------------------------------
# 2. 安装 s-ui（官方）
# ------------------------------
install_sui() {
    log "安装 s-ui..."

    curl -sSL https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh | bash

    sleep 5

    systemctl enable s-ui --now
}

# ------------------------------
# 3. 等待 s-ui API 就绪
# ------------------------------
wait_sui() {
    log "等待 s-ui 启动..."

    for i in {1..30}; do
        if curl -s http://127.0.0.1:2095 >/dev/null; then
            log "s-ui 已启动"
            return
        fi
        sleep 2
    done

    err "s-ui 启动失败"
    exit 1
}

# ------------------------------
# 4. 创建 API Token（官方API方式）
# ------------------------------
create_token() {

    log "创建 API Token..."

    USER_ID=$(sqlite3 /usr/local/s-ui/db/s-ui.db "SELECT id FROM users LIMIT 1;")

    if [ -z "$USER_ID" ]; then
        err "无法获取 user_id"
        exit 1
    fi

    API_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d "=+/")

    sqlite3 /usr/local/s-ui/db/s-ui.db <<EOF
INSERT INTO tokens (desc, token, expiry, user_id)
VALUES ('auto-install-token', '$API_TOKEN', 0, $USER_ID);
EOF

    log "API Token 创建完成"
    echo "$API_TOKEN" > /tmp/sui_api_token
}

# ------------------------------
# 5. 安装 sui-agent
# ------------------------------
install_agent() {
    log "安装 sui-agent..."

    API_TOKEN=$(cat /tmp/sui_api_token)

    curl -sSL https://raw.githubusercontent.com/mcqwyhud/sui-group/main/agent_linux_install_v1.0.sh -o /tmp/agent.sh
    chmod +x /tmp/agent.sh

    # 传 token 给 agent
    bash /tmp/agent.sh "$API_TOKEN"
}

# ------------------------------
# 6. 主流程
# ------------------------------
main() {
    install_base
    install_sui
    wait_sui
    create_token
    install_agent

    log "安装完成"
    echo ""
    echo "============================"
    echo "SUI + Agent 安装完成"
    echo "API TOKEN: $(cat /tmp/sui_api_token)"
    echo "============================"
}

main
