#!/bin/bash

set -e

# =========================
# 🔥 修复：恢复交互输入（关键）
# =========================
exec < /dev/tty

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行"
        exit 1
    fi
}

detect_os() {
    . /etc/os-release
    OS=$ID
    print_info "系统: $OS"
}

install_base() {
    print_info "检查基础工具..."

    local tools=("wget" "curl" "tar" "tzdata" "jq")
    local missing=()

    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done

    [ ${#missing[@]} -eq 0 ] && return

    print_info "安装: ${missing[*]}"

    case "$OS" in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y "${missing[@]}"
            ;;
        centos|rhel|almalinux|rocky)
            yum install -y "${missing[@]}"
            ;;
    esac
}

install_java() {
    command -v java &>/dev/null && return

    print_info "安装 Java..."

    case "$OS" in
        ubuntu|debian)
            apt-get install -y openjdk-21-jre-headless
            ;;
        *)
            yum install -y java-21-openjdk-headless
            ;;
    esac
}

setup_user_and_dir() {
    id suiagent &>/dev/null || useradd -r -s /bin/false suiagent

    mkdir -p /opt/sui-agent/{config,logs,data,conf}
    chown -R suiagent:suiagent /opt/sui-agent
}

download_jar() {
    print_info "下载 JAR..."

    GITHUB_REPO="mcqwyhud/sui-agent"
    RELEASE_URL="https://api.github.com/repos/$GITHUB_REPO/releases/latest"

    if [ -z "$GITHUB_TOKEN" ]; then
        read -p "请输入 GitHub Token: " GITHUB_TOKEN
    fi

    API=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$RELEASE_URL")

    JAR_NAME=$(echo "$API" | jq -r '.assets[]|select(.name|endswith(".jar"))|.name' | head -1)

    wget --header="Authorization: token $GITHUB_TOKEN" \
         -O "/opt/sui-agent/$JAR_NAME" \
         "https://github.com/$GITHUB_REPO/releases/latest/download/$JAR_NAME"

    chown suiagent:suiagent "/opt/sui-agent/$JAR_NAME"
}

# =========================
# 🔥 你原本完整 JSON 配置（必须保留）
# =========================
setup_json_config() {

    print_info "初始化 JSON 配置..."

    CONFIG_FILE="/opt/sui-agent/config/external.json"

    brokerKey_def="xxx"
    brokerHost_def="127.0.0.1"
    brokerPort_def="10200"

    agentName_def="节点1"
    agentTag_def="节点"

    if [ -f "$CONFIG_FILE" ]; then
        old=$(cat "$CONFIG_FILE")
        brokerKey=$(echo "$old" | jq -r '.brokerKey')
        brokerHost=$(echo "$old" | jq -r '.brokerHost')
        brokerPort=$(echo "$old" | jq -r '.brokerPort')
        agentName=$(echo "$old" | jq -r '.agentName')
    fi

    # 👉 这里才是交互输入
    read -p "brokerKey [$brokerKey_def]: " brokerKey
    brokerKey=${brokerKey:-$brokerKey_def}

    read -p "brokerHost [$brokerHost_def]: " brokerHost
    brokerHost=${brokerHost:-$brokerHost_def}

    read -p "brokerPort [$brokerPort_def]: " brokerPort
    brokerPort=${brokerPort:-$brokerPort_def}

    read -p "agentName [$agentName_def]: " agentName
    agentName=${agentName:-$agentName_def}

    cat > "$CONFIG_FILE" <<EOF
{
  "brokerKey": "$brokerKey",
  "brokerHost": "$brokerHost",
  "brokerPort": $brokerPort,
  "agentName": "$agentName"
}
EOF

    chown suiagent:suiagent "$CONFIG_FILE"
}

create_service() {
    JAR=$(ls /opt/sui-agent/*.jar | head -1)

    cat > /etc/systemd/system/sui-agent.service <<EOF
[Unit]
Description=SUI Agent
After=network.target

[Service]
User=suiagent
WorkingDirectory=/opt/sui-agent
ExecStart=/usr/bin/java -jar $JAR
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sui-agent
}

start_service() {
    systemctl start sui-agent
}

main() {
    check_root
    detect_os
    install_base
    install_java
    setup_user_and_dir
    download_jar
    setup_json_config   # ✅ 关键：必须有
    create_service
    start_service

    print_info "安装完成"
}

main
