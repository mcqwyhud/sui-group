#!/bin/bash
# SUI Agent 一键安装脚本
# 支持 Linux 系统，自动安装依赖，从私有仓库下载 jar 并部署为 systemd 服务
# 改进：使用 jq + assets API，增加 SHA256 校验，支持 JVM 参数动态修改
# 注意：Agent 为 iogame 应用，无 Spring Boot，无需 jprotobuf-cache 和 tmp 目录
# SUI Agent 一键安装脚本（完整版 + JSON交互配置增强版）
# 支持 Linux + GitHub Release + systemd + JVM 管理 + JSON交互初始化

set -e

# =========================
# 颜色定义
# =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# =========================
# root检查
# =========================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# =========================
# OS检测
# =========================
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

# =========================
# 基础工具安装
# =========================
install_base() {
    print_info "检查基础工具..."
    local tools=("wget" "curl" "tar" "tzdata" "jq")
    local missing=()

    for t in "${tools[@]}"; do
        if ! command -v "$t" &>/dev/null; then
            if [ "$t" != "tzdata" ]; then
                missing+=("$t")
            fi
        fi
    done

    if [ ! -d "/usr/share/zoneinfo" ]; then
        missing+=("tzdata")
    fi

    if [ ${#missing[@]} -eq 0 ]; then
        print_info "基础工具已安装 (wget, curl, tar, tzdata, jq)"
        return 0
    fi

    print_info "需要安装的工具: ${missing[*]}"
    
    # 更新缓存
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
        esac
    fi

    print_info "安装缺失的基础工具..."
    case "${OS}" in
        ubuntu|debian)
            apt-get install -y -qq "${missing[@]}"
            ;;
        centos|almalinux|rocky|oracle|rhel)
            yum install -y -q "${missing[@]}"
            ;;
        fedora)
            dnf install -y -q "${missing[@]}"
            ;;
        *)
            print_error "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
    print_info "基础工具安装完成"
}

# =========================
# Java 安装
# =========================
install_java() {
    print_info "检查 Java 环境..."
    if command -v java &>/dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
        if [ "$JAVA_VERSION" -ge 21 ]; then
            print_info "已安装 Java 版本: $(java -version 2>&1 | head -1)"
            return
        fi
    fi

    print_info "正在安装 Java 21..."
    case "${OS}" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq openjdk-21-jre-headless
            ;;
        centos|rhel|almalinux|rocky|oracle)
            yum install -y -q java-21-openjdk-headless
            ;;
        fedora)
            dnf install -y -q java-21-openjdk-headless
            ;;
        *)
            print_error "不支持的操作系统: $OS，请手动安装 Java 21"
            exit 1
            ;;
    esac

    if command -v java &>/dev/null; then
        print_info "Java 安装成功: $(java -version 2>&1 | head -1)"
    else
        print_error "Java 安装失败"
        exit 1
    fi
}

# =========================
# 用户和目录创建
# =========================
setup_user_and_dir() {
    print_info "创建用户和目录..."
    if ! id -u suiagent &>/dev/null; then
        useradd -r -s /bin/false suiagent
        print_info "用户 suiagent 创建成功"
    fi

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

# =========================
# UUID 生成
# =========================
uuid_gen() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)"
    fi
}

