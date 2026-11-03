#!/bin/bash
# SUI Master 一键安装/更新脚本
# 用法: bash <(curl -Ls https://raw.githubusercontent.com/mcqwyhud/sui-group/main/master_linux_install_v1.0.sh)

set -e

# ============================================
# 第一部分：颜色与输出定义（共用）
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

print_info() { echo -e "${GREEN}✔ [INFO]${NC} $1"; }
print_error() { echo -e "${RED}✘ [ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠ [WARN]${NC} $1"; }

# ============================================
# 第二部分：检查组件是否已安装
# ============================================
is_java_installed() {
    if command -v java &> /dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
        if [ "$JAVA_VERSION" -ge 21 ]; then
            return 0
        fi
    fi
    return 1
}

is_mysql_installed() {
    command -v mysql &> /dev/null
}

is_user_exists() {
    id -u suimaster &> /dev/null
}

is_service_exists() {
    [ -f "/etc/systemd/system/sui-master.service" ]
}

is_management_script_exists() {
    [ -f "/usr/local/bin/sui-m" ]
}

# ============================================
# 第三部分：安装功能
# ============================================
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

install_java() {
    if is_java_installed; then
        print_info "Java 21 已安装，跳过"
        return 0
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

install_mysql() {
    if is_mysql_installed; then
        MYSQL_VERSION=$(mysql --version | awk '{print $5}' | sed 's/,//')
        print_info "MySQL 已安装，跳过安装 (版本: $MYSQL_VERSION)"
        
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

    sleep 5
    print_info "创建数据库..."
    mysql -u root -pc123456 -e "CREATE DATABASE IF NOT EXISTS \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || {
        print_warning "无法创建数据库，请手动执行："
        echo "  mysql -u root -p -e \"CREATE DATABASE \`s-ui\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""
    }
    print_info "数据库创建完成"
}

setup_user_and_dir() {
    print_info "创建用户和目录..."

    if is_user_exists; then
        print_info "用户 suimaster 已存在，跳过创建"
    else
        useradd -r -s /bin/false suimaster
        print_info "用户 suimaster 创建成功"
    fi

    mkdir -p /opt/sui-master/{config,logs,uploads,config/web/static,conf}
    mkdir -p /opt/sui-master/jprotobuf-cache
    mkdir -p /opt/sui-master/tmp

    chown -R suimaster:suimaster /opt/sui-master
    chmod 755 /opt/sui-master/logs
    chmod 755 /opt/sui-master/jprotobuf-cache
    chmod 755 /opt/sui-master/tmp
    chmod 755 /opt/sui-master/conf

    JVM_CONF="/opt/sui-master/conf/jvm_opts"
    if [ ! -f "$JVM_CONF" ]; then
        echo "-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m" > "$JVM_CONF"
        chown suimaster:suimaster "$JVM_CONF"
        print_info "默认 JVM 参数已写入 $JVM_CONF"
    else
        print_info "JVM 配置文件已存在，保留现有配置"
    fi

    print_info "目录创建完成"
}

