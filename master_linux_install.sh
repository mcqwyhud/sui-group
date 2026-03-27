#!/bin/bash

# SUI Master 一键安装脚本 - 最终稳定版
# 使用 jq 解析 GitHub API，确保 asset ID 提取无误

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
    else
        print_error "无法检测操作系统"
        exit 1
    fi
    print_info "检测到操作系统: $OS"
}

install_base() {
    print_info "安装基础工具（wget, curl, tar, tzdata, jq）..."
    case "$OS" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq wget curl tar tzdata jq
            ;;
        centos|rhel|almalinux|rocky|oracle)
            yum install -y -q wget curl tar tzdata jq
            ;;
        fedora)
            dnf install -y -q wget curl tar tzdata jq
            ;;
        *)
            print_error "不支持的操作系统: $OS，请手动安装 wget curl tar tzdata jq"
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
    print_info "安装 Java 21..."
    case "$OS" in
        ubuntu|debian)
            apt-get install -y -qq openjdk-21-jre-headless
            ;;
        centos|rhel|almalinux|rocky|oracle)
            yum install -y -q java-21-openjdk-headless
            ;;
        fedora)
            dnf install -y -q java-21-openjdk-headless
            ;;
        *)
            print_error "请手动安装 Java 21"
            exit 1
            ;;
    esac
    print_info "Java 安装完成: $(java -version 2>&1 | head -1)"
}

install_mysql() {
    print_info "检查 MySQL 环境..."
    if command -v mysql &> /dev/null; then
        print_info "已安装 MySQL: $(mysql --version)"
        if mysql -u root -pc123456 -e "USE \`s-ui\`;" 2>/dev/null; then
            print_info "数据库 s-ui 已存在"
        else
            print_warning "数据库 s-ui 不存在，尝试创建..."
            mysql -u root -pc123456 -e "CREATE DATABASE IF NOT EXISTS \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
                print_warning "无法自动创建，请手动执行："
                echo "mysql -u root -p -e \"CREATE DATABASE s-ui CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
            }
        fi
        return
    fi
    print_info "安装 MySQL..."
    case "$OS" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            debconf-set-selections <<< "mysql-server mysql-server/root_password password c123456"
            debconf-set-selections <<< "mysql-server mysql-server/root_password_again password c123456"
            apt-get install -y -qq mysql-server
            ;;
        centos|rhel|almalinux|rocky|oracle)
            yum install -y -q mysql-server
            systemctl start mysqld
            systemctl enable mysqld
            ;;
        fedora)
            dnf install -y -q mysql-server
            systemctl start mysqld
            systemctl enable mysqld
            ;;
        *)
            print_error "请手动安装 MySQL"
            exit 1
            ;;
    esac
    print_info "MySQL 安装完成"
    sleep 5
    mysql -u root -pc123456 -e "CREATE DATABASE IF NOT EXISTS \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
        print_warning "无法创建数据库，请手动执行："
        echo "mysql -u root -p -e \"CREATE DATABASE s-ui CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
    }
}

setup_user_and_dir() {
    print_info "创建用户和目录..."
    if ! id -u suimaster &> /dev/null; then
        useradd -r -s /bin/false suimaster
    fi
    mkdir -p /opt/sui-master/{config,logs,uploads,config/web/static}
    mkdir -p /tmp/JPROTOBUF_CACHE_DIR
    chown -R suimaster:suimaster /tmp/JPROTOBUF_CACHE_DIR
    chown -R suimaster:suimaster /opt/sui-master
    chmod 755 /opt/sui-master/logs
    print_info "目录创建完成"
}