# =========================
# JSON 配置（agent.json）
# =========================
setup_json_config() {
    print_info "初始化 JSON 配置..."
    mkdir -p /opt/sui-agent/config

    local CONFIG_FILE="/opt/sui-agent/config/agent.json"
    
    # 定义默认值
    local brokerKey_def="TuAyStnLhnVX9l215cgciVWFDhs2CrrehFZTEgJVtrM="
    local brokerHost_def="127.0.0.1"
    local brokerPort_def="10200"
    local suiSubUrl_def="http://127.0.0.1:2096/sub/"
    local suiApi2Key_def="cwCZa6Aq6lmKXjt3QeotgywhiDzXpb8U"
    local suiApi2Url_def="http://127.0.0.1:2095"
    local suiApi2Path_def="/app/apiv2"
    local agentName_def="子节点逻辑服1"
    local agentTag_def="子节点逻辑服"
    local reportVpsTime_def="600000"
    local auto_create_inbound_def="false"
    local auto_vpsId_def="美国1"
    local auto_up_mbps_def="0"
    local auto_down_mbps_def="0"

    # 初始化变量
    local brokerKey="$brokerKey_def"
    local brokerHost="$brokerHost_def"
    local brokerPort="$brokerPort_def"
    local suiSubUrl="$suiSubUrl_def"
    local suiApi2Key="$suiApi2Key_def"
    local suiApi2Url="$suiApi2Url_def"
    local suiApi2Path="$suiApi2Path_def"
    local agentName="$agentName_def"
    local agentTag="$agentTag_def"
    local reportVpsTime="$reportVpsTime_def"
    local auto_create_inbound="$auto_create_inbound_def"
    local auto_vpsId="$auto_vpsId_def"
    local auto_up_mbps="$auto_up_mbps_def"
    local auto_down_mbps="$auto_down_mbps_def"
    local pid=""

    # 如果存在配置文件则读取
    if [ -f "$CONFIG_FILE" ]; then
        print_info "检测到已有配置文件: $CONFIG_FILE"
        if command -v jq &>/dev/null; then
            # 读取配置，如果字段不存在则使用默认值
            local tmp_brokerKey=$(jq -r '.brokerKey // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_brokerHost=$(jq -r '.brokerHost // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_brokerPort=$(jq -r '.brokerPort // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_suiSubUrl=$(jq -r '.suiSubUrl // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_suiApi2Key=$(jq -r '.suiApi2Key // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_suiApi2Url=$(jq -r '.suiApi2Url // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_suiApi2Path=$(jq -r '.suiApi2Path // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_agentName=$(jq -r '.agentName // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_agentTag=$(jq -r '.agentTag // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_reportVpsTime=$(jq -r '.reportVpsTime // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_auto_create_inbound=$(jq -r '.auto_create_inbound // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_auto_vpsId=$(jq -r '.auto_vpsId // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_auto_up_mbps=$(jq -r '.auto_up_mbps // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_auto_down_mbps=$(jq -r '.auto_down_mbps // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
            local tmp_pid=$(jq -r '.pid // empty' "$CONFIG_FILE" 2>/dev/null || echo "")

            [ -n "$tmp_brokerKey" ] && brokerKey="$tmp_brokerKey"
            [ -n "$tmp_brokerHost" ] && brokerHost="$tmp_brokerHost"
            [ -n "$tmp_brokerPort" ] && brokerPort="$tmp_brokerPort"
            [ -n "$tmp_suiSubUrl" ] && suiSubUrl="$tmp_suiSubUrl"
            [ -n "$tmp_suiApi2Key" ] && suiApi2Key="$tmp_suiApi2Key"
            [ -n "$tmp_suiApi2Url" ] && suiApi2Url="$tmp_suiApi2Url"
            [ -n "$tmp_suiApi2Path" ] && suiApi2Path="$tmp_suiApi2Path"
            [ -n "$tmp_agentName" ] && agentName="$tmp_agentName"
            [ -n "$tmp_agentTag" ] && agentTag="$tmp_agentTag"
            [ -n "$tmp_reportVpsTime" ] && reportVpsTime="$tmp_reportVpsTime"
            [ -n "$tmp_auto_create_inbound" ] && auto_create_inbound="$tmp_auto_create_inbound"
            [ -n "$tmp_auto_vpsId" ] && auto_vpsId="$tmp_auto_vpsId"
            [ -n "$tmp_auto_up_mbps" ] && auto_up_mbps="$tmp_auto_up_mbps"
            [ -n "$tmp_auto_down_mbps" ] && auto_down_mbps="$tmp_auto_down_mbps"
            [ -n "$tmp_pid" ] && pid="$tmp_pid"
        else
            print_warning "jq 未安装，使用默认值"
        fi
    fi

    # 生成 PID
    if [ -z "$pid" ]; then
        pid=$(uuid_gen)
    fi

    echo ""
    print_info "开始交互式配置（直接回车使用默认值）"
    echo ""

    # 交互式输入
    read -p "brokerKey [$brokerKey]: " input
    brokerKey="${input:-$brokerKey}"
    
    read -p "brokerHost [$brokerHost]: " input
    brokerHost="${input:-$brokerHost}"
    
    read -p "brokerPort [$brokerPort]: " input
    brokerPort="${input:-$brokerPort}"
    
    read -p "suiSubUrl [$suiSubUrl]: " input
    suiSubUrl="${input:-$suiSubUrl}"
    
    read -p "suiApi2Key [$suiApi2Key]: " input
    suiApi2Key="${input:-$suiApi2Key}"
    
    read -p "suiApi2Url [$suiApi2Url]: " input
    suiApi2Url="${input:-$suiApi2Url}"
    
    read -p "suiApi2Path [$suiApi2Path]: " input
    suiApi2Path="${input:-$suiApi2Path}"
    
    read -p "agentName [$agentName]: " input
    agentName="${input:-$agentName}"
    
    read -p "agentTag [$agentTag]: " input
    agentTag="${input:-$agentTag}"
    
    read -p "reportVpsTime [$reportVpsTime]: " input
    reportVpsTime="${input:-$reportVpsTime}"
    
    read -p "auto_create_inbound [$auto_create_inbound]: " input
    auto_create_inbound="${input:-$auto_create_inbound}"
    
    read -p "auto_vpsId [$auto_vpsId]: " input
    auto_vpsId="${input:-$auto_vpsId}"
    
    read -p "auto_up_mbps [$auto_up_mbps]: " input
    auto_up_mbps="${input:-$auto_up_mbps}"
    
    read -p "auto_down_mbps [$auto_down_mbps]: " input
    auto_down_mbps="${input:-$auto_down_mbps}"

    # 写入配置文件
    cat > "$CONFIG_FILE" <<EOF
{
  "brokerKey": "$brokerKey",
  "brokerHost": "$brokerHost",
  "brokerPort": $brokerPort,
  "pid": "$pid",
  "agentName": "$agentName",
  "agentTag": "$agentTag",
  "reportVpsTime": $reportVpsTime,
  "suiSubUrl": "$suiSubUrl",
  "suiApi2Key": "$suiApi2Key",
  "suiApi2Url": "$suiApi2Url",
  "suiApi2Path": "$suiApi2Path",
  "auto_create_inbound": $auto_create_inbound,
  "auto_vpsId": "$auto_vpsId",
  "auto_up_mbps": $auto_up_mbps,
  "auto_down_mbps": $auto_down_mbps
}
EOF

    chown suiagent:suiagent "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    
    print_info "JSON 配置已保存到: $CONFIG_FILE"
}

# =========================
# 下载 JAR
# =========================
download_jar() {
    print_info "下载 JAR 文件..."
    local GITHUB_REPO="mcqwyhud/sui-agent"
    local RELEASE_URL="https://api.github.com/repos/$GITHUB_REPO/releases/latest"
    
    # 获取 GitHub Token
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
    local API_RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$RELEASE_URL")
    
    if echo "$API_RESPONSE" | grep -q '"message"'; then
        local ERROR_MSG=$(echo "$API_RESPONSE" | grep -o '"message": "[^"]*"' | cut -d'"' -f4)
        print_error "API 请求失败: $ERROR_MSG"
        exit 1
    fi

    local LATEST_VERSION=$(echo "$API_RESPONSE" | jq -r '.tag_name // empty')
    if [ -z "$LATEST_VERSION" ]; then
        print_error "无法获取最新版本"
        exit 1
    fi
    print_info "最新版本: $LATEST_VERSION"

    local JAR_NAME=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar")) | .name' | head -1)
    local ASSET_ID=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar")) | .id' | head -1)
    local EXPECTED_SHA256=$(echo "$API_RESPONSE" | jq -r '.assets[] | select(.name | endswith(".jar")) | .digest // ""' | head -1 | sed 's/^sha256://')

    if [ -z "$JAR_NAME" ] || [ -z "$ASSET_ID" ]; then
        print_error "发布版本中未找到 jar 文件"
        exit 1
    fi
    print_info "JAR 文件名: $JAR_NAME"

    # 尝试通过 assets API 下载
    local ASSETS_DOWNLOAD_URL="https://api.github.com/repos/$GITHUB_REPO/releases/assets/$ASSET_ID"
    print_info "通过 assets API 下载 JAR 文件..."
    local DOWNLOAD_ERROR=false

    if command -v wget &>/dev/null; then
        wget --header="Authorization: token $GITHUB_TOKEN" \
             --header="Accept: application/octet-stream" \
             -O "/opt/sui-agent/$JAR_NAME" "$ASSETS_DOWNLOAD_URL" || DOWNLOAD_ERROR=true
    else
        curl -L -H "Authorization: token $GITHUB_TOKEN" \
             -H "Accept: application/octet-stream" \
             -o "/opt/sui-agent/$JAR_NAME" "$ASSETS_DOWNLOAD_URL" || DOWNLOAD_ERROR=true
    fi

    # 如果 assets API 失败，尝试标准 URL
    if [ "$DOWNLOAD_ERROR" = true ] || [ ! -f "/opt/sui-agent/$JAR_NAME" ]; then
        print_warning "assets API 下载失败，尝试使用标准 Release URL..."
        local STANDARD_URL="https://github.com/$GITHUB_REPO/releases/download/$LATEST_VERSION/$JAR_NAME"
        DOWNLOAD_ERROR=false
        
        if command -v wget &>/dev/null; then
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

    # 验证文件大小
    local FILE_SIZE=$(stat -c%s "/opt/sui-agent/$JAR_NAME" 2>/dev/null || stat -f%z "/opt/sui-agent/$JAR_NAME" 2>/dev/null)
    if [ "$FILE_SIZE" -lt 1000000 ]; then
        print_error "文件大小异常: $FILE_SIZE 字节"
        exit 1
    fi

    # SHA256 校验
    if [ -n "$EXPECTED_SHA256" ]; then
        local LOCAL_SHA256=$(sha256sum "/opt/sui-agent/$JAR_NAME" | awk '{print $1}')
        if [ "$LOCAL_SHA256" != "$EXPECTED_SHA256" ]; then
            print_error "SHA256 校验失败！"
            print_error "期望: $EXPECTED_SHA256"
            print_error "实际: $LOCAL_SHA256"
            exit 1
        fi
        print_info "SHA256 校验通过 ✓"
    else
        print_warning "未获取到 digest 信息，跳过 SHA256 校验"
    fi

    print_info "文件下载完成 (大小: $(numfmt --to=iec $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes"))"
    chown suiagent:suiagent "/opt/sui-agent/$JAR_NAME"
}