# 每次都重新下载 JAR
download_and_verify_jar() {
    print_info "开始下载最新 JAR 文件..."

    # 备份旧 JAR（如果存在）
    if ls /opt/sui-master/*.jar 1> /dev/null 2>&1; then
        OLD_JAR=$(ls /opt/sui-master/*.jar | head -1)
        BACKUP_JAR="${OLD_JAR}.bak.$(date +%Y%m%d_%H%M%S)"
        mv "$OLD_JAR" "$BACKUP_JAR"
        print_info "旧 JAR 已备份: $BACKUP_JAR"
    fi

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

    if echo "$API_RESPONSE" | grep -q '"message"'; then
        ERROR_MSG=$(echo "$API_RESPONSE" | grep -o '"message": "[^"]*"' | cut -d'"' -f4)
        print_error "API 请求失败: $ERROR_MSG"
        print_info "请检查 GitHub 令牌权限和仓库访问权限"
        exit 1
    fi

    LATEST_VERSION=$(echo "$API_RESPONSE" | jq -r '.tag_name // empty')
    if [ -z "$LATEST_VERSION" ]; then
        print_error "无法获取最新版本，请检查令牌和仓库设置"
        print_info "API 响应: $API_RESPONSE"
        exit 1
    fi
    print_info "最新版本: $LATEST_VERSION"

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
            # 恢复备份
            if [ -f "$BACKUP_JAR" ]; then
                mv "$BACKUP_JAR" "$OLD_JAR"
                print_info "已恢复旧 JAR 文件"
            fi
            exit 1
        fi
    fi

    if [ -n "$EXPECTED_SHA256" ]; then
        print_info "计算本地 JAR 的 SHA256..."
        LOCAL_SHA256=$(sha256sum "/opt/sui-master/$JAR_NAME" | awk '{print $1}')
        if [ "$LOCAL_SHA256" != "$EXPECTED_SHA256" ]; then
            print_error "SHA256 校验失败！"
            print_info "期望: $EXPECTED_SHA256"
            print_info "实际: $LOCAL_SHA256"
            # 恢复备份
            if [ -f "$BACKUP_JAR" ]; then
                mv "$BACKUP_JAR" "$OLD_JAR"
                print_info "已恢复旧 JAR 文件"
            fi
            exit 1
        fi
        print_info "SHA256 校验通过 ✓"
    else
        print_warning "未获取到 digest 信息，跳过 SHA256 校验"
    fi

    chown suimaster:suimaster "/opt/sui-master/$JAR_NAME"
    
    # 删除旧备份（保留最近3个）
    ls -t /opt/sui-master/*.jar.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
    
    print_info "JAR 文件下载完成: $JAR_NAME"
}

get_jvm_opts() {
    JVM_CONF="/opt/sui-master/conf/jvm_opts"
    if [ -f "$JVM_CONF" ]; then
        cat "$JVM_CONF"
    else
        echo "-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=64m"
    fi
}

create_service() {
    print_info "创建/更新 systemd 服务..."

    JAR_FILE=$(ls /opt/sui-master/*.jar | grep -v '.bak.' | head -1)
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        exit 1
    fi
    print_info "使用 JAR 文件: $JAR_FILE"

    mkdir -p /opt/sui-master/logs
    mkdir -p /opt/sui-master/jprotobuf-cache
    mkdir -p /opt/sui-master/tmp
    chown -R suimaster:suimaster /opt/sui-master/logs /opt/sui-master/jprotobuf-cache /opt/sui-master/tmp
    chmod 755 /opt/sui-master/logs /opt/sui-master/jprotobuf-cache /opt/sui-master/tmp

    JVM_OPTS=$(get_jvm_opts)
    JVM_OPTS="$JVM_OPTS -Djava.io.tmpdir=/opt/sui-master/tmp -Djprotobuf.cache.dir=/opt/sui-master/jprotobuf-cache -Djprotobuf.cache.enable=true"

    SERVICE_FILE="/etc/systemd/system/sui-master.service"
    
    # 如果服务已存在，先停止
    if systemctl is-active --quiet sui-master 2>/dev/null; then
        print_info "停止旧服务..."
        systemctl stop sui-master
    fi
    
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
    print_info "systemd 服务创建/更新完成"
}

cleanup_caches() {
    print_info "清理旧的缓存..."

    if [ -d "/tmp/JPROTOBUF_CACHE_DIR" ]; then
        print_info "删除旧的 /tmp 缓存..."
        rm -rf /tmp/JPROTOBUF_CACHE_DIR
    fi

    mkdir -p /opt/sui-master/jprotobuf-cache
    mkdir -p /opt/sui-master/tmp
    chown -R suimaster:suimaster /opt/sui-master/jprotobuf-cache /opt/sui-master/tmp
    chmod 755 /opt/sui-master/jprotobuf-cache /opt/sui-master/tmp

    print_info "缓存清理完成"
}

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

show_complete() {
    echo ""
    echo -e "${CYAN}================================================${NC}"
    echo -e "        ${PURPLE}🎉 SUI Master 部署完成！${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo -e "${YELLOW}【 管理命令 】${NC}"
    echo -e "  ${GREEN}sui-m${NC}             进入交互式管理菜单 (推荐)"
    echo -e "  ${GREEN}sui-m start${NC}       启动服务"
    echo -e "  ${GREEN}sui-m stop${NC}        停止服务"
    echo -e "  ${GREEN}sui-m restart${NC}     重启服务"
    echo -e "  ${GREEN}sui-m logs${NC}        查看实时日志"
    echo -e ""
    echo -e "${YELLOW}【 目录与配置 】${NC}"
    echo -e "  配置文件: ${GRAY}/opt/sui-master/config/application.yml${NC}"
    echo -e "  日志文件: ${GRAY}/opt/sui-master/logs/${NC}"
    echo -e "  数据库名: ${GRAY}s-ui${NC}"
    echo -e "  数据库密: ${GRAY}c123456${NC}"
    echo -e ""
    echo -e "${YELLOW}【 重要提示 】${NC}"
    echo -e "  首次启动请查看日志中的临时密码："
    echo -e "  ${GRAY}journalctl -u sui-master | grep 'Using generated security password'${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo ""
}

# ============================================
# 第四部分：生成管理脚本
# ============================================
create_management_script() {
    if is_management_script_exists; then
        print_info "管理脚本已存在，更新中..."
    else
        print_info "创建自定义命令 sui-m ..."
    fi

    cat > /usr/local/bin/sui-m << 'EOF'
#!/bin/bash
# SUI Master 管理脚本（包含交互式菜单，美化版）

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m'

print_info() { echo -e "${GREEN}✔ [INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}⚠ [WARN]${NC} $1"; }
print_error() { echo -e "${RED}✘ [ERROR]${NC} $1"; }

SERVICE="sui-master"
SERVICE_FILE="/etc/systemd/system/sui-master.service"
JVM_CONF="/opt/sui-master/conf/jvm_opts"

show_status(){
    # 检查服务状态
    local status_color="${RED}"
    local status_text="🔴 已停止"
    if systemctl is-active --quiet $SERVICE; then
        status_color="${GREEN}"
        status_text="🟢 运行中"
    fi

    # 检查自重启
    local restart_text="${GREEN}✅ 开启(on-failure)${NC}"
    if grep -q "^Restart=no" $SERVICE_FILE 2>/dev/null; then
        restart_text="${RED}❌ 关闭${NC}"
    fi

    local jvm_text=$(cat "$JVM_CONF" 2>/dev/null || echo "默认")

    echo ""
    echo -e "${CYAN}================================================${NC}"
    echo -e "  ${PURPLE}📊 SUI-MASTER 当前状态${NC}"
    echo -e "${CYAN}------------------------------------------------${NC}"
    echo -e "  服务状态   : ${status_color}${status_text}${NC}"
    echo -e "  自重启策略 : ${restart_text}"
    echo -e "  JVM 参数   : ${YELLOW}${jvm_text}${NC}"
    echo -e "${CYAN}================================================${NC}"
}

show_jvm(){
    cat "$JVM_CONF" 2>/dev/null || echo "默认 JVM 参数未配置"
}

set_jvm(){
    echo "$1" > "$JVM_CONF"
    chown suimaster:suimaster "$JVM_CONF"
    
    JAR_FILE=$(ls /opt/sui-master/*.jar | grep -v '.bak.' | head -1)
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        return 1
    fi
    
    JVM_OPTS="$1 -Djava.io.tmpdir=/opt/sui-master/tmp -Djprotobuf.cache.dir=/opt/sui-master/jprotobuf-cache -Djprotobuf.cache.enable=true"
    
    sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/java ${JVM_OPTS} -jar ${JAR_FILE}|" "$SERVICE_FILE"
    sed -i "s|^Environment=JAVA_OPTS=.*|Environment=JAVA_OPTS=${JVM_OPTS}|" "$SERVICE_FILE"
    
    systemctl daemon-reload
    print_info "JVM参数已更新并同步"
    
    read -p "是否立即重启 SUI Master 服务以应用新参数？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        systemctl restart $SERVICE
        print_info "服务已重启"
    else
        print_info "请手动执行 'sui-m restart' 使参数生效"
    fi
}

autorestart(){
    case "$1" in
        on)
            sed -i 's/^Restart=.*/Restart=on-failure/' "$SERVICE_FILE"
            if grep -q "^RestartSec=" "$SERVICE_FILE"; then
                sed -i 's/^RestartSec=.*/RestartSec=10/' "$SERVICE_FILE"
            else
                sed -i '/Restart=on-failure/a RestartSec=10' "$SERVICE_FILE"
            fi
            systemctl daemon-reload
            print_info "自重启已开启（失败后10秒重启）"
            ;;
        off)
            sed -i 's/^Restart=.*/Restart=no/' "$SERVICE_FILE"
            systemctl daemon-reload
            print_info "自重启已关闭"
            ;;
        *)
            print_warn "用法: sui-m autorestart on|off"
            ;;
    esac
}

