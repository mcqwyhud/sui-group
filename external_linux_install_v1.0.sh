#!/bin/bash
# SUI External 一键安装脚本（最终修复版）
# 修复了 JVM 参数硬编码导致无法更新的问题，默认参数已适配 Spring Boot 实际需求

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
    local tools=("wget" "curl" "tar" "jq" "openssl")
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
# 用户 & 目录 & 默认配置
# -------------------------------
setup_user_and_dir() {
    print_info "创建用户与目录"
    id suiexternal &>/dev/null || useradd -r -s /bin/false suiexternal
    mkdir -p /opt/sui-external/{config,logs,uploads,conf,tmp,jprotobuf-cache}

    # 【修改点1】：直接使用你测试通过的最佳参数作为默认值
    cat > /opt/sui-external/conf/jvm_opts <<EOF
-Xms64m -Xmx128m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=32m
EOF

    chown -R suiexternal:suiexternal /opt/sui-external
}

# -------------------------------
# external.json 交互配置
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
# GitHub 下载
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
# systemd 服务
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
# suie-cli（含更新命令的美化版 CLI）
# -------------------------------
create_custom_command() {
cat > /usr/local/bin/sui-e <<'EOF'
#!/bin/bash

CONF=/opt/sui-external/conf/jvm_opts
SERVICE_FILE=/etc/systemd/system/sui-external.service

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'
NC='\033[0m' # 恢复默认颜色
GRAY='\033[0;90m'

# 帮助信息函数
usage() {
    echo -e "${CYAN}================================================${NC}"
    echo -e "        ${PURPLE}🚀 SUI External 管理工具 (sui-e)${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e "${YELLOW}【 服务控制 】${NC}"
    echo -e "  sui-e ${GREEN}start${NC}        启动服务"
    echo -e "  sui-e ${GREEN}stop${NC}         停止服务"
    echo -e "  sui-e ${GREEN}restart${NC}      重启服务"
    echo -e "  sui-e ${GREEN}status${NC}       查看运行状态"
    echo -e "  sui-e ${GREEN}logs${NC}         查看实时日志 (Ctrl+C 退出)"
    echo ""
    echo -e "${YELLOW}【 更新与参数 】${NC}"
    echo -e "  sui-e ${GREEN}update${NC}       拉取最新版本并自动重启"
    echo -e "  sui-e ${GREEN}jvm${NC}          查看当前 JVM 参数"
    echo -e "  sui-e ${GREEN}set-jvm${NC} ${GRAY}\"-Xms... -Xmx...\"${NC}"
    echo -e "                   设置新的 JVM 参数并同步到服务"
    echo -e "${CYAN}================================================${NC}"
}

# 处理空输入
if [ -z "$1" ]; then
    usage
    exit 0
fi

case "$1" in
start) 
    systemctl start sui-external 
    echo -e "${GREEN}✔ 服务已启动${NC}"
    ;;
stop) 
    systemctl stop sui-external 
    echo -e "${GREEN}✔ 服务已停止${NC}"
    ;;
restart) 
    systemctl restart sui-external 
    echo -e "${GREEN}✔ 服务已重启${NC}"
    ;;
status) 
    systemctl status sui-external 
    ;;
logs) 
    journalctl -u sui-external -f 
    ;;