# =========================
# 获取 JVM 参数
# =========================
get_jvm_opts() {
    local JVM_CONF="/opt/sui-agent/conf/jvm_opts"
    if [ -f "$JVM_CONF" ]; then
        cat "$JVM_CONF"
    else
        echo "-Xms64m -Xmx128m -XX:MaxMetaspaceSize=128m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=32m"
    fi
}

# =========================
# 创建 systemd 服务
# =========================
create_service() {
    print_info "创建 systemd 服务..."
    local JAR_FILE=$(ls /opt/sui-agent/*.jar 2>/dev/null | head -1)
    
    if [ -z "$JAR_FILE" ]; then
        print_error "未找到 JAR 文件"
        exit 1
    fi
    print_info "使用 JAR 文件: $JAR_FILE"
    
    local JVM_OPTS=$(get_jvm_opts)
    local SERVICE_FILE="/etc/systemd/system/sui-agent.service"

    cat > "$SERVICE_FILE" <<EOF
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
Environment=JAVA_OPTS=${JVM_OPTS}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sui-agent
    print_info "systemd 服务创建完成"
}

# =========================
# 启动服务
# =========================
start_service() {
    print_info "启动 SUI Agent 服务..."
    systemctl start sui-agent
    sleep 3
    
    if systemctl is-active --quiet sui-agent; then
        print_info "服务启动成功"
    else
        print_error "服务启动失败，请查看日志: journalctl -u sui-agent -n 50"
        exit 1
    fi
}

# =========================
# 创建 CLI 工具
# =========================
create_cli() {
    print_info "创建自定义命令 sui-a ..."
    
    cat > /usr/local/bin/sui-a <<'EOF'
#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

JVM_CONF="/opt/sui-agent/conf/jvm_opts"
SERVICE_FILE="/etc/systemd/system/sui-agent.service"
CONFIG_FILE="/opt/sui-agent/config/agent.json"

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
    
    local JAR_FILE=$(ls /opt/sui-agent/*.jar 2>/dev/null | head -1)
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

show_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "当前配置:"
        cat "$CONFIG_FILE" | jq '.' 2>/dev/null || cat "$CONFIG_FILE"
    else
        print_error "配置文件不存在: $CONFIG_FILE"
    fi
}

edit_config() {
    if [ -f "$CONFIG_FILE" ]; then
        ${EDITOR:-vi} "$CONFIG_FILE"
        print_info "配置文件已修改，需要重启服务生效"
        read -p "是否立即重启 SUI Agent 服务？(y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            systemctl restart sui-agent
            print_info "服务已重启"
        fi
    else
        print_error "配置文件不存在: $CONFIG_FILE"
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
    config)
        case "$2" in
            show|"")
                show_config
                ;;
            edit)
                edit_config
                ;;
            *)
                echo "用法: sui-a config {show|edit}"
                ;;
        esac
        ;;
    *)
        echo "用法: sui-a {start|stop|restart|status|logs|jvm|config}"
        echo ""
        echo "  start           - 启动服务"
        echo "  stop            - 停止服务"
        echo "  restart         - 重启服务"
        echo "  status          - 查看服务状态"
        echo "  logs            - 查看实时日志"
        echo ""
        echo "  jvm             - 交互式修改 JVM 参数"
        echo "  jvm show        - 显示当前 JVM 参数"
        echo "  jvm set \"...\"   - 设置新的 JVM 参数"
        echo ""
        echo "  config show     - 显示当前配置"
        echo "  config edit     - 编辑配置文件"
        echo ""
        echo "示例:"
        echo "  sui-a jvm set \"-Xms128m -Xmx256m -XX:MaxMetaspaceSize=128m\""
        echo "  sui-a config edit"
        exit 1
        ;;
esac
EOF

    chmod +x /usr/local/bin/sui-a
    print_info "自定义命令创建完成"
}

# =========================
# 显示完成信息
# =========================
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
    echo "  sui-a jvm set     # 直接设置 JVM 参数"
    echo "  sui-a config show # 显示配置"
    echo "  sui-a config edit # 编辑配置"
    echo ""
    echo "或者使用 systemctl："
    echo "  systemctl start|stop|restart|status sui-agent"
    echo "  journalctl -u sui-agent -f"
    echo ""
    echo "配置文件位置: /opt/sui-agent/config/agent.json"
    echo "日志文件位置: /opt/sui-agent/logs/"
    echo "数据目录位置: /opt/sui-agent/data/"
    echo "JVM 配置文件: /opt/sui-agent/conf/jvm_opts"
    echo ""
}

# =========================
# 主函数
# =========================
main() {
    print_info "开始安装 SUI Agent..."
    check_root
    detect_os
    install_base
    install_java
    setup_user_and_dir
    download_jar
    setup_json_config
    create_service
    create_cli
    start_service
    show_complete
    print_info "安装完成！"
}

main "$@"
