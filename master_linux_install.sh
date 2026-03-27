#!/bin/bash

# SUI Master 一键安装脚本
# 参考 External 脚本的下载方式，增加 SHA256 校验

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# 检查 root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# 检测操作系统
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

# 安装基础工具（wget, curl, tar, tzdata）
install_base() {
    print_info "检查基础工具..."

    local tools=("wget" "curl" "tar" "tzdata")
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
        print_info "基础工具已安装 (wget, curl, tar, tzdata)"
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
        centos|almalinux|rocky|oracle|rhel)
            if [ ! -f /var/cache/yum/timestamp.txt ] || [ $(find /var/cache/yum -name "*.rpm" -mtime +1 2>/dev/null | wc -l) -gt 0 ]; then
                need_update=true
            fi
            ;;
        fedora)
            if [ ! -f /var/cache/dnf/timestamp.txt ] || [ $(find /var/cache/dnf -name "*.rpm" -mtime +1 2>/dev/null | wc -l) -gt 0 ]; then
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
        esac
    fi

    print_info "安装缺失的基础工具..."
    case "${OS}" in
        centos|almalinux|rocky|oracle)
            yum install -y -q "${missing_tools[@]}"
            ;;
        fedora)
            dnf install -y -q "${missing_tools[@]}"
            ;;
        ubuntu|debian)
            apt-get install -y -qq "${missing_tools[@]}"
            ;;
        *)
            print_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac

    print_info "基础工具安装完成"
}

# 安装 Java 21
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

# 安装 MySQL
install_mysql() {
    print_info "检查 MySQL 环境..."

    if command -v mysql &> /dev/null; then
        MYSQL_VERSION=$(mysql --version | awk '{print $5}' | sed 's/,//')
        print_info "已安装 MySQL 版本: $MYSQL_VERSION"
        if mysql -u root -pc123456 -e "USE \`s-ui\`;" 2>/dev/null; then
            print_info "数据库 's-ui' 已存在"
        else
            print_warning "数据库 's-ui' 不存在，正在创建..."
            mysql -u root -pc123456 -e "CREATE DATABASE IF NOT EXISTS \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
                print_warning "无法自动创建数据库，请手动执行："
                echo "  mysql -u root -p -e \"CREATE DATABASE \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
            }
        fi
        return
    fi

    print_info "未检测到 MySQL，正在安装..."
    case "${OS}" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            debconf-set-selections <<< "mysql-server mysql-server/root_password password c123456"
            debconf-set-selections <<< "mysql-server mysql-server/root_password_again password c123456"
            apt-get update
            apt-get install -y mysql-server
            ;;
        centos|rhel|almalinux|rocky|oracle)
            yum install -y mysql-server
            systemctl start mysqld
            systemctl enable mysqld
            ;;
        fedora)
            dnf install -y mysql-server
            systemctl start mysqld
            systemctl enable mysqld
            ;;
        *)
            print_error "不支持的操作系统: $OS，请手动安装 MySQL"
            exit 1
            ;;
    esac
    print_info "MySQL 安装完成"

    sleep 5
    print_info "创建数据库..."
    mysql -u root -pc123456 -e "CREATE DATABASE IF NOT EXISTS \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
        print_warning "无法创建数据库，请手动执行："
        echo "  mysql -u root -p -e \"CREATE DATABASE \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
    }
    print_info "数据库创建完成"
}

# 创建用户和目录
setup_user_and_dir() {
    print_info "创建用户和目录..."

    if ! id -u suimaster &> /dev/null; then
        useradd -r -s /bin/false suimaster
        print_info "用户 suimaster 创建成功"
    fi

    mkdir -p /opt/sui-master/{config,logs,uploads,config/web/static}

    # 修复权限问题：创建临时目录
    mkdir -p /tmp/JPROTOBUF_CACHE_DIR
    chown -R suimaster:suimaster /tmp/JPROTOBUF_CACHE_DIR
    chmod 755 /tmp/JPROTOBUF_CACHE_DIR

    chown -R suimaster:suimaster /opt/sui-master
    chmod 755 /opt/sui-master/logs

    print_info "目录创建完成"
}

