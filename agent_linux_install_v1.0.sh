#!/bin/bash
# SUI Agent 一键安装脚本
# 支持 Linux 系统，自动安装依赖，从私有仓库下载 jar 并部署为 systemd 服务
# 改进：使用 jq + assets API，增加 SHA256 校验，支持 JVM 参数动态修改
# 注意：Agent 为 iogame 应用，无 Spring Boot，无需 jprotobuf-cache 和 tmp 目录

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        print_error "无法检测操作系统"
        exit 1
    fi
    print_info "检测到操作系统: $OS $VERSION"
}

install_base() {
    print_info "检查基础工具..."
    local tools=("wget" "curl" "tar" "tzdata" "jq")
    local missing_tools=()
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            if [ "$tool" != "tzdata" ]; then
                missing_tools+=("$tool")
            fi
        fi
    done
    if [ ! -d "/usr/share/zoneinfo" ]; then
        missing_tools+=("tzdata")
    fi
    if [ ${#missing_tools[@]} -eq 0 ]; then
        print_info "基础工具已安装 (wget, curl, tar, tzdata, jq)"
        return 0
    fi
    print_info "需要安装的工具: ${missing_tools[*]}"
    local need_update=false
    case "${OS}" in
        ubuntu|debian)
            if [ ! -f /var/lib/apt/lists/lock ] || [ $(find /var/lib/apt/lists/ -name "*.deb" -mtime +1 2>/dev/null | wc -l) -gt 0 ]; then
                need_update=true
            fi
            ;;
        centos|almalinux|rocky|oracle|rhel|fedora)
            if [ ! -f /var/cache/yum/timestamp.txt ] || [ $(find /var/cache/yum -name "*.rpm" -mtime +1 2>/dev/null | wc -l) -gt 0 ]; then
                need_update=true
            fi
            ;;
    esac
    if [ "$need_update" = true ]; then
        print_info "更新软件包缓存..."
        case "${OS}" in
            ubuntu|debian) apt-get update -qq ;;
            centos|almalinux|rocky|oracle|rhel) yum makecache -q ;;
            fedora) dnf makecache -q ;;
            arch|manjaro|parch) pacman -Sy --noconfirm --quiet ;;
            opensuse-tumbleweed) zypper refresh -q ;;
        esac
    fi
    print_info "安装缺失的基础工具..."
    case "${OS}" in
        ubuntu|debian)
            apt-get install -y -qq "${missing_tools[@]}"
            ;;
        centos|almalinux|rocky|oracle|rhel)
            yum install -y -q "${missing_tools[@]}"
            ;;
        fedora)
            dnf install -y -q "${missing_tools[@]}"
            ;;
        arch|manjaro|parch)
            pacman -Syu --noconfirm --quiet "${missing_tools[@]}"
            ;;
        opensuse-tumbleweed)
            zypper -q install -y "${missing_tools[@]}"
            ;;
        *)
            print_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
    print_info "基础工具安装完成"
}

install_java() {
    print_info "检查 Java 环境..."
    if command -v java &> /dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
        if [ "$JAVA_VERSION" -ge 21 ]; then
            print_info "已安装 Java 版本: $(java -version 2>&1 | head -1)"
            return
        fi
    fi
    print_info "正在安装 Java 21..."
    case "${OS}" in
        ubuntu|debian)
            apt-get update
            apt-get install -y openjdk-21-jre-headless
            ;;
        centos|rhel|almalinux|rocky|oracle)
            yum install -y java-21-openjdk-headless
            ;;
        fedora)
            dnf install -y java-21-openjdk-headless
            ;;
        *)
            print_error "不支持的操作系统: $OS，请手动安装 Java 21"
            exit 1
            ;;
    esac
    if command -v java &> /dev/null; then
        print_info "Java 安装成功: $(java -version 2>&1 | head -1)"
    else
        print_error "Java 安装失败"
        exit 1
    fi
}

setup_user_and_dir() {
    print_info "创建用户和目录..."
    if ! id -u suiagent &> /dev/null; then
        useradd -r -s /bin/false suiagent
        print_info "用户 suiagent 创建成功"
    fi
    # 只需要基础目录，无 jprotobuf-cache 和 tmp
    mkdir -p /opt/sui-agent/{config,logs,data,conf}
    chown -R suiagent:suiagent /opt/sui-agent
    chmod 755 /opt/sui-agent/logs
    chmod 755 /opt/sui-agent/conf

    JVM_CONF="/opt/sui-agent/conf/jvm_opts"
    if [ ! -f "$JVM_CONF" ]; then
        echo "-Xms64m -Xmx128m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=32m" > "$JVM_CONF"
        chown suiagent:suiagent "$JVM_CONF"
        print_info "默认 JVM 参数已写入 $JVM_CONF"
    fi
    print_info "目录创建完成"
}