menu(){
    while true; do
        clear # 每次循环清屏，让界面更干净
        show_status

        echo -e "${CYAN}================================================${NC}"
        echo -e "        ${PURPLE}🚀 SUI-M 服务管理控制台${NC}"
        echo -e "${CYAN}================================================${NC}"
        
        echo -e "${YELLOW}【 服务控制 】${NC}"
        echo -e "  ${GREEN}1)${NC} 启动服务          ${GREEN}2)${NC} 停止服务"
        echo -e "  ${GREEN}3)${NC} 重启服务          ${GREEN}4)${NC} 查看实时日志"
        
        echo -e ""
        echo -e "${YELLOW}【 状态与配置 】${NC}"
        echo -e "  ${GREEN}5)${NC} 查看详细状态      ${GREEN}6)${NC} 修改 JVM 参数"
        echo -e "  ${GREEN}7)${NC} 开启自重启        ${GREEN}8)${NC} 关闭自重启"
        
        echo -e ""
        echo -e "${YELLOW}【 系统维护 】${NC}"
        echo -e "  ${GREEN}9)${NC} 📦 更新 JAR 文件 (从 GitHub 拉取最新版本)"
        
        echo -e ""
        echo -e "  ${RED}0)${NC} 🚪 退出管理菜单"
        echo -e "${CYAN}================================================${NC}"
        
        read -p "请选择操作 [0-9]: " opt

        case $opt in
            1) systemctl start $SERVICE && print_info "已启动" ;;
            2) systemctl stop $SERVICE && print_info "已停止" ;;
            3) systemctl restart $SERVICE && print_info "已重启" ;;
            4) journalctl -u $SERVICE -f ;;
            5) systemctl status $SERVICE ;;
            6)
                echo -e "${CYAN}当前 JVM 参数:${NC} $(show_jvm)"
                echo ""
                read -p "请输入新的 JVM 参数 (回车跳过): " j
                [ -n "$j" ] && set_jvm "$j"
                ;;
            7) autorestart on ;;
            8) autorestart off ;;
            9) 
                echo -e "${YELLOW}正在准备更新...${NC}"
                if [ -f "/tmp/update_jar.sh" ]; then
                    bash /tmp/update_jar.sh
                else
                    print_error "更新功能不可用，请重新运行一键安装脚本进行覆盖更新。"
                fi
                ;;
            0) exit 0 ;;
            *) print_warn "无效选项，请重新输入" ;;
        esac

        echo ""
        read -p "按回车键继续..."
    done
}

