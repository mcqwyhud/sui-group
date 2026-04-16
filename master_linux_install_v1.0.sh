#!/bin/bash

# SUI Master 一键安装脚本
# 修复日志权限错误问题
# 支持动态修改 JVM 参数

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

    mkdir -p /opt/sui-master/{config,logs,uploads,config/web/static,conf}

    # 创建持久化的 jprotobuf 缓存目录
    mkdir -p /opt/sui-master/jprotobuf-cache
    mkdir -p /opt/sui-master/tmp

    chown -R suimaster:suimaster /opt/sui-master
    chmod 755 /opt/sui-master/logs
    chmod 755 /opt/sui-master/jprotobuf-cache
    chmod 755 /opt/sui-master/tmp
    chmod 755 /opt/sui-master/conf

    # 写入默认 JVM 参数配置文件（如果不存在）
    JVM_CONF="/opt/sui-master/conf/jvm_opts"
    if [ ! -f "$JVM_CONF" ]; then
        echo "-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m" > "$JVM_CONF"
        chown suimaster:suimaster "$JVM_CONF"
        print_info "默认 JVM 参数已写入 $JVM_CONF"
    fi

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

# 读取 JVM 参数配置
get_jvm_opts() {
    JVM_CONF="/opt/sui-master/conf/jvm_opts"
    if [ -f "$JVM_CONF" ]; then
        cat "$JVM_CONF"
    else
        echo "-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m"
    fi
}

# 创建 systemd 服务（动态读取 JVM 参数）
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

    JVM_OPTS=$(get_jvm_opts)
    # 附加系统属性
    JVM_OPTS="$JVM_OPTS -Djava.io.tmpdir=/opt/sui-master/tmp -Djprotobuf.cache.dir=/opt/sui-master/jprotobuf-cache -Djprotobuf.cache.enable=true"

    SERVICE_FILE="/etc/systemd/system/sui-master.service"
    > "$SERVICE_FILE"
    cat >> "$SERVICE_FILE" <<EOF
[Unit]
Description=SUI Master Service
After=network.target mysql.service

[Service]
Type=simple
User=suimaster
WorkingDirectory=/opt/sui-master
ExecStart=/usr/bin/java ${JVM_OPTS} -jar ${JAR_FILE}
Restart=on-failure
RestartSec=10
Environment=JPROTOBUF_CACHE_DIR=/opt/sui-master/jprotobuf-cache
Environment=JAVA_OPTS=${JVM_OPTS}

[Install]
WantedBy=multi-user.target
EOF

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

# 创建自定义命令（包含 JVM 参数管理功能）
create_custom_command() {
    print_info "创建自定义命令 sui-m ..."

    cat > /usr/local/bin/sui-m << 'EOF'
#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

JVM_CONF="/opt/sui-master/conf/jvm_opts"
SERVICE_FILE="/etc/systemd/system/sui-master.service"

# 显示当前 JVM 参数
show_jvm() {
    if [ -f "$JVM_CONF" ]; then
        echo "当前 JVM 参数: $(cat "$JVM_CONF")"
    else
        echo "默认 JVM 参数: -Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m"
    fi
}

# 设置新的 JVM 参数
set_jvm() {
    local new_opts="$1"
    if [ -z "$new_opts" ]; then
        print_error "请提供新的 JVM 参数，例如: -Xms256m -Xmx512m"
        exit 1
    fi
    # 备份原配置
    if [ -f "$JVM_CONF" ]; then
        cp "$JVM_CONF" "$JVM_CONF.bak"
    fi
    echo "$new_opts" > "$JVM_CONF"
    chown suimaster:suimaster "$JVM_CONF"
    print_info "JVM 参数已更新: $new_opts"
    
    # 重新生成服务文件
    JAR_FILE=$(ls /opt/sui-master/*.jar | head -1)
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        exit 1
    fi
    
    # 读取新的 JVM 参数并附加系统属性
    JVM_OPTS=$(cat "$JVM_CONF")
    JVM_OPTS="$JVM_OPTS -Djava.io.tmpdir=/opt/sui-master/tmp -Djprotobuf.cache.dir=/opt/sui-master/jprotobuf-cache -Djprotobuf.cache.enable=true"
    
    # 更新服务文件中的 ExecStart 行
    sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/java ${JVM_OPTS} -jar ${JAR_FILE}|" "$SERVICE_FILE"
    systemctl daemon-reload
    print_info "systemd 服务文件已更新"
    
    # 询问是否重启
    read -p "是否立即重启 SUI Master 服务以应用新参数？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl restart sui-master
        print_info "服务已重启"
    else
        print_info "请手动执行 'sui-m restart' 使参数生效"
    fi
}

# 交互式修改 JVM 参数
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
        echo "用法: sui-m {start|stop|restart|status|logs|jvm [show|set \"JVM_OPTS\"]}"
        echo ""
        echo "  jvm              - 交互式修改 JVM 参数"
        echo "  jvm show         - 显示当前 JVM 参数"
        echo "  jvm set \"...\"    - 设置新的 JVM 参数（完整字符串）"
        echo "  示例: sui-m jvm set \"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=128m\""
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
    echo "  sui-m start       # 启动服务"
    echo "  sui-m stop        # 停止服务"
    echo "  sui-m restart     # 重启服务"
    echo "  sui-m status      # 查看状态"
    echo "  sui-m logs        # 查看日志"
    echo "  sui-m jvm         # 交互式修改 JVM 参数"
    echo "  sui-m jvm show    # 显示当前 JVM 参数"
    echo "  sui-m jvm set \"...\" # 直接设置 JVM 参数"
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
    cleanup_caches
    start_service
    show_complete
    print_info "安装完成！"
}

# 执行主函数
main
