#!/bin/bash

# SUI Master 一键安装脚本
# 优化下载验证：使用 jq + assets API，确保私有仓库下载稳定性

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

# 安装基础工具（wget, curl, tar, tzdata, jq）
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

    # ----- 1. 如果 MySQL 已安装 -----
    if command -v mysql &> /dev/null; then
        MYSQL_VERSION=$(mysql --version | awk '{print $5}' | sed 's/,//')
        MYSQL_MAJOR=$(echo "$MYSQL_VERSION" | cut -d. -f1)
        print_info "已安装 MySQL 版本: $MYSQL_VERSION"

        # 版本已满足要求，直接创建数据库后返回
        if [ "$MYSQL_MAJOR" -ge 8 ]; then
            print_info "MySQL 版本符合要求 (≥8.0)"
            mysql -u root -pc123456 -e "CREATE DATABASE IF NOT EXISTS \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
            return 0
        fi

        # ----- 2. 版本过低，执行自动升级 -----
        print_info "MySQL 版本 $MYSQL_VERSION < 8.0，开始自动升级..."
        BACKUP_DIR="/opt/mysql-backup-$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"

        # 逻辑备份所有数据库
        print_info "正在备份所有数据库到 $BACKUP_DIR/all-databases.sql"
        if mysqldump -u root -pc123456 --all-databases --single-transaction --routines --triggers > "$BACKUP_DIR/all-databases.sql" 2>/dev/null; then
            print_info "数据库逻辑备份完成 (路径: $BACKUP_DIR/all-databases.sql)"
        else
            print_error "数据库备份失败，升级已终止"
            exit 1
        fi

        # 停止 MySQL 服务
        systemctl stop mysql 2>/dev/null || systemctl stop mysqld 2>/dev/null || service mysql stop 2>/dev/null
        sleep 2

        # 卸载旧版本（询问用户确认）
        print_warning "即将卸载旧版 MySQL，数据已备份至 $BACKUP_DIR"
        read -p "是否继续卸载并安装 MySQL 8.0？(y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "升级已取消"
            exit 1
        fi

        case "${OS}" in
            ubuntu|debian)
                # 阻止卸载时询问是否删除数据目录
                echo "mysql-server mysql-server/postrm_remove_databases boolean false" | debconf-set-selections
                echo "mysql-server-8.0 mysql-server/postrm_remove_databases boolean false" | debconf-set-selections 2>/dev/null
                echo "mysql-server-5.7 mysql-server/postrm_remove_databases boolean false" | debconf-set-selections 2>/dev/null

                apt-get remove --purge -y mysql-server mysql-client mysql-common mysql-server-* mysql-client-* 2>/dev/null
                apt-get autoremove -y
                ;;
            centos|almalinux|rocky|oracle|rhel|fedora)
                yum remove -y mysql-server mysql mysql-community-server mysql-community-client 2>/dev/null || \
                dnf remove -y mysql-server mysql mysql-community-server mysql-community-client 2>/dev/null
                rm -f /etc/yum.repos.d/mysql-community*.repo
                ;;
        esac
        print_info "旧版 MySQL 已卸载"

        # 物理备份原数据目录（用于极端情况回滚）
        if [ -d "/var/lib/mysql" ]; then
            mv /var/lib/mysql "$BACKUP_DIR/mysql-data"
            print_info "原始数据目录已备份至 $BACKUP_DIR/mysql-data"
        fi

    else
        print_info "未检测到 MySQL，将全新安装 MySQL 8.0"
    fi

    # ----- 3. 安装 MySQL 8.0 -----
    print_info "正在安装 MySQL 8.0..."
    case "${OS}" in
        ubuntu|debian)
            # 添加官方 APT 仓库（完全无人值守）
            wget -q https://dev.mysql.com/get/mysql-apt-config_0.8.24-1_all.deb -O /tmp/mysql-apt-config.deb
            echo "mysql-apt-config mysql-apt-config/select-server select mysql-8.0" | debconf-set-selections
            echo "mysql-apt-config mysql-apt-config/select-product select Ok" | debconf-set-selections
            export DEBIAN_FRONTEND=noninteractive
            dpkg -i /tmp/mysql-apt-config.deb
            apt-get update -qq

            # 预配置 MySQL root 密码
            echo "mysql-community-server mysql-community-server/root-pass password c123456" | debconf-set-selections
            echo "mysql-community-server mysql-community-server/re-root-pass password c123456" | debconf-set-selections
            apt-get install -y mysql-server
            ;;
        centos|almalinux|rocky|oracle|rhel|fedora)
            # 添加官方 YUM 仓库
            rpm -Uvh https://dev.mysql.com/get/mysql80-community-release-el7-3.noarch.rpm 2>/dev/null || \
            rpm -Uvh https://dev.mysql.com/get/mysql80-community-release-el8-1.noarch.rpm 2>/dev/null || \
            rpm -Uvh https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm 2>/dev/null
            # 启用 8.0 仓库，禁用 5.7
            yum-config-manager --disable mysql57-community 2>/dev/null
            yum-config-manager --enable mysql80-community 2>/dev/null
            # 安装
            yum install -y mysql-server 2>/dev/null || dnf install -y mysql-server
            ;;
        *)
            print_error "不支持的操作系统: $OS，请手动安装 MySQL 8.0"
            exit 1
            ;;
    esac

    # 启动服务
    systemctl start mysqld 2>/dev/null || systemctl start mysql 2>/dev/null
    systemctl enable mysqld 2>/dev/null || systemctl enable mysql 2>/dev/null
    sleep 5

    # 处理 CentOS 系列首次启动生成的临时密码
    if [[ "$OS" =~ ^(centos|almalinux|rocky|oracle|rhel|fedora)$ ]]; then
        TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}')
        if [ -n "$TEMP_PASS" ]; then
            mysql --connect-expired-password -u root -p"$TEMP_PASS" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'c123456';" 2>/dev/null
        fi
    fi

    # 确保 root 密码已正确设置
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'c123456';" 2>/dev/null

    # 简单安全配置
    mysql -u root -pc123456 -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null
    mysql -u root -pc123456 -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null
    mysql -u root -pc123456 -e "DROP DATABASE IF EXISTS test;" 2>/dev/null
    mysql -u root -pc123456 -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null
    mysql -u root -pc123456 -e "FLUSH PRIVILEGES;" 2>/dev/null

    print_info "MySQL 8.0 安装完成"

    # ----- 4. 恢复数据（如果有备份）-----
    if [ -f "$BACKUP_DIR/all-databases.sql" ]; then
        print_info "正在恢复数据..."
        if mysql -u root -pc123456 < "$BACKUP_DIR/all-databases.sql" 2>/dev/null; then
            print_info "数据恢复成功"
        else
            print_error "数据恢复失败，请手动从 $BACKUP_DIR/all-databases.sql 导入"
        fi
    fi

    # 创建项目数据库
    mysql -u root -pc123456 -e "CREATE DATABASE IF NOT EXISTS \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
        print_warning "无法自动创建数据库，请手动执行："
        echo "  mysql -u root -p -e \"CREATE DATABASE \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
    }

    print_info "MySQL 处理完成！"
}