case "$1" in
    start)
        systemctl start $SERVICE
        echo -e "${GREEN}✔ SUI Master 服务已启动${NC}"
        ;;
    stop)
        systemctl stop $SERVICE
        echo -e "${GREEN}✔ SUI Master 服务已停止${NC}"
        ;;
    restart)
        systemctl restart $SERVICE
        echo -e "${GREEN}✔ SUI Master 服务已重启${NC}"
        ;;
    status)
        systemctl status $SERVICE
        ;;
    logs)
        journalctl -u $SERVICE -f
        ;;
    jvm)
        case "$2" in
            show|"")
                show_jvm
                ;;
            set)
                if [ -z "$3" ]; then
                    print_error "请提供 JVM 参数"
                    exit 1
                fi
                set_jvm "$3"
                ;;
            *)
                echo "用法: sui-m jvm [show|set \"JVM_OPTS\"]"
                echo "  jvm              - 交互式修改"
                echo "  jvm show         - 显示当前 JVM 参数"
                echo "  jvm set \"...\"    - 设置新的 JVM 参数"
                ;;
        esac
        ;;
    autorestart)
        autorestart "$2"
        ;;
    ""|menu)
        menu
        ;;
    *)
        echo -e "${CYAN}================================================${NC}"
        echo -e "        ${PURPLE}🚀 SUI Master 管理工具${NC}"
        echo -e "${CYAN}================================================${NC}"
        echo -e "  sui-m              进入交互式菜单"
        echo -e "  sui-m start        启动服务"
        echo -e "  sui-m stop         停止服务"
        echo -e "  sui-m restart      重启服务"
        echo -e "  sui-m status       查看详细状态"
        echo -e "  sui-m logs         查看实时日志"
        echo -e "  sui-m jvm          查看/修改 JVM"
        echo -e "  sui-m autorestart  配置自重启"
        echo -e "${CYAN}================================================${NC}"
        ;;
