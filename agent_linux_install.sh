#!/bin/bash
# SUI Agent 一键安装脚本
# 基于 alireza0/s-ui 的安装脚本结构改进
# 支持 Linux 系统，自动安装依赖，从私有仓库下载 jar 并部署为 systemd 服务
# 改进：使用 jq + assets API，增加 SHA256 校验

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# 检测操作系统和架构
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

# 获取 CPU 架构
get_arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) print_error "不支持的 CPU 架构: $(uname -m)"; exit 1 ;;
    esac
}

# 安装基础工具（wget, curl, tar, tzdata, jq 等）
install_base() {
    print_info "检查基础工具..."

    # 定义需要检查的工具（增加 jq）
    local tools=("wget" "curl" "tar" "tzdata" "jq")
    local missing_tools=()

    # 检查哪些工具缺失
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            # tzdata 特殊处理（它不是一个命令，而是一个包）
            if [ "$tool" != "tzdata" ]; then
                missing_tools+=("$tool")
            fi
        fi
    done

    # 检查 tzdata 是否安装
    if [ ! -d "/usr/share/zoneinfo" ]; then
        missing_tools+=("tzdata")
    fi

    # 如果没有缺失工具，直接返回
    if [ ${#missing_tools[@]} -eq 0 ]; then
        print_info "基础工具已安装 (wget, curl, tar, tzdata, jq)"
        return 0
    fi

    print_info "需要安装的工具: ${missing_tools[*]}"

    # 检查是否需要更新包缓存（如果超过1天未更新）
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

    # 只安装缺失的工具
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

# 安装 Java（如果未安装）
install_java() {
    print_info "检查 Java 环境..."

    # 如果已安装 Java 21+，直接返回
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

    # 验证安装
    if command -v java &> /dev/null; then
        print_info "Java 安装成功: $(java -version 2>&1 | head -1)"
    else
        print_error "Java 安装失败"
        exit 1
    fi
}

# 创建用户和目录
setup_user_and_dir() {
    print_info "创建用户和目录..."
    # 创建系统用户
    if ! id -u suiagent &> /dev/null; then
        useradd -r -s /bin/false suiagent
        print_info "用户 suiagent 创建成功"
    fi

    # 创建所需目录
    mkdir -p /opt/sui-agent/{config,logs,data}
    chown -R suiagent:suiagent /opt/sui-agent
    print_info "目录创建完成"
}

# 下载最新 Release 中的 jar 文件（使用 jq + assets API，增加 SHA256 校验）
download_jar() {
    print_info "下载文件..."

    GITHUB_REPO="mcqwyhud/sui-agent"
    RELEASE_URL="https://api.github.com/repos/$GITHUB_REPO/releases/latest"

    # 获取令牌
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

    # 获取最新版本信息
    print_info "获取最新版本信息..."
    API_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$RELEASE_URL")

    # 检查 API 响应是否有效
    if echo "$API_RESPONSE" | grep -q '"message"'; then
        ERROR_MSG=$(echo "$API_RESPONSE" | grep -o '"message": "[^"]*"' | cut -d'"' -f4)
        print_error "API 请求失败: $ERROR_MSG"
        print_info "请检查 GitHub 令牌权限和仓库访问权限"
        exit 1
    fi

    # 提取版本号（用于显示）
    LATEST_VERSION=$(echo "$API_RESPONSE" | jq -r '.tag_name // empty')
    if [ -z "$LATEST_VERSION" ]; then
        print_error "无法获取最新版本，请检查令牌和仓库设置"
        print_info "API 响应: $API_RESPONSE"
        exit 1
    fi
    print_info "最新版本: $LATEST_VERSION"

    # 提取第一个 .jar 资产的信息（名称、ID、digest，并去除 sha256: 前缀）
    JAR_NAME=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar")) | .name' | head -1)
    ASSET_ID=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar")) | .id' | head -1)
    EXPECTED_SHA256=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar")) | .digest // ""' | head -1 | sed 's/^sha256://')

    if [ -z "$JAR_NAME" ] || [ -z "$ASSET_ID" ]; then
        print_error "发布版本中未找到 jar 文件"
        print_info "可用的 assets:"
        echo "$API_RESPONSE" | jq -r '.assets[].name' 2>/dev/null || echo "$API_RESPONSE" | grep -o '"name": "[^"]*"' | cut -d'"' -f4
        exit 1
    fi
    print_info "JAR 文件名: $JAR_NAME"
    print_info "资产 ID: $ASSET_ID"

    # 构建 assets API 下载 URL
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

    # 如果 assets API 下载失败，回退到标准 Release URL
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
            print_info "请检查:"
            print_info "1. GitHub 令牌是否有正确的权限 (repo)"
            print_info "2. 仓库是否为私有仓库"
            print_info "3. Release 版本是否存在"
            print_info "4. JAR 文件名是否正确"
            exit 1
        fi
    fi

    # 验证文件大小（应该大于 1MB）
    FILE_SIZE=$(stat -c%s "/opt/sui-agent/$JAR_NAME" 2>/dev/null || stat -f%z "/opt/sui-agent/$JAR_NAME" 2>/dev/null)
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        print_error "文件大小异常: $FILE_SIZE 字节（应该大于 1MB）"
        exit 1
    fi

    # SHA256 校验
    if [ -n "$EXPECTED_SHA256" ]; then
        print_info "计算本地 JAR 的 SHA256..."
        LOCAL_SHA256=$(sha256sum "/opt/sui-agent/$JAR_NAME" | awk '{print $1}')
        if [ "$LOCAL_SHA256" != "$EXPECTED_SHA256" ]; then
            print_error "SHA256 校验失败！"
            print_info "期望: $EXPECTED_SHA256"
            print_info "实际: $LOCAL_SHA256"
            exit 1
        fi
        print_info "SHA256 校验通过 ✓"
    else
        print_warning "未获取到 digest 信息，跳过 SHA256 校验"
    fi

    print_info "文件下载完成 (大小: $(numfmt --to=iec $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes"))"

    chown suiagent:suiagent "/opt/sui-agent/$JAR_NAME"
}

# 创建 systemd 服务文件
create_service() {
    print_info "创建 systemd 服务..."

    JAR_FILE=$(ls /opt/sui-agent/*.jar | head -1)
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        exit 1
    fi
    print_info "使用 JAR 文件: $JAR_FILE"

    # JVM 内存配置（Agent 轻量级配置）
    # 注意：由于应用使用了 Protobuf 动态代理，需要较大的 Metaspace
    JVM_OPTS="-Xms64m -Xmx128m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=32m"

    SERVICE_FILE="/etc/systemd/system/sui-agent.service"
    > "$SERVICE_FILE"
    echo "[Unit]" >> "$SERVICE_FILE"
    echo "Description=SUI Agent Service" >> "$SERVICE_FILE"
    echo "After=network.target" >> "$SERVICE_FILE"
    echo "" >> "$SERVICE_FILE"
    echo "[Service]" >> "$SERVICE_FILE"
    echo "Type=simple" >> "$SERVICE_FILE"
    echo "User=suiagent" >> "$SERVICE_FILE"
    echo "WorkingDirectory=/opt/sui-agent" >> "$SERVICE_FILE"
    echo "ExecStart=/usr/bin/java ${JVM_OPTS} -jar ${JAR_FILE}" >> "$SERVICE_FILE"
    echo "Restart=on-failure" >> "$SERVICE_FILE"
    echo "RestartSec=10" >> "$SERVICE_FILE"
    echo "StandardOutput=file:/opt/sui-agent/logs/sui-agent.log" >> "$SERVICE_FILE"
    echo "StandardError=file:/opt/sui-agent/logs/sui-agent-error.log" >> "$SERVICE_FILE"
    echo "" >> "$SERVICE_FILE"
    echo "[Install]" >> "$SERVICE_FILE"
    echo "WantedBy=multi-user.target" >> "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable sui-agent
    print_info "systemd 服务创建完成"
}

# 启动服务
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

# 创建自定义管理命令
create_custom_command() {
    print_info "创建自定义命令 sui-a ..."
    cat > /usr/local/bin/sui-a << 'EOF'
#!/bin/bash
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
    *)
        echo "用法: sui-a {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
EOF
    chmod +x /usr/local/bin/sui-a
    print_info "自定义命令创建完成"
}

# 显示完成信息
show_complete() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}SUI Agent 安装完成！${NC}"
    echo "=========================================="
    echo ""
    echo "管理命令："
    echo "  sui-a start    # 启动服务"
    echo "  sui-a stop     # 停止服务"
    echo "  sui-a restart  # 重启服务"
    echo "  sui-a status   # 查看状态"
    echo "  sui-a logs     # 查看日志"
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

# 主函数
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

# 执行主函数
main