download_jar() {
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
        print_error "未提供令牌"
        exit 1
    fi

    print_info "获取最新版本信息..."
    API_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$RELEASE_URL")

    # 使用 jq 提取所需数据
    LATEST_VERSION=$(echo "$API_RESPONSE" | jq -r '.tag_name')
    JAR_ASSET=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar"))')
    ASSET_ID=$(echo "$JAR_ASSET" | jq -r '.id')
    EXPECTED_SHA256=$(echo "$JAR_ASSET" | jq -r '.digest' | sed 's/^sha256://')
    JAR_NAME=$(echo "$JAR_ASSET" | jq -r '.name')

    if [ -z "$ASSET_ID" ] || [ "$ASSET_ID" = "null" ]; then
        print_error "未找到 jar 文件 asset"
        exit 1
    fi

    print_info "最新版本: $LATEST_VERSION"
    print_info "JAR 文件名: $JAR_NAME"
    print_info "期望 SHA256: $EXPECTED_SHA256"

    print_info "下载 JAR 文件..."
    ASSET_API_URL="https://api.github.com/repos/$GITHUB_REPO/releases/assets/$ASSET_ID"
    curl -L -H "Authorization: token $GITHUB_TOKEN" \
         -H "Accept: application/octet-stream" \
         -o "/opt/sui-master/$JAR_NAME" \
         "$ASSET_API_URL"

    if [ ! -f "/opt/sui-master/$JAR_NAME" ]; then
        print_error "下载失败"
        exit 1
    fi

    print_info "计算本地 SHA256..."
    LOCAL_SHA256=$(sha256sum "/opt/sui-master/$JAR_NAME" | awk '{print $1}')
    if [ "$LOCAL_SHA256" != "$EXPECTED_SHA256" ]; then
        print_error "SHA256 校验失败！"
        print_info "期望: $EXPECTED_SHA256"
        print_info "实际: $LOCAL_SHA256"
        exit 1
    fi
    print_info "SHA256 校验通过 ✓"

    chown suimaster:suimaster "/opt/sui-master/$JAR_NAME"
    print_info "文件准备完成"
}

create_service() {
    print_info "创建 systemd 服务..."
    JAR_FILE=$(ls /opt/sui-master/*.jar | head -1)
    mkdir -p /opt/sui-master/logs
    chown -R suimaster:suimaster /opt/sui-master/logs
    chmod 755 /opt/sui-master/logs

    JVM_OPTS="-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m"
    JVM_OPTS="$JVM_OPTS -Djava.io.tmpdir=/tmp -Djprotobuf.cache.dir=/tmp/JPROTOBUF_CACHE_DIR"

    cat > /etc/systemd/system/sui-master.service << EOF
[Unit]
Description=SUI Master Service
After=network.target mysql.service

[Service]
Type=simple
User=suimaster
WorkingDirectory=/opt/sui-master
Environment="JAVA_OPTS=$JVM_OPTS"
ExecStart=/usr/bin/java \$JAVA_OPTS -jar $JAR_FILE
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

start_service() {
    print_info "启动服务..."
    systemctl start sui-master
    sleep 3
    if systemctl is-active --quiet sui-master; then
        print_info "服务启动成功"
    else
        print_error "启动失败，查看日志: journalctl -u sui-master"
        exit 1
    fi
}

create_custom_command() {
    print_info "创建自定义命令 sui-m ..."
    cat > /usr/local/bin/sui-m << 'EOF'
#!/bin/bash
case "$1" in
    start) systemctl start sui-master && echo "已启动" ;;
    stop) systemctl stop sui-master && echo "已停止" ;;
    restart) systemctl restart sui-master && echo "已重启" ;;
    status) systemctl status sui-master ;;
    logs) journalctl -u sui-master -f ;;
    *) echo "用法: sui-m {start|stop|restart|status|logs}" ;;
esac
EOF
    chmod +x /usr/local/bin/sui-m
    print_info "自定义命令创建完成"
}

show_complete() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}SUI Master 安装完成！${NC}"
    echo "=========================================="
    echo ""
    echo "管理命令: sui-m {start|stop|restart|status|logs}"
    echo "配置文件: /opt/sui-master/config/application.yml"
    echo "日志文件: /opt/sui-master/logs/"
    echo "数据库: s-ui / 密码: c123456"
    echo ""
    print_warning "首次启动后，使用以下命令查看临时密码："
    echo "  journalctl -u sui-master | grep 'Using generated security password'"
    echo "  或 tail -f /opt/sui-master/logs/sui-master.log"
    echo ""
}

main() {
    print_info "开始安装 SUI Master..."
    check_root
    detect_os
    install_base          # 现在会自动安装 jq
    install_java
    install_mysql
    setup_user_and_dir
    download_jar
    create_service
    create_custom_command
    start_service
    show_complete
    print_info "安装完成！"
}

main