esac
EOF

    chmod +x /usr/local/bin/sui-m
    print_info "管理脚本创建/更新完成"
}

# ============================================
# 第五部分：更新 JAR 的独立函数（供管理脚本调用）
# ============================================
update_jar_only() {
    print_info "更新 JAR 文件..."
    
    # 备份旧 JAR
    if ls /opt/sui-master/*.jar 1> /dev/null 2>&1; then
        OLD_JAR=$(ls /opt/sui-master/*.jar | grep -v '.bak.' | head -1)
        if [ -n "$OLD_JAR" ]; then
            BACKUP_JAR="${OLD_JAR}.bak.$(date +%Y%m%d_%H%M%S)"
            mv "$OLD_JAR" "$BACKUP_JAR"
            print_info "旧 JAR 已备份: $BACKUP_JAR"
        fi
    fi
    
    # 重新下载
    download_and_verify_jar
    
    # 更新服务
    create_service
    
    # 重启服务
    systemctl restart sui-master
    sleep 2
    
    if systemctl is-active --quiet sui-master; then
        print_info "服务更新成功并已重启"
    else
        print_error "服务启动失败，请检查日志"
    fi
}

# ============================================
# 第六部分：安装主流程
# ============================================
install_service() {
    print_info "开始部署 SUI Master..."
    check_root
    detect_os
    install_base
    install_java
    install_mysql
    setup_user_and_dir
    download_and_verify_jar  # 每次都重新下载
    create_service           # 每次更新服务文件
    create_management_script
    cleanup_caches
    start_service
    show_complete
    print_info "部署完成！"
}

# ============================================
# 第七部分：主入口
# ============================================
main() {
    # 生成独立的更新脚本（供管理菜单调用）
    cat > /tmp/update_jar.sh << 'EOF'
#!/bin/bash
# JAR 更新脚本
print_info() { echo -e "\033[0;32m✔ [INFO]\033[0m $1"; }
print_error() { echo -e "\033[0;31m✘ [ERROR]\033[0m $1"; }

# 重新下载 JAR
if [ -f "/opt/sui-master/conf/jvm_opts" ]; then
    print_info "请运行完整安装脚本来更新:"
    echo "  bash <(curl -Ls https://raw.githubusercontent.com/mcqwyhud/sui-group/main/master_linux_install_v1.0.sh)"
else
    print_error "SUI Master 未安装"
fi
EOF
    chmod +x /tmp/update_jar.sh

    # 直接执行安装/更新
    install_service
}

main
