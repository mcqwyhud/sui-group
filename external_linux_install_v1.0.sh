#!/bin/bash
# SUI External 一键安装脚本（修复完整版）
# 在新版基础上完整补回旧版能力（非简化版）

set -e

# -------------------------------
# 颜色
# -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# -------------------------------
# 检查 root
# -------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行"
        exit 1
    fi
}

# -------------------------------
# OS检测
# -------------------------------
detect_os() {
    . /etc/os-release
    OS=$ID
    print_info "系统: $OS"
}

# -------------------------------
# 基础工具
# -------------------------------
install_base() {
    print_info "检查基础工具..."

    local tools=("wget" "curl" "tar" "jq")
    local missing=()

    for t in "${tools[@]}"; do
        command -v "$t" >/dev/null || missing+=("$t")
    done

    [ ${#missing[@]} -eq 0 ] && return

    print_info "安装: ${missing[*]}"

    case "$OS" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq "${missing[@]}"
            ;;
        centos|almalinux|rocky|rhel)
            yum install -y -q "${missing[@]}"
            ;;
        fedora)
            dnf install -y -q "${missing[@]}"
            ;;
    esac
}

# -------------------------------
# Java安装
# -------------------------------
install_java() {
    if command -v java &>/dev/null; then
        v=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
        [ "$v" -ge 21 ] && return
    fi

    print_info "安装 Java 21"
    cd /tmp
    wget -q https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.deb
    apt install -y ./jdk-21_linux-x64_bin.deb
}

# -------------------------------
# 用户 & 目录
# -------------------------------
setup_user_and_dir() {
    print_info "创建用户与目录"

    id suiexternal &>/dev/null || useradd -r -s /bin/false suiexternal

    mkdir -p /opt/sui-external/{config,logs,uploads,conf,tmp,jprotobuf-cache}

    cat > /opt/sui-external/conf/jvm_opts <<EOF
-Xms64m -Xmx128m -XX:MaxMetaspaceSize=64m
EOF

    chown -R suiexternal:suiexternal /opt/sui-external
}

# -------------------------------
# external.json 交互配置（保留你原逻辑）
# -------------------------------
configure_external_json() {
    CONFIG="/opt/sui-external/config/external.json"

    DEFAULT_NAME="游戏对逻辑外服1"
    DEFAULT_TAG="游戏对逻辑外服"
    DEFAULT_PORT=28688
    DEFAULT_BROKER_HOST="127.0.0.1"
    DEFAULT_BROKER_PORT=10200

    EXISTING_PID=""

    if [ -f "$CONFIG" ]; then
        EXISTING_PID=$(jq -r '.pid' "$CONFIG" 2>/dev/null || echo "")
        print_warning "已存在 external.json"

        echo "1) 使用现有"
        echo "2) 重新配置"
        read -p "选择: " c

        [ "$c" = "1" ] && return
    fi

    read -p "port [$DEFAULT_PORT]: " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    read -p "brokerHost [$DEFAULT_BROKER_HOST]: " BROKER_HOST
    BROKER_HOST=${BROKER_HOST:-$DEFAULT_BROKER_HOST}

    read -p "brokerPort [$DEFAULT_BROKER_PORT]: " BROKER_PORT
    BROKER_PORT=${BROKER_PORT:-$DEFAULT_BROKER_PORT}

    read -p "brokerKey(自动生成): " BROKER_KEY
    if [ -z "$BROKER_KEY" ]; then
        BROKER_KEY=$(openssl rand -base64 32 2>/dev/null || date +%s | sha256sum | base64 | head -c 32)
    fi

    PID=${EXISTING_PID:-$(date +%s%N | sha256sum | cut -c1-32)}

    cat > "$CONFIG" <<EOF
{
  "port": $PORT,
  "brokerKey": "$BROKER_KEY",
  "brokerHost": "$BROKER_HOST",
  "brokerPort": $BROKER_PORT,
  "pid": "$PID",
  "name": "$DEFAULT_NAME",
  "tag": "$DEFAULT_TAG",
  "webEnable": true
}
EOF

    chown suiexternal:suiexternal "$CONFIG"
}