# 创建用户和目录
setup_user_and_dir() {
    print_info "创建用户和目录..."

    if ! id -u suimaster &> /dev/null; then
        useradd -r -s /bin/false suimaster
        print_info "用户 suimaster 创建成功"
    fi

    mkdir -p /opt/sui-master/{config,logs,uploads,config/web/static}

    # 创建持久化的 jprotobuf 缓存目录
    mkdir -p /opt/sui-master/jprotobuf-cache
    mkdir -p /opt/sui-master/tmp

    chown -R suimaster:suimaster /opt/sui-master
    chmod 755 /opt/sui-master/logs
    chmod 755 /opt/sui-master/jprotobuf-cache
    chmod 755 /opt/sui-master/tmp

    print_info "目录创建完成"
}

# 下载并验证 JAR（使用 jq + assets API，标准URL作为备用）
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

    # 检查 API 响应是否有效
    if echo "$API_RESPONSE" | grep -q '"message"'; then
        ERROR_MSG=$(echo "$API_RESPONSE" | grep -o '"message": "[^"]*"' | cut -d'"' -f4)
        print_error "API 请求失败: $ERROR_MSG"
        print_info "请检查 GitHub 令牌权限和仓库访问权限"
        exit 1
    fi

    # 使用 jq 提取版本号（仅用于显示）
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
             -O "/opt/sui-master/$JAR_NAME" "$ASSETS_DOWNLOAD_URL" || DOWNLOAD_ERROR=true
    else
        curl -L -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/octet-stream" \
             -o "/opt/sui-master/$JAR_NAME" "$ASSETS_DOWNLOAD_URL" || DOWNLOAD_ERROR=true
    fi

    # 如果 assets API 下载失败，回退到标准 Release URL
    if [ "$DOWNLOAD_ERROR" = true ] || [ ! -f "/opt/sui-master/$JAR_NAME" ]; then
        print_warning "assets API 下载失败，尝试使用标准 Release URL..."
        STANDARD_URL="https://github.com/$GITHUB_REPO/releases/download/$LATEST_VERSION/$JAR_NAME"
        DOWNLOAD_ERROR=false
        if command -v wget &> /dev/null; then
            wget --header="Authorization: token $GITHUB_TOKEN" \
                 -O "/opt/sui-master/$JAR_NAME" "$STANDARD_URL" || DOWNLOAD_ERROR=true
        else
            curl -L -H "Authorization: token $GITHUB_TOKEN" \
                 -o "/opt/sui-master/$JAR_NAME" "$STANDARD_URL" || DOWNLOAD_ERROR=true
        fi
        if [ "$DOWNLOAD_ERROR" = true ] || [ ! -f "/opt/sui-master/$JAR_NAME" ]; then
            print_error "所有下载方式均失败"
            print_info "请检查:"
            print_info "1. GitHub 令牌是否有正确的权限 (repo)"
            print_info "2. 仓库是否为私有仓库"
            print_info "3. Release 版本是否存在"
            print_info "4. JAR 文件名是否正确"
            exit 1
        fi
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
        print_warning "未获取到 digest 信息，跳过 SHA256 校验"
    fi

    chown suimaster:suimaster "/opt/sui-master/$JAR_NAME"
    print_info "文件下载完成"
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
    mkdir -p /opt/sui-master/jprotobuf-cache
    mkdir -p /opt/sui-master/tmp
    chown -R suimaster:suimaster /opt/sui-master/logs /opt/sui-master/jprotobuf-cache /opt/sui-master/tmp
    chmod 755 /opt/sui-master/logs /opt/sui-master/jprotobuf-cache /opt/sui-master/tmp

    # JVM 参数 - 使用持久化目录
    JVM_OPTS="-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m"
    JVM_OPTS="$JVM_OPTS -Djava.io.tmpdir=/opt/sui-master/tmp"
    JVM_OPTS="$JVM_OPTS -Djprotobuf.cache.dir=/opt/sui-master/jprotobuf-cache"
    JVM_OPTS="$JVM_OPTS -Djprotobuf.cache.enable=true"

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
    echo "StandardOutput=file:/opt/sui-master/logs/sui-master.log" >> "$SERVICE_FILE"
    echo "StandardError=file:/opt/sui-master/logs/sui-master-error.log" >> "$SERVICE_FILE"

    # 添加环境变量
    echo "Environment=JPROTOBUF_CACHE_DIR=/opt/sui-master/jprotobuf-cache" >> "$SERVICE_FILE"
    echo "Environment=JAVA_OPTS=${JVM_OPTS}" >> "$SERVICE_FILE"

    echo "" >> "$SERVICE_FILE"
    echo "[Install]" >> "$SERVICE_FILE"
    echo "WantedBy=multi-user.target" >> "$SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable sui-master
    print_info "systemd 服务创建完成"
}

# 清理旧的缓存
cleanup_caches() {
    print_info "清理旧的缓存..."

    # 清理旧的 /tmp 缓存
    if [ -d "/tmp/JPROTOBUF_CACHE_DIR" ]; then
        print_info "删除旧的 /tmp 缓存..."
        rm -rf /tmp/JPROTOBUF_CACHE_DIR
    fi

    # 确保新目录存在且权限正确
    mkdir -p /opt/sui-master/jprotobuf-cache
    mkdir -p /opt/sui-master/tmp
    chown -R suimaster:suimaster /opt/sui-master/jprotobuf-cache /opt/sui-master/tmp
    chmod 755 /opt/sui-master/jprotobuf-cache /opt/sui-master/tmp

    print_info "缓存清理完成"
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
    cleanup_caches  # 清理旧的temp缓存
    start_service
    show_complete
    print_info "安装完成！"
}

# 执行主函数
main