# 更新逻辑
update)
    echo -e "${CYAN}================================================${NC}"
    echo -e "        ${PURPLE}🔄 SUI External 版本更新${NC}"
    echo -e "${CYAN}================================================${NC}"
    read -s -p "请输入 GitHub Token 以拉取最新版本: " TOKEN
    echo ""
    if [ -z "$TOKEN" ]; then
        echo -e "${RED}✘ 错误: Token 不能为空！${NC}"
        exit 1
    fi

    REPO="mcqwyhud/sui-external"
    API="https://api.github.com/repos/$REPO/releases/latest"
    
    echo -e "${YELLOW}正在检查最新版本...${NC}"
    RESP=$(curl -s -H "Authorization: token $TOKEN" "$API")

    VERSION=$(echo "$RESP" | jq -r '.tag_name')
    JAR=$(echo "$RESP" | jq -r '.assets[] | select(.name|endswith(".jar")) | .name' | head -1)
    ID=$(echo "$RESP" | jq -r '.assets[] | select(.name|endswith(".jar")) | .id' | head -1)

    if [ -z "$JAR" ] || [ "$JAR" = "null" ]; then
        echo -e "${RED}✘ 获取版本信息失败，请检查 Token 权限或网络。${NC}"
        exit 1
    fi

    echo -e "${GREEN}✔ 发现最新版本: $VERSION${NC}"
    echo -e "   文件: $JAR"

    systemctl stop sui-external
    echo -e "${YELLOW}✔ 服务已暂停，正在下载...${NC}"

    URL="https://api.github.com/repos/$REPO/releases/assets/$ID"
    wget --header="Authorization: token $TOKEN" \
         --header="Accept: application/octet-stream" \
         -O "/opt/sui-external/$JAR" "$URL"

    if [ $? -eq 0 ]; then
        chown suiexternal:suiexternal "/opt/sui-external/$JAR"
        echo -e "${GREEN}✔ 下载完成，正在启动服务...${NC}"
        systemctl start sui-external
        echo -e "${GREEN}✔ 更新成功！当前版本: $VERSION${NC}"
        
        # 清理旧版 JAR（防止硬盘占用）
        for old_jar in /opt/sui-external/*.jar; do
            if [ "$(basename "$old_jar")" != "$JAR" ]; then
                echo -e "${YELLOW}🗑 清理旧版本: $(basename "$old_jar")${NC}"
                rm -f "$old_jar"
            fi
        done
    else
        echo -e "${RED}✘ 下载失败，正在恢复旧服务。${NC}"
        systemctl start sui-external
    fi
    ;;

# 查看/设置参数
jvm)
    if [ "$2" = "set" ] && [ -n "$3" ]; then
        echo "$3" > "$CONF"
        sed -i -E "s|^(ExecStart=/usr/bin/java ).*( -jar .*)$|\1$3\2|" "$SERVICE_FILE"
        systemctl daemon-reload
        echo -e "${GREEN}✔ JVM 参数已更新并同步！${NC}"
        echo -e "${YELLOW}⚠ 请执行 ${NC}sui-e restart${YELLOW} 使参数生效${NC}"
    else
        echo -e "${CYAN}当前 JVM 参数:${NC}"
        echo -e "${GRAY}$(cat "$CONF")${NC}"
    fi
    ;;

# 设置参数
set-jvm)
    if [ -z "$2" ]; then
        echo -e "${RED}✘ 错误: 缺少参数！${NC}"
        echo -e "用法: sui-e set-jvm ${GRAY}\"-Xms64m -Xmx128m ...\"${NC}"
        exit 1
    fi
    echo "$2" > "$CONF"
    sed -i -E "s|^(ExecStart=/usr/bin/java ).*( -jar .*)$|\1$2\2|" "$SERVICE_FILE"
    systemctl daemon-reload
    echo -e "${GREEN}✔ JVM 参数已更新并同步！${NC}"
    echo -e "${YELLOW}⚠ 请执行 ${NC}sui-e restart${YELLOW} 使参数生效${NC}"
    ;;

-h|--help|help)
    usage
    ;;
*)
    echo -e "${RED}✘ 未知命令: $1${NC}"
    echo ""
    usage
    ;;
esac
EOF
chmod +x /usr/local/bin/sui-e
}

# -------------------------------
# 缓存清理
# -------------------------------
cleanup_caches() {
    print_info "清理缓存"
    rm -rf /tmp/JPROTOBUF_CACHE_DIR || true
    mkdir -p /opt/sui-external/jprotobuf-cache
    mkdir -p /opt/sui-external/tmp
    chown -R suiexternal:suiexternal /opt/sui-external
}

# -------------------------------
# 提示信息
# -------------------------------
show_complete() {
    echo ""
    echo "===================================="
    echo "SUI External 安装完成"
    echo "===================================="
    echo "管理命令:"
    echo "  sui-e start / stop / restart"
    echo "  sui-e update         # 更新最新版"
    echo "  sui-e logs"
    echo "  sui-e jvm"
    echo "  sui-e set-jvm \"...\""
    echo ""
}

# -------------------------------
# 主流程
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