# -------------------------------
# GitHub 下载（完整旧版逻辑）
# -------------------------------
download_jar() {
    print_info "下载 JAR"

    REPO="mcqwyhud/sui-external"
    API="https://api.github.com/repos/$REPO/releases/latest"

    [ -z "$GITHUB_TOKEN" ] && read -s -p "GitHub Token: " GITHUB_TOKEN && echo ""

    RESP=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$API")

    VERSION=$(echo "$RESP" | jq -r '.tag_name')
    JAR=$(echo "$RESP" | jq -r '.assets[] | select(.name|endswith(".jar")) | .name' | head -1)
    ID=$(echo "$RESP" | jq -r '.assets[] | select(.name|endswith(".jar")) | .id' | head -1)

    print_info "版本: $VERSION"
    print_info "文件: $JAR"

    URL="https://api.github.com/repos/$REPO/releases/assets/$ID"

    wget --header="Authorization: token $GITHUB_TOKEN" \
         --header="Accept: application/octet-stream" \
         -O "/opt/sui-external/$JAR" "$URL"

    chown suiexternal:suiexternal "/opt/sui-external/$JAR"
}

# -------------------------------
# systemd 服务（完整版）
# -------------------------------
create_service() {
    JAR=$(ls /opt/sui-external/*.jar | head -1)
    JVM=$(cat /opt/sui-external/conf/jvm_opts)

    cat > /etc/systemd/system/sui-external.service <<EOF
[Unit]
Description=SUI External
After=network.target

[Service]
User=suiexternal
WorkingDirectory=/opt/sui-external
ExecStart=/usr/bin/java $JVM -jar $JAR
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sui-external
}

# -------------------------------
# suie-cli（完整恢复版）
# -------------------------------
create_custom_command() {
cat > /usr/local/bin/sui-e <<'EOF'
#!/bin/bash

CONF=/opt/sui-external/conf/jvm_opts

case "$1" in
start) systemctl start sui-external ;;
stop) systemctl stop sui-external ;;
restart) systemctl restart sui-external ;;
status) systemctl status sui-external ;;
logs) journalctl -u sui-external -f ;;
jvm)
    cat "$CONF"
    ;;
set-jvm)
    echo "$2" > "$CONF"
    systemctl daemon-reload
    echo "JVM已更新"
    ;;
*)
    echo "sui-e start|stop|restart|status|logs|jvm|set-jvm"
    ;;
esac
EOF

chmod +x /usr/local/bin/sui-e
}

# -------------------------------
# 缓存清理（旧版恢复）
# -------------------------------
cleanup_caches() {
    print_info "清理缓存"

    rm -rf /tmp/JPROTOBUF_CACHE_DIR || true

    mkdir -p /opt/sui-external/jprotobuf-cache
    mkdir -p /opt/sui-external/tmp

    chown -R suiexternal:suiexternal /opt/sui-external
}

# -------------------------------
# 完整安装提示（你缺失的 show_complete）
# -------------------------------
show_complete() {
    echo ""
    echo "===================================="
    echo "SUI External 安装完成"
    echo "===================================="
    echo ""
    echo "管理命令:"
    echo "  sui-e start"
    echo "  sui-e stop"
    echo "  sui-e restart"
    echo "  sui-e status"
    echo "  sui-e logs"
    echo "  sui-e jvm"
    echo "  sui-e set-jvm \"...\""
    echo ""
    echo "systemd:"
    echo "  systemctl start sui-external"
    echo ""
    echo "配置: /opt/sui-external/config"
    echo "日志: /opt/sui-external/logs"
    echo ""
}

# -------------------------------
# 主流程（不删你结构）
# -------------------------------
main() {
    check_root
    detect_os

    install_base
    install_java
    setup_user_and_dir

    configure_external_json

    download_jar
    create_service
    create_custom_command

    cleanup_caches

    systemctl daemon-reload
    systemctl start sui-external

    show_complete
}

main "$@"
