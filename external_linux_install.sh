#!/bin/bash
# SUI External 一键安装脚本
# 基于 alireza0/s-ui 的安装脚本结构改进
# 支持 Linux 系统，自动安装依赖，从私有仓库下载 jar 并部署为 systemd 服务

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

# 安装基础工具（wget, curl, tar, tzdata 等）
install_base() {
    print_info "安装基础工具..."
    case "${OS}" in
        centos | almalinux | rocky | oracle)
            yum -y update && yum install -y -q wget curl tar tzdata
            ;;
        fedora)
            dnf -y update && dnf install -y -q wget curl tar tzdata
            ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm wget curl tar tzdata
            ;;
        opensuse-tumbleweed)
            zypper refresh && zypper -q install -y wget curl tar timezone
            ;;
        *)
            apt-get update && apt-get install -y -q wget curl tar tzdata
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

    print_info "正在安装 Java 21 (Oracle JDK) ..."

    # 下载并安装 Oracle JDK 21 DEB
    cd /tmp
    wget -q https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.deb
    apt install -y ./jdk-21_linux-x64_bin.deb
    rm -f jdk-21_linux-x64_bin.deb

    # 验证安装
    if command -v java &> /dev/null; then
        print_info "Java 21 安装成功: $(java -version 2>&1 | head -1)"
    else
        print_error "Java 21 安装失败"
        exit 1
    fi
}

# 创建用户和目录
setup_user_and_dir() {
    print_info "创建用户和目录..."
    # 创建系统用户
    if ! id -u suiexternal &> /dev/null; then
        useradd -r -s /bin/false suiexternal
        print_info "用户 suiexternal 创建成功"
    fi

    # 创建所需目录
    mkdir -p /opt/sui-external/{config,logs,uploads,config/web/static}
    chown -R suiexternal:suiexternal /opt/sui-external
    print_info "目录创建完成"
}

# 下载最新 Release 中的 jar 文件
download_jar() {
    print_info "下载文件..."

    GITHUB_REPO="mcqwyhud/sui-external"   # 替换为你的仓库
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

    # 获取最新版本 tag
    print_info "获取最新版本信息..."
    LATEST_VERSION=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$RELEASE_URL" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    if [ -z "$LATEST_VERSION" ]; then
        print_error "无法获取最新版本，请检查令牌和仓库设置"
        exit 1
    fi
    print_info "最新版本: $LATEST_VERSION"

    # 获取 jar 文件名（假设只有一个 .jar 文件）
    JAR_NAME=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$RELEASE_URL" | grep -o '"name": "[^"]*\.jar"' | cut -d'"' -f4 | head -1)
    if [ -z "$JAR_NAME" ]; then
        print_error "发布版本中未找到 jar 文件"
        exit 1
    fi
    print_info "JAR 文件名: $JAR_NAME"

    # 构建下载 URL
    DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$LATEST_VERSION/$JAR_NAME"

    # 下载
    if command -v wget &> /dev/null; then
        wget --header="Authorization: token $GITHUB_TOKEN" -O "/opt/sui-external/$JAR_NAME" "$DOWNLOAD_URL"
    else
        curl -L -H "Authorization: token $GITHUB_TOKEN" -o "/opt/sui-external/$JAR_NAME" "$DOWNLOAD_URL"
    fi

    if [ ! -f "/opt/sui-external/$JAR_NAME" ]; then
        print_error "文件下载失败"
        exit 1
    fi

    chown suiexternal:suiexternal "/opt/sui-external/$JAR_NAME"
    print_info "文件下载完成"
}

# 创建 systemd 服务文件（使用 echo 避免 heredoc 问题）
create_service() {
    print_info "创建 systemd 服务..."

    JAR_FILE=$(ls /opt/sui-external/*.jar | head -1)
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        exit 1
    fi
    print_info "使用 JAR 文件: $JAR_FILE"

    # JVM 内存配置（可根据需要调整）
    JVM_OPTS="-Xms64m -Xmx128m -XX:MaxMetaspaceSize=64m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=32m"

    SERVICE_FILE="/etc/systemd/system/sui-external.service"
    > "$SERVICE_FILE"
    echo "[Unit]" >> "$SERVICE_FILE"
    echo "Description=SUI External Service" >> "$SERVICE_FILE"
    echo "After=network.target" >> "$SERVICE_FILE"
    echo "" >> "$SERVICE_FILE"
    echo "[Service]" >> "$SERVICE_FILE"
    echo "Type=simple" >> "$SERVICE_FILE"
    echo "User=suiexternal" >> "$SERVICE_FILE"
    echo "WorkingDirectory=/opt/sui-external" >> "$SERVICE_FILE"
    echo "ExecStart=/usr/bin/java ${JVM_OPTS} -jar ${JAR_FILE}" >> "$SERVICE_FILE"
    echo "Restart=on-failure" >> "$SERVICE_FILE"
    echo "RestartSec=10" >> "$SERVICE_FILE"
    echo "StandardOutput=append:/opt/sui-external/logs/sui-external.log" >> "$SERVICE_FILE"
    echo "StandardError=append:/opt/sui-external/logs/sui-external-error.log" >> "$SERVICE_FILE"
    echo "" >> "$SERVICE_FILE"
    echo "[Install]" >> "$SERVICE_FILE"
    echo "WantedBy=multi-user.target" >> "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable sui-external
    print_info "systemd 服务创建完成"
}

# 启动服务
start_service() {
    print_info "启动 SUI External 服务..."
    systemctl start sui-external
    sleep 3
    if systemctl is-active --quiet sui-external; then
        print_info "服务启动成功"
    else
        print_error "服务启动失败，请查看日志: journalctl -u sui-external"
        exit 1
    fi
}

# 创建自定义管理命令
create_custom_command() {
    print_info "创建自定义命令 sui-e ..."
    cat > /usr/local/bin/sui-e << 'EOF'
#!/bin/bash
case "$1" in
    start)
        systemctl start sui-external
        echo "SUI External 服务已启动"
        ;;
    stop)
        systemctl stop sui-external
        echo "SUI External 服务已停止"
        ;;
    restart)
        systemctl restart sui-external
        echo "SUI External 服务已重启"
        ;;
    status)
        systemctl status sui-external
        ;;
    logs)
        journalctl -u sui-external -f
        ;;
    *)
        echo "用法: sui-e {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
EOF
    chmod +x /usr/local/bin/sui-e
    print_info "自定义命令创建完成"
}

# 显示完成信息
show_complete() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}SUI External 安装完成！${NC}"
    echo "=========================================="
    echo ""
    echo "管理命令："
    echo "  sui-e start    # 启动服务"
    echo "  sui-e stop     # 停止服务"
    echo "  sui-e restart  # 重启服务"
    echo "  sui-e status   # 查看状态"
    echo "  sui-e logs     # 查看日志"
    echo ""
    echo "或者使用 systemctl："
    echo "  systemctl start|stop|restart|status sui-external"
    echo "  journalctl -u sui-external -f"
    echo ""
    echo "配置文件位置: /opt/sui-external/config/application.yml"
    echo "日志文件位置: /opt/sui-external/logs/"
    echo ""
}

# 主函数
main() {
    print_info "开始安装 SUI External..."
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