# 下载并验证 JAR（参照 External 脚本的下载方式，并增加 SHA256 校验）
download_and_verify_jar() {
    print_info "下载文件..."

    GITHUB_REPO="mcqwyhud/sui-master"
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

    # 提取版本号
    LATEST_VERSION=$(echo "$API_RESPONSE" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    if [ -z "$LATEST_VERSION" ]; then
        print_error "无法获取最新版本，请检查令牌和仓库设置"
        exit 1
    fi
    print_info "最新版本: $LATEST_VERSION"

    # 稳健提取 asset ID：先定位到包含 jar 文件名的行，再取前面的 id
    ASSET_ID=$(echo "$API_RESPONSE" | grep -o '"id": [0-9]*, "name": "sui-master-0.0.1-SNAPSHOT.jar"' | sed 's/.*"id": \([0-9]*\),.*/\1/')
    if [ -z "$ASSET_ID" ]; then
        print_error "未找到 jar 文件的 asset ID"
        print_info "API 响应预览（前500字符）:"
        echo "$API_RESPONSE" | head -c 500
        exit 1
    fi
    print_info "Asset ID: $ASSET_ID"

    # 提取 digest（包含 sha256）
    DIGEST=$(echo "$API_RESPONSE" | grep -o '"digest": "sha256:[^"]*"' | head -1 | cut -d'"' -f4)
    EXPECTED_SHA256=$(echo "$DIGEST" | sed 's/^sha256://')
    JAR_NAME="sui-master-0.0.1-SNAPSHOT.jar"

    if [ -n "$EXPECTED_SHA256" ]; then
        print_info "期望 SHA256: $EXPECTED_SHA256"
    else
        print_warning "未获取到 digest 信息，将跳过 SHA256 校验"
    fi

    print_info "下载 JAR 文件..."
    ASSET_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases/assets/$ASSET_ID"
    curl -L -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/octet-stream" \
         -o "/opt/sui-master/$JAR_NAME" \
         "$ASSET_API_URL"

    if [ ! -f "/opt/sui-master/$JAR_NAME" ]; then
        print_error "JAR 文件下载失败"
        exit 1
    fi

    # SHA256 校验
    if [ -n "$EXPECTED_SHA256" ]; then
        print_info "计算本地 JAR 的 SHA256..."
        LOCAL_SHA256=$(sha256sum "/opt/sui-master/$JAR_NAME" | awk '{print $1}')
        if [ "$LOCAL_SHA256" != "$EXPECTED_SHA256" ]; then
            print_error "SHA256 校验失败！"
            print_info "期望: $EXPECTED_SHA256"
            print_info "实际: $LOCAL_SHA256"
            exit 1
        fi
        print_info "SHA256 校验通过 ✓"
    else
        print_warning "跳过 SHA256 校验"
    fi

    chown suimaster:suimaster "/opt/sui-master/$JAR_NAME"
    print_info "文件准备完成"
}

# 创建 systemd 服务
create_service() {
    print_info "创建 systemd 服务..."

    JAR_FILE=$(ls /opt/sui-master/*.jar | head -1)
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        exit 1
    fi
    print_info "使用 JAR 文件: $JAR_FILE"

    # 确保日志目录存在且有正确权限
    mkdir -p /opt/sui-master/logs
    chown -R suimaster:suimaster /opt/sui-master/logs
    chmod 755 /opt/sui-master/logs

    JVM_OPTS="-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m"
    JVM_OPTS="$JVM_OPTS -Djava.io.tmpdir=/tmp -Djprotobuf.cache.dir=/tmp/JPROTOBUF_CACHE_DIR"

    SERVICE_FILE="/etc/systemd/system/sui-master.service"
    > "$SERVICE_FILE"
    echo "[Unit]" >> "$SERVICE_FILE"
    echo "Description=SUI Master Service" >> "$SERVICE_FILE"
    echo "After=network.target mysql.service" >> "$SERVICE_FILE"
    echo "" >> "$SERVICE_FILE"
    echo "[Service]" >> "$SERVICE_FILE"
    echo "Type=simple" >> "$SERVICE_FILE"
    echo "User=suimaster" >> "$SERVICE_FILE"
    echo "WorkingDirectory=/opt/sui-master" >> "$SERVICE_FILE"
    echo "ExecStart=/usr/bin/java ${JVM_OPTS} -jar ${JAR_FILE}" >> "$SERVICE_FILE"
    echo "Restart=on-failure" >> "$SERVICE_FILE"
    echo "RestartSec=10" >> "$SERVICE_FILE"
    echo "StandardOutput=append:/opt/sui-master/logs/sui-master.log" >> "$SERVICE_FILE"
    echo "StandardError=append:/opt/sui-master/logs/sui-master-error.log" >> "$SERVICE_FILE"
    echo "" >> "$SERVICE_FILE"
    echo "[Install]" >> "$SERVICE_FILE"
    echo "WantedBy=multi-user.target" >> "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable sui-master
    print_info "systemd 服务创建完成"
}

# 启动服务
start_service() {
    print_info "启动 SUI Master 服务..."
    systemctl start sui-master
    sleep 3

    if systemctl is-active --quiet sui-master; then
        print_info "SUI Master 服务启动成功"
    else
        print_error "SUI Master 服务启动失败，请查看日志: journalctl -u sui-master"
        exit 1
    fi
}

# 创建自定义命令
create_custom_command() {
    print_info "创建自定义命令 sui-m ..."

    cat > /usr/local/bin/sui-m << 'EOF'
#!/bin/bash
case "$1" in
    start)
        systemctl start sui-master
        echo "SUI Master 服务已启动"
        ;;
    stop)
        systemctl stop sui-master
        echo "SUI Master 服务已停止"
        ;;
    restart)
        systemctl restart sui-master
        echo "SUI Master 服务已重启"
        ;;
    status)
        systemctl status sui-master
        ;;
    logs)
        journalctl -u sui-master -f
        ;;
    *)
        echo "用法: sui-m {start|stop|restart|status|logs}"
        exit 1
        ;;
esac
EOF

    chmod +x /usr/local/bin/sui-m
    print_info "自定义命令创建完成"
}

# 显示完成信息
show_complete() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}SUI Master 安装完成！${NC}"
    echo "=========================================="
    echo ""
    echo "管理命令："
    echo "  sui-m start    # 启动服务"
    echo "  sui-m stop     # 停止服务"
    echo "  sui-m restart  # 重启服务"
    echo "  sui-m status   # 查看状态"
    echo "  sui-m logs     # 查看日志"
    echo ""
    echo "或者使用 systemctl："
    echo "  systemctl start|stop|restart|status sui-master"
    echo "  journalctl -u sui-master -f"
    echo ""
    echo "配置文件位置: /opt/sui-master/config/application.yml"
    echo "日志文件位置: /opt/sui-master/logs/"
    echo "数据库名称: s-ui"
    echo "数据库密码: c123456"
    echo ""
    print_warning "首次启动后，请查看日志中的临时密码："
    echo "  journalctl -u sui-master | grep 'Using generated security password'"
    echo "  或查看日志文件: tail -f /opt/sui-master/logs/sui-master.log"
    echo ""
}

# 主函数
main() {
    print_info "开始安装 SUI Master..."
    check_root
    detect_os
    install_base
    install_java
    install_mysql
    setup_user_and_dir
    download_and_verify_jar
    create_service
    create_custom_command
    start_service
    show_complete
    print_info "安装完成！"
}

main
