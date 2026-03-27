#!/bin/bash

# SUI Master 一键安装脚本
# 支持 Linux 系统

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# 检查是否为root用户
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

# 安装基础工具（只在需要时安装）
install_base() {
    print_info "检查基础工具..."

    # 定义需要检查的工具
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
        arch|manjaro|parch)
            need_update=false
            ;;
        opensuse-tumbleweed)
            if [ ! -f /var/cache/zypp/timestamp.txt ] || [ $(find /var/cache/zypp -name "*.rpm" -mtime +1 2>/dev/null | wc -l) -gt 0 ]; then
                need_update=true
            fi
            ;;
    esac

    if [ "$need_update" = true ]; then
        print_info "更新软件包缓存..."
        case "${OS}" in
            ubuntu|debian)
                apt-get update -qq
                ;;
            centos|almalinux|rocky|oracle|rhel)
                yum makecache -q
                ;;
            fedora)
                dnf makecache -q
                ;;
            opensuse-tumbleweed)
                zypper refresh -q
                ;;
        esac
    fi

    # 只安装缺失的工具
    print_info "安装缺失的基础工具..."
    case "${OS}" in
        centos|almalinux|rocky|oracle)
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

# 安装Java（如果未安装）
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

# 安装MySQL（如果未安装则安装）
install_mysql() {
    print_info "检查 MySQL 环境..."

    if command -v mysql &> /dev/null; then
        MYSQL_VERSION=$(mysql --version | awk '{print $5}' | sed 's/,//')
        print_info "已安装 MySQL 版本: $MYSQL_VERSION"

        # 检查数据库是否存在
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

    # 等待MySQL启动
    sleep 5

    # 创建数据库
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

    # 创建用户（如果不存在）
    if ! id -u suimaster &> /dev/null; then
        useradd -r -s /bin/false suimaster
        print_info "用户 suimaster 创建成功"
    fi

    # 创建目录
    mkdir -p /opt/sui-master/{config,logs,uploads,config/web/static}

    # 创建临时目录并设置权限（修复权限问题）
    mkdir -p /tmp/JPROTOBUF_CACHE_DIR
    chown -R suimaster:suimaster /tmp/JPROTOBUF_CACHE_DIR
    chmod 755 /tmp/JPROTOBUF_CACHE_DIR

    # 设置权限
    chown -R suimaster:suimaster /opt/sui-master

    # 额外确保日志目录权限正确（修复日志写入问题）
    chmod 755 /opt/sui-master/logs

    print_info "目录创建完成"
}

# 获取最新版本信息
get_latest_release() {
    GITHUB_REPO="mcqwyhud/sui-master"

    print_info "获取最新版本信息..."

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

    # 获取最新的 release 信息
    RELEASE_INFO=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_REPO/releases/latest")

    # 检查是否成功
    if echo "$RELEASE_INFO" | grep -q "Not Found"; then
        print_error "无法访问仓库或仓库不存在"
        exit 1
    fi

    # 提取版本号
    LATEST_VERSION=$(echo "$RELEASE_INFO" | jq -r '.tag_name')

    if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
        print_error "无法获取最新版本信息"
        exit 1
    fi

    print_info "最新版本: $LATEST_VERSION"

    # 保存 release 信息
    echo "$RELEASE_INFO" > /tmp/release_info.json
}

# 下载并验证 JAR 文件
download_and_verify() {
    GITHUB_REPO="mcqwyhud/sui-master"
    JAR_NAME="sui-master-0.0.1-SNAPSHOT.jar"

    print_info "下载文件..."

    # 获取 asset ID
    ASSET_ID=$(cat /tmp/release_info.json | jq -r ".assets[] | select(.name == \"$JAR_NAME\") | .id")

    if [ -z "$ASSET_ID" ] || [ "$ASSET_ID" = "null" ]; then
        print_error "无法获取 asset ID"
        print_info "请检查 /tmp/release_info.json 文件"
        exit 1
    fi

    print_info "Asset ID: $ASSET_ID"

    # 下载文件
    print_info "开始下载..."
    curl -L -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/octet-stream" \
         -o "/opt/sui-master/$JAR_NAME" \
         "https://api.github.com/repos/$GITHUB_REPO/releases/assets/$ASSET_ID"

    # 检查下载是否成功
    if [ ! -f "/opt/sui-master/$JAR_NAME" ]; then
        print_error "文件下载失败"
        exit 1
    fi

    # 验证文件大小
    FILE_SIZE=$(stat -c%s "/opt/sui-master/$JAR_NAME" 2>/dev/null || stat -f%z "/opt/sui-master/$JAR_NAME" 2>/dev/null)
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        print_error "文件大小异常: $FILE_SIZE 字节（应该大于 1MB）"
        print_info "下载可能失败，请检查网络或 token 权限"
        exit 1
    fi

    print_info "文件大小: $(numfmt --to=iec $FILE_SIZE)"

    # 验证 JAR 文件完整性
    print_info "验证 JAR 文件完整性..."
    if unzip -t "/opt/sui-master/$JAR_NAME" 2>&1 | grep -q "bad CRC"; then
        print_error "JAR 文件完整性验证失败 (CRC 错误)"
        exit 1
    fi

    # 验证特定文件（ip2region_v4.xdb）
    if unzip -t "/opt/sui-master/$JAR_NAME" 2>&1 | grep -q "ip2region_v4.xdb.*bad CRC"; then
        print_error "JAR 文件中的 ip2region_v4.xdb 文件损坏"
        exit 1
    fi

    print_info "JAR 文件完整性验证通过"

    # 设置权限
    chown suimaster:suimaster "/opt/sui-master/$JAR_NAME"
    chmod 755 "/opt/sui-master/$JAR_NAME"

    print_info "文件下载完成"
}

# 创建 systemd 服务文件
create_service() {
    print_info "创建 systemd 服务..."

    JAR_FILE=$(ls /opt/sui-master/*.jar | head -1)
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        exit 1
    fi
    print_info "使用 JAR 文件: $JAR_FILE"

    # 确保日志目录存在且有正确权限（修复日志写入问题）
    mkdir -p /opt/sui-master/logs
    chown -R suimaster:suimaster /opt/sui-master/logs
    chmod 755 /opt/sui-master/logs

    # JVM 内存配置（保持原配置）
    JVM_OPTS="-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m"
    # 添加临时目录配置（修复权限问题）
    JVM_OPTS="$JVM_OPTS -Djava.io.tmpdir=/tmp -Djprotobuf.cache.dir=/tmp/JPROTOBUF_CACHE_DIR"

    SERVICE_FILE="/etc/systemd/system/sui-master.service"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=SUI Master Service
After=network.target mysql.service

[Service]
Type=simple
User=suimaster
WorkingDirectory=/opt/sui-master
Environment="JAVA_OPTS=${JVM_OPTS}"
ExecStart=/usr/bin/java \$JAVA_OPTS -jar ${JAR_FILE}
Restart=on-failure
RestartSec=10
StandardOutput=append:/opt/sui-master/logs/sui-master.log
StandardError=append:/opt/sui-master/logs/sui-master-error.log

[Install]
WantedBy=multi-user.target
EOF

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
    get_latest_release
    download_and_verify
    create_service
    create_custom_command
    start_service
    show_complete
    print_info "安装完成！"
}

# 执行主函数
main