download_jar() {
    print_info "下载文件..."
    GITHUB_REPO="mcqwyhud/sui-agent"
    RELEASE_URL="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
    if [ -z "$GITHUB_TOKEN" ]; then
        echo ""
        print_info "请输入 GitHub 个人访问令牌（需有 repo 权限）:"
        read -s GITHUB_TOKEN
        echo ""
    fi
    if [ -z "$GITHUB_TOKEN" ]; then
        print_error "未提供 GitHub 令牌，无法访问私有仓库"
        exit 1
    fi
    print_info "获取最新版本信息..."
    API_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$RELEASE_URL")
    if echo "$API_RESPONSE" | grep -q '"message"'; then
        ERROR_MSG=$(echo "$API_RESPONSE" | grep -o '"message": "[^"]*"' | cut -d'"' -f4)
        print_error "API 请求失败: $ERROR_MSG"
        exit 1
    fi
    LATEST_VERSION=$(echo "$API_RESPONSE" | jq -r '.tag_name // empty')
    if [ -z "$LATEST_VERSION" ]; then
        print_error "无法获取最新版本"
        exit 1
    fi
    print_info "最新版本: $LATEST_VERSION"
    JAR_NAME=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar")) | .name' | head -1)
    ASSET_ID=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar")) | .id' | head -1)
    EXPECTED_SHA256=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar")) | .digest // ""' | head -1 | sed 's/^sha256://')
    if [ -z "$JAR_NAME" ] || [ -z "$ASSET_ID" ]; then
        print_error "发布版本中未找到 jar 文件"
        exit 1
    fi
    print_info "JAR 文件名: $JAR_NAME"
    ASSETS_DOWNLOAD_URL="https://api.github.com/repos/$GITHUB_REPO/releases/assets/$ASSET_ID"
    print_info "通过 assets API 下载 JAR 文件..."
    DOWNLOAD_ERROR=false
    if command -v wget &> /dev/null; then
        wget --header="Authorization: token $GITHUB_TOKEN" \
             --header="Accept: application/octet-stream" \
             -O "/opt/sui-agent/$JAR_NAME" "$ASSETS_DOWNLOAD_URL" || DOWNLOAD_ERROR=true
    else
        curl -L -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/octet-stream" \
             -o "/opt/sui-agent/$JAR_NAME" "$ASSETS_DOWNLOAD_URL" || DOWNLOAD_ERROR=true
    fi
    if [ "$DOWNLOAD_ERROR" = true ] || [ ! -f "/opt/sui-agent/$JAR_NAME" ]; then
        print_warning "assets API 下载失败，尝试使用标准 Release URL..."
        STANDARD_URL="https://github.com/$GITHUB_REPO/releases/download/$LATEST_VERSION/$JAR_NAME"
        DOWNLOAD_ERROR=false
        if command -v wget &> /dev/null; then
            wget --header="Authorization: token $GITHUB_TOKEN" \
                 -O "/opt/sui-agent/$JAR_NAME" "$STANDARD_URL" || DOWNLOAD_ERROR=true
        else
            curl -L -H "Authorization: token $GITHUB_TOKEN" \
                 -o "/opt/sui-agent/$JAR_NAME" "$STANDARD_URL" || DOWNLOAD_ERROR=true
        fi
        if [ "$DOWNLOAD_ERROR" = true ] || [ ! -f "/opt/sui-agent/$JAR_NAME" ]; then
            print_error "所有下载方式均失败"
            exit 1
        fi
    fi
    FILE_SIZE=$(stat -c%s "/opt/sui-agent/$JAR_NAME" 2>/dev/null || stat -f%z "/opt/sui-agent/$JAR_NAME" 2>/dev/null)
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        print_error "文件大小异常: $FILE_SIZE 字节"
        exit 1
    fi
    if [ -n "$EXPECTED_SHA256" ]; then
        LOCAL_SHA256=$(sha256sum "/opt/sui-agent/$JAR_NAME" | awk '{print $1}')
        if [ "$LOCAL_SHA256" != "$EXPECTED_SHA256" ]; then
            print_error "SHA256 校验失败！"
            exit 1
        fi
        print_info "SHA256 校验通过 ✓"
    else
        print_warning "未获取到 digest 信息，跳过 SHA256 校验"
    fi
    print_info "文件下载完成 (大小: $(numfmt --to=iec $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes"))"
    chown suiagent:suiagent "/opt/sui-agent/$JAR_NAME"
}

get_jvm_opts() {
    JVM_CONF="/opt/sui-agent/conf/jvm_opts"
    if [ -f "$JVM_CONF" ]; then
        cat "$JVM_CONF"
    else
        echo "-Xms64m -Xmx128m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=32m"
    fi
}

