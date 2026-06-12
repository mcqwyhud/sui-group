#!/bin/bash
# SUI Agent 一键安装脚本（完整版 + JSON交互配置增强版）
# 支持 Linux + GitHub Release + systemd + JVM 管理 + JSON交互初始化

set -e

# =========================
# 颜色
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
        print_error "请使用 root 运行"
        exit 1
    fi
}

# =========================
# OS检测
# =========================
detect_os() {
    . /etc/os-release
    OS=$ID
    print_info "系统: $OS"
}

# =========================
# 基础工具
# =========================
install_base() {
    print_info "检查基础工具..."
    local tools=("wget" "curl" "tar" "tzdata" "jq")
    local missing=()

    for t in "${tools[@]}"; do
        if ! command -v "$t" &>/dev/null; then
            [ "$t" != "tzdata" ] && missing+=("$t")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        return
    fi

    print_info "安装: ${missing[*]}"

    case "$OS" in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq "${missing[@]}"
            ;;
        centos|rhel|almalinux|rocky)
            yum install -y -q "${missing[@]}"
            ;;
        fedora)
            dnf install -y -q "${missing[@]}"
            ;;
    esac
}

# =========================
# Java
# =========================
install_java() {
    if command -v java &>/dev/null; then
        return
    fi

    print_info "安装 Java 21..."

    case "$OS" in
        ubuntu|debian)
            apt-get install -y openjdk-21-jre-headless
            ;;
        centos|rhel|almalinux|rocky|fedora)
            dnf install -y java-21-openjdk-headless || yum install -y java-21-openjdk-headless
            ;;
    esac
}

# =========================
# 用户目录
# =========================
setup_user_and_dir() {
    id suiagent &>/dev/null || useradd -r -s /bin/false suiagent

    mkdir -p /opt/sui-agent/{config,logs,data,conf}
    chown -R suiagent:suiagent /opt/sui-agent

    JVM_CONF="/opt/sui-agent/conf/jvm_opts"
    [ ! -f "$JVM_CONF" ] && echo "-Xms64m -Xmx128m" > "$JVM_CONF"
}

# =========================
# 下载jar（保持原逻辑）
# =========================
download_jar() {
    print_info "下载 JAR..."
    # 这里保持你原逻辑（略简，但结构不变）
    GITHUB_REPO="mcqwyhud/sui-agent"
    RELEASE_URL="https://api.github.com/repos/$GITHUB_REPO/releases/latest"

    API=$(curl -s "$RELEASE_URL")
    JAR_NAME=$(echo "$API" | jq -r '.assets[]|select(.name|endswith(".jar"))|.name' | head -1)

    wget -O "/opt/sui-agent/$JAR_NAME" "https://github.com/$GITHUB_REPO/releases/latest/download/$JAR_NAME"

    chown suiagent:suiagent "/opt/sui-agent/$JAR_NAME"
}

# =========================
# JSON配置（核心新增）
# =========================

CONFIG_FILE="/opt/sui-agent/config/external.json"

uuid_gen() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

ask() {
    local key="$1"
    local def="$2"
    local cur="$3"

    if [ -n "$cur" ]; then
        read -p "$key [$cur]: " val
        echo "${val:-$cur}"
    else
        read -p "$key [$def]: " val
        echo "${val:-$def}"
    fi
}

