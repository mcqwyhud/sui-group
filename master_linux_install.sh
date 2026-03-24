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

# 安装基础工具
install_base() {
    print_info "安装基础工具..."
    case "${OS}" in
        centos|almalinux|rocky|oracle)
            yum -y update && yum install -y -q wget curl tar tzdata
            ;;
        fedora)
            dnf -y update && dnf install -y -q wget curl tar tzdata
            ;;
        arch|manjaro|parch)
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

# 安装MySQL
install_mysql() {
    print_info "检查 MySQL 环境..."

    if command -v mysql &> /dev/null; then
        MYSQL_VERSION=$(mysql --version | awk '{print $5}' | sed 's/,//')
        print_info "已安装 MySQL 版本: $MYSQL_VERSION"
    else
        print_info "安装 MySQL..."
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
                # 获取临时密码
                if [ -f /var/log/mysqld.log ]; then
                    TEMP_PASSWORD=$(grep 'temporary password' /var/log/mysqld.log | tail -n 1 | awk '{print $NF}')
                    if [ -n "$TEMP_PASSWORD" ]; then
                        mysql -u root -p"$TEMP_PASSWORD" --connect-expired-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'c123456';"
                    fi
                fi
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
    fi

    # 确保MySQL服务正在运行
    if systemctl list-unit-files | grep -q mysqld; then
        systemctl start mysqld 2>/dev/null || systemctl start mysql 2>/dev/null
        systemctl enable mysqld 2>/dev/null || systemctl enable mysql 2>/dev/null
    elif service --status-all 2>&1 | grep -q mysql; then
        service mysql start
    fi

    # 等待MySQL启动
    sleep 3

    # 创建数据库（如果不存在）
    print_info "创建数据库..."
    mysql -u root -pc123456 -e "CREATE DATABASE IF NOT EXISTS \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
        print_warning "无法连接MySQL，请手动创建数据库: CREATE DATABASE \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
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

    # 设置权限
    chown -R suimaster:suimaster /opt/sui-master

    print_info "目录创建完成"
}

# 下载最新 Release 中的 jar 文件
download_files() {
    print_info "下载文件..."

    GITHUB_REPO="mcqwyhud/sui-master"
    VERSION="v0.0.1"
    JAR_NAME="sui-master-0.0.1-SNAPSHOT.jar"
    
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

    print_info "获取 release 信息..."
    
    # 获取完整的 release 信息
    RELEASE_INFO=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_REPO/releases/tags/$VERSION")
    
    # 保存到文件以便调试
    echo "$RELEASE_INFO" > /tmp/release_info.json
    
    # 查找 jar 文件的 asset ID（更精确的匹配）
    ASSET_ID=$(echo "$RELEASE_INFO" | grep -B 10 "\"name\": \"$JAR_NAME\"" | grep -o '"id": [0-9]*' | head -1 | awk '{print $2}')
    
    if [ -z "$ASSET_ID" ]; then
        print_error "无法获取 asset ID"
        print_info "请检查 /tmp/release_info.json 文件"
        exit 1
    fi
    
    print_info "Asset ID: $ASSET_ID"
    
    # 通过 API 下载
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

    # 验证文件大小（应该大于 1MB）
    FILE_SIZE=$(stat -c%s "/opt/sui-master/$JAR_NAME" 2>/dev/null || stat -f%z "/opt/sui-master/$JAR_NAME" 2>/dev/null)
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        print_error "文件大小异常: $FILE_SIZE 字节（应该大于 1MB）"
        print_info "下载可能失败，请检查网络或 token 权限"
        exit 1
    fi
    
    print_info "文件下载完成 (大小: $(numfmt --to=iec $FILE_SIZE))"

    chown suimaster:suimaster "/opt/sui-master/$JAR_NAME"
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

    # JVM 内存配置（可根据需要调整）
    # Master 服务需要更多内存（MySQL 连接、多用户管理等）
    JVM_OPTS="-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m"

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
    download_files
    create_service
    create_custom_command
    start_service
    show_complete
    print_info "安装完成！"
}

# 执行主函数
main
