#!/bin/bash
# SUI External 一键安装脚本（完整版）
# 改进：交互式 external.json 配置，pid 保持原值，支持修改 JVM 参数

set -e

# -------------------------------
# 颜色定义
# -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# -------------------------------
# 检查 root 用户
# -------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# -------------------------------
# 检测操作系统
# -------------------------------
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

# -------------------------------
# 获取 CPU 架构
# -------------------------------
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

# -------------------------------
# 安装基础工具
# -------------------------------
install_base() {
    print_info "检查基础工具..."
    local tools=("wget" "curl" "tar" "tzdata" "jq")
    local missing_tools=()
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            [ "$tool" != "tzdata" ] && missing_tools+=("$tool")
        fi
    done
    [ ! -d "/usr/share/zoneinfo" ] && missing_tools+=("tzdata")

    if [ ${#missing_tools[@]} -eq 0 ]; then
        print_info "基础工具已安装"
        return 0
    fi

    print_info "需要安装: ${missing_tools[*]}"

    case "$OS" in
        ubuntu|debian) apt-get update -qq && apt-get install -y -qq "${missing_tools[@]}" ;;
        centos|almalinux|rocky|oracle|rhel) yum install -y -q "${missing_tools[@]}" ;;
        fedora) dnf install -y -q "${missing_tools[@]}" ;;
        arch|manjaro|parch) pacman -Syu --noconfirm --quiet "${missing_tools[@]}" ;;
        opensuse-tumbleweed) zypper -q install -y "${missing_tools[@]}" ;;
        *) print_error "不支持的操作系统: $OS"; exit 1 ;;
    esac

    print_info "基础工具安装完成"
}

# -------------------------------
# 安装 Java
# -------------------------------
install_java() {
    print_info "检查 Java..."
    if command -v java &> /dev/null; then
        JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d. -f1)
        if [ "$JAVA_VERSION" -ge 21 ]; then
            print_info "已安装 Java: $(java -version 2>&1 | head -1)"
            return
        fi
    fi

    print_info "安装 Java 21 (Oracle JDK)"
    cd /tmp
    wget -q https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.deb
    apt install -y ./jdk-21_linux-x64_bin.deb
    rm -f jdk-21_linux-x64_bin.deb

    command -v java &> /dev/null || { print_error "Java 安装失败"; exit 1; }
    print_info "Java 安装成功: $(java -version 2>&1 | head -1)"
}

# -------------------------------
# 创建用户和目录
# -------------------------------
setup_user_and_dir() {
    print_info "创建用户和目录"
    id -u suiexternal &> /dev/null || useradd -r -s /bin/false suiexternal
    mkdir -p /opt/sui-external/{config,logs,uploads,config/web/static,conf,jprotobuf-cache,tmp}
    chown -R suiexternal:suiexternal /opt/sui-external
    chmod 755 /opt/sui-external/logs /opt/sui-external/jprotobuf-cache /opt/sui-external/tmp /opt/sui-external/conf

    JVM_CONF="/opt/sui-external/conf/jvm_opts"
    if [ ! -f "$JVM_CONF" ]; then
        echo "-Xms64m -Xmx128m -XX:MaxMetaspaceSize=64m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=32m" > "$JVM_CONF"
        chown suiexternal:suiexternal "$JVM_CONF"
        print_info "默认 JVM 参数写入 $JVM_CONF"
    fi

    [ -d "/tmp/JPROTOBUF_CACHE_DIR" ] && rm -rf /tmp/JPROTOBUF_CACHE_DIR
}

# -------------------------------
# 生成 UUID
# -------------------------------
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen
    else
        # fallback: 用 date+sha256
        echo $(date +%s%N | sha256sum | cut -c1-32)
    fi
}

# -------------------------------
# 配置 external.json
# -------------------------------
configure_external_json() {
    CONFIG_FILE="/opt/sui-external/config/external.json"
    mkdir -p /opt/sui-external/config

    DEFAULT_NAME="游戏对逻辑外服1"
    DEFAULT_TAG="游戏对逻辑外服"
    DEFAULT_WEB_ENABLE=true
    DEFAULT_PORT=28688
    DEFAULT_BROKER_HOST="127.0.0.1"
    DEFAULT_BROKER_PORT=10200

    echo ""

    EXISTING_PID=""
    if [ -f "$CONFIG_FILE" ]; then
        EXISTING_PID=$(jq -r '.pid' "$CONFIG_FILE" 2>/dev/null || echo "")
        print_warning "检测到已存在 external.json"

        echo "请选择操作："
        echo "1) 使用现有配置"
        echo "2) 重新配置"
        read -p "请输入 [1-2]: " choice

        case "$choice" in
            1)
                print_info "使用现有 external.json"
                return
                ;;
            2)
                print_warning "进入重新配置模式..."
                ;;
            *)
                print_error "无效选择，默认使用现有配置"
                return
                ;;
        esac
    else
        print_warning "未检测到 external.json，进入初始化配置..."
    fi

    read -p "port [${DEFAULT_PORT}]: " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    read -p "brokerHost [${DEFAULT_BROKER_HOST}]: " BROKER_HOST
    BROKER_HOST=${BROKER_HOST:-$DEFAULT_BROKER_HOST}

    read -p "brokerPort [${DEFAULT_BROKER_PORT}]: " BROKER_PORT
    BROKER_PORT=${BROKER_PORT:-$DEFAULT_BROKER_PORT}

    read -p "brokerKey [自动生成]: " BROKER_KEY
    if [ -z "$BROKER_KEY" ]; then
        if command -v openssl &>/dev/null; then
            BROKER_KEY=$(openssl rand -base64 32)
        else
            BROKER_KEY=$(date +%s%N | sha256sum | base64 | head -c 44)
        fi
        print_info "已生成 brokerKey"
    fi

    PID=${EXISTING_PID:-$(generate_uuid)}

    cat > "$CONFIG_FILE" <<EOF
{
  "port" : $PORT,
  "brokerKey" : "$BROKER_KEY",
  "brokerHost" : "$BROKER_HOST",
  "brokerPort" : $BROKER_PORT,
  "pid" : "$PID",
  "name" : "$DEFAULT_NAME",
  "tag" : "$DEFAULT_TAG",
  "webEnable" : $DEFAULT_WEB_ENABLE
}
EOF

    chown suiexternal:suiexternal "$CONFIG_FILE"
    chmod 644 "$CONFIG_FILE"
    print_info "external.json 已保存: $CONFIG_FILE"
}

# -------------------------------
# 脚本主流程
# -------------------------------
main() {
    check_root
    detect_os
    install_base
    install_java
    setup_user_and_dir
    configure_external_json

    print_info "安装完成！"
}

main "$@"