create_service() {
    print_info "创建 systemd 服务..."
    JAR_FILE=$(ls /opt/sui-agent/*.jar | head -1)
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        exit 1
    fi
    print_info "使用 JAR 文件: $JAR_FILE"
    JVM_OPTS=$(get_jvm_opts)
    # Agent 无 Spring Boot，不需要 jprotobuf 相关参数
    SERVICE_FILE="/etc/systemd/system/sui-agent.service"
    > "$SERVICE_FILE"
    cat >> "$SERVICE_FILE" <<EOF
[Unit]
Description=SUI Agent Service
After=network.target

[Service]
Type=simple
User=suiagent
WorkingDirectory=/opt/sui-agent
ExecStart=/usr/bin/java ${JVM_OPTS} -jar ${JAR_FILE}
Restart=on-failure
RestartSec=10
# 日志由应用自身管理，不再使用 StandardOutput/Error 避免权限问题
Environment=JAVA_OPTS=${JVM_OPTS}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sui-agent
    print_info "systemd 服务创建完成"
}

start_service() {
    print_info "启动 SUI Agent 服务..."
    systemctl start sui-agent
    sleep 3
    if systemctl is-active --quiet sui-agent; then
        print_info "服务启动成功"
    else
        print_error "服务启动失败，请查看日志: journalctl -u sui-agent"
        exit 1
    fi
}

create_custom_command() {
    print_info "创建自定义命令 sui-a ..."
    cat > /usr/local/bin/sui-a << 'EOF'
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

JVM_CONF="/opt/sui-agent/conf/jvm_opts"
SERVICE_FILE="/etc/systemd/system/sui-agent.service"

show_jvm() {
    if [ -f "$JVM_CONF" ]; then
        echo "当前 JVM 参数: $(cat "$JVM_CONF")"
    else
        echo "默认 JVM 参数: -Xms64m -Xmx128m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=32m"
    fi
}

set_jvm() {
    local new_opts="$1"
    if [ -z "$new_opts" ]; then
        print_error "请提供新的 JVM 参数，例如: -Xms128m -Xmx256m"
        exit 1
    fi
    if [ -f "$JVM_CONF" ]; then
        cp "$JVM_CONF" "$JVM_CONF.bak"
    fi
    echo "$new_opts" > "$JVM_CONF"
    chown suiagent:suiagent "$JVM_CONF"
    print_info "JVM 参数已更新: $new_opts"
    JAR_FILE=$(ls /opt/sui-agent/*.jar | head -1)
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        exit 1
    fi
    sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/java ${new_opts} -jar ${JAR_FILE}|" "$SERVICE_FILE"
    systemctl daemon-reload
    print_info "systemd 服务文件已更新"
    read -p "是否立即重启 SUI Agent 服务以应用新参数？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl restart sui-agent
        print_info "服务已重启"
    else
        print_info "请手动执行 'sui-a restart' 使参数生效"
    fi
}

interactive_jvm() {
    echo "当前 JVM 参数:"
    show_jvm
    echo ""
    read -p "请输入新的 JVM 参数（直接回车保持不变）: " new_opts
    if [ -n "$new_opts" ]; then
        set_jvm "$new_opts"
    else
        print_info "未做任何修改"
    fi
}

case "$1" in
    start)
        systemctl start sui-agent
        echo "SUI Agent 服务已启动"
        ;;
    stop)
        systemctl stop sui-agent
        echo "SUI Agent 服务已停止"
        ;;
    restart)
        systemctl restart sui-agent
        echo "SUI Agent 服务已重启"
        ;;
    status)
        systemctl status sui-agent
        ;;
    logs)
        journalctl -u sui-agent -f
        ;;
    jvm)
        case "$2" in
            show|"")
                show_jvm
                ;;
            set)
                set_jvm "$3"
                ;;
            *)
                interactive_jvm
                ;;
        esac
        ;;
    *)
        echo "用法: sui-a {start|stop|restart|status|logs|jvm [show|set \"JVM_OPTS\"]}"
        echo ""
        echo "  jvm              - 交互式修改 JVM 参数"
        echo "  jvm show         - 显示当前 JVM 参数"
        echo "  jvm set \"...\"    - 设置新的 JVM 参数（完整字符串）"
        echo "  示例: sui-a jvm set \"-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m\""
        exit 1
        ;;
esac
EOF
    chmod +x /usr/local/bin/sui-a
    print_info "自定义命令创建完成"
}

show_complete() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}SUI Agent 安装完成！${NC}"
    echo "=========================================="
    echo ""
    echo "管理命令："
    echo "  sui-a start       # 启动服务"
    echo "  sui-a stop        # 停止服务"
    echo "  sui-a restart     # 重启服务"
    echo "  sui-a status      # 查看状态"
    echo "  sui-a logs        # 查看日志"
    echo "  sui-a jvm         # 交互式修改 JVM 参数"
    echo "  sui-a jvm show    # 显示当前 JVM 参数"
    echo "  sui-a jvm set \"...\" # 直接设置 JVM 参数"
    echo ""
    echo "或者使用 systemctl："
    echo "  systemctl start|stop|restart|status sui-agent"
    echo "  journalctl -u sui-agent -f"
    echo ""
    echo "配置文件位置: /opt/sui-agent/config/"
    echo "日志文件位置: /opt/sui-agent/logs/"
    echo "数据目录位置: /opt/sui-agent/data/"
    echo ""
}

main() {
    print_info "开始安装 SUI Agent..."
    check_root
    detect_os
    install_base
    install_java
    setup_user_and_dir
    download_jar
    create_service
    create_custom_command
    start_service
    show_complete
    print_info "安装完成！"
}

main