setup_json_config() {

    print_info "初始化 JSON 配置..."

    mkdir -p /opt/sui-agent/config

    # 默认值
    brokerKey_def="TuAyStnLhnVX9l215cgciVWFDhs2CrrehFZTEgJVtrM="
    brokerHost_def="127.0.0.1"
    brokerPort_def="10200"
    suiSubUrl_def="http://127.0.0.1:2096/sub/"
    suiApi2Key_def="cwCZa6Aq6lmKXjt3QeotgywhiDzXpb8U"
    suiApi2Url_def="http://127.0.0.1:2095"
    suiApi2Path_def="/app/apiv2"

    agentName_def="子节点逻辑服1"
    agentTag_def="子节点逻辑服"
    reportVpsTime_def="600000"

    auto_create_inbound_def="false"
    auto_vpsId_def="美国1"
    auto_up_mbps_def="0"
    auto_down_mbps_def="0"

    # 如果存在就读取
    if [ -f "$CONFIG_FILE" ]; then
        print_warning "检测到已有配置，将进入编辑模式"
        old=$(cat "$CONFIG_FILE")

        brokerKey=$(echo "$old" | jq -r '.brokerKey')
        brokerHost=$(echo "$old" | jq -r '.brokerHost')
        brokerPort=$(echo "$old" | jq -r '.brokerPort')

        suiSubUrl=$(echo "$old" | jq -r '.suiSubUrl')
        suiApi2Key=$(echo "$old" | jq -r '.suiApi2Key')
        suiApi2Url=$(echo "$old" | jq -r '.suiApi2Url')
        suiApi2Path=$(echo "$old" | jq -r '.suiApi2Path')

        agentName=$(echo "$old" | jq -r '.agentName')
        agentTag=$(echo "$old" | jq -r '.agentTag')
        reportVpsTime=$(echo "$old" | jq -r '.reportVpsTime')

        pid=$(echo "$old" | jq -r '.pid')

        auto_create_inbound=$(echo "$old" | jq -r '.auto_create_inbound')
        auto_vpsId=$(echo "$old" | jq -r '.auto_vpsId')
        auto_up_mbps=$(echo "$old" | jq -r '.auto_up_mbps')
        auto_down_mbps=$(echo "$old" | jq -r '.auto_down_mbps')

    else
        pid=$(uuid_gen)
    fi

    echo ""
    print_info "开始交互式配置（直接回车使用默认值）"
    echo ""

    brokerKey=$(ask "brokerKey" "$brokerKey_def" "$brokerKey")
    brokerHost=$(ask "brokerHost" "$brokerHost_def" "$brokerHost")
    brokerPort=$(ask "brokerPort" "$brokerPort_def" "$brokerPort")

    suiSubUrl=$(ask "suiSubUrl" "$suiSubUrl_def" "$suiSubUrl")
    suiApi2Key=$(ask "suiApi2Key" "$suiApi2Key_def" "$suiApi2Key")
    suiApi2Url=$(ask "suiApi2Url" "$suiApi2Url_def" "$suiApi2Url")
    suiApi2Path=$(ask "suiApi2Path" "$suiApi2Path_def" "$suiApi2Path")

    agentName=$(ask "agentName" "$agentName_def" "$agentName")
    agentTag=$(ask "agentTag" "$agentTag_def" "$agentTag")
    reportVpsTime=$(ask "reportVpsTime" "$reportVpsTime_def" "$reportVpsTime")

    auto_create_inbound=$(ask "auto_create_inbound" "$auto_create_inbound_def" "$auto_create_inbound")
    auto_vpsId=$(ask "auto_vpsId" "$auto_vpsId_def" "$auto_vpsId")
    auto_up_mbps=$(ask "auto_up_mbps" "$auto_up_mbps_def" "$auto_up_mbps")
    auto_down_mbps=$(ask "auto_down_mbps" "$auto_down_mbps_def" "$auto_down_mbps")

    cat > "$CONFIG_FILE" <<EOF
{
  "brokerKey":"$brokerKey",
  "brokerHost":"$brokerHost",
  "brokerPort":$brokerPort,
  "pid":"$pid",
  "agentName":"$agentName",
  "agentTag":"$agentTag",
  "reportVpsTime":$reportVpsTime,
  "suiSubUrl":"$suiSubUrl",
  "suiApi2Key":"$suiApi2Key",
  "suiApi2Url":"$suiApi2Url",
  "suiApi2Path":"$suiApi2Path",
  "auto_create_inbound":$auto_create_inbound,
  "auto_vpsId":"$auto_vpsId",
  "auto_up_mbps":$auto_up_mbps,
  "auto_down_mbps":$auto_down_mbps
}
EOF

    chown suiagent:suiagent "$CONFIG_FILE"

    print_info "JSON 配置完成: $CONFIG_FILE"
}

# =========================
# systemd
# =========================
create_service() {

    JAR=$(ls /opt/sui-agent/*.jar | head -1)

    cat > /etc/systemd/system/sui-agent.service <<EOF
[Unit]
Description=SUI Agent
After=network.target

[Service]
Type=simple
User=suiagent
WorkingDirectory=/opt/sui-agent
ExecStart=/usr/bin/java \$(cat /opt/sui-agent/conf/jvm_opts) -jar $JAR
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sui-agent
}

# =========================
# 启动
# =========================
start_service() {
    systemctl start sui-agent
    sleep 2
    systemctl is-active --quiet sui-agent && print_info "启动成功"
}

# =========================
# CLI工具
# =========================
create_cli() {
    cat > /usr/local/bin/sui-a <<'EOF'
#!/bin/bash
case "$1" in
start) systemctl start sui-agent ;;
stop) systemctl stop sui-agent ;;
restart) systemctl restart sui-agent ;;
status) systemctl status sui-agent ;;
logs) journalctl -u sui-agent -f ;;
esac
EOF
    chmod +x /usr/local/bin/sui-a
}

# =========================
# main
# =========================
main() {
    check_root
    detect_os
    install_base
    install_java
    setup_user_and_dir
    download_jar
    setup_json_config     # ⭐ 核心新增
    create_service
    create_cli
    start_service

    echo ""
    print_info "安装完成"
}

main
