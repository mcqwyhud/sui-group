#!/bin/bash
# ==============================
# SUI + SUI-Agent 一键安装脚本
# ==============================

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log(){ echo -e "${GREEN}[INFO]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn(){ echo -e "${YELLOW}[WARNING]${NC} $1"; }

# ------------------------------
# 检测系统
# ------------------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        OS="unknown"
    fi
    log "检测到系统: $OS"
}

# ------------------------------
# 生成 Java 风格 UUID（标准格式带横线）
# ------------------------------
gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        # 手动生成标准 UUID 格式
        local uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
        if [ -n "$uuid" ]; then
            echo "$uuid"
        else
            # 备用方案：生成随机 UUID
            printf "%08x-%04x-%04x-%04x-%012x\n" \
                $((RANDOM*65536 + RANDOM)) \
                $((RANDOM*65536 + RANDOM)) \
                $(( (RANDOM*65536 + RANDOM) & 0x0FFF | 0x4000 )) \
                $(( (RANDOM*65536 + RANDOM) & 0x3FFF | 0x8000 )) \
                $((RANDOM*65536*65536 + RANDOM*65536 + RANDOM))
        fi
    fi
}

# ------------------------------
# 生成随机字符串
# ------------------------------
gen_random() {
    local len=${1:-32}
    head -c "$len" /dev/urandom | base64 | tr -d "=+/" | head -c "$len"
}

# ------------------------------
# 交互式输入函数
# ------------------------------
ask() {
    local prompt="$1"
    local default="$2"
    local input=""
    
    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " input
        echo "${input:-$default}"
    else
        read -p "$prompt: " input
        echo "$input"
    fi
}

# ------------------------------
# 1. 基础依赖
# ------------------------------
install_base() {
    log "安装基础依赖..."
    
    detect_os
    
    case "$OS" in
        ubuntu|debian)
            apt update -y
            apt install -y curl wget jq sqlite3 uuid-runtime
            ;;
        centos|rhel|almalinux|rocky|fedora)
            yum install -y curl wget jq sqlite util-linux
            ;;
        *)
            warn "未知系统，尝试使用 yum 安装"
            yum install -y curl wget jq sqlite 2>/dev/null || {
                err "无法安装依赖，请手动安装: curl wget jq sqlite"
            }
            ;;
    esac
    
    log "基础依赖安装完成"
}

# ------------------------------
# 2. 交互式配置 Agent（在 s-ui 安装前）
# ------------------------------
pre_configure_agent() {
    log "开始交互式配置 Agent..."
    
    # 创建 Agent 目录
    mkdir -p /opt/sui-agent/{config,logs,data,conf}
    
    # 创建 suiagent 用户（如果不存在）
    if ! id -u suiagent &>/dev/null; then
        useradd -r -s /bin/false suiagent
        log "用户 suiagent 创建成功"
    fi
    
    echo ""
    log "请输入 Agent 配置信息（直接回车使用默认值）"
    echo "=========================================="
    
    # ==========================================
    # 生成 PID (Java 风格 UUID)
    # ==========================================
    PID=$(gen_uuid)
    log "自动生成 PID: $PID"
    
    # ==========================================
    # 1. 生成 suiApi2Key - 用于调用 s-ui API
    # ==========================================
    SUI_API_KEY=$(gen_random 32)
    
    # ==========================================
    # 2. 生成 brokerKey - 用于 agent 之间通信
    # ==========================================
    BROKER_KEY=$(gen_random 32)
    
    # 保存两个 key 供后续使用
    echo "$SUI_API_KEY" > /tmp/sui_api_key
    echo "$BROKER_KEY" > /tmp/broker_key
    chmod 600 /tmp/sui_api_key /tmp/broker_key
    
    log "生成 suiApi2Key: ${SUI_API_KEY:0:16}..."
    log "生成 brokerKey: ${BROKER_KEY:0:16}..."
    echo ""
    
    # ==========================================
    # 3. 交互式配置所有参数
    # ==========================================
    
    # broker 配置
    BROKER_HOST=$(ask "brokerHost (agent 监听地址)" "localhost")
    BROKER_PORT=$(ask "brokerPort (agent 监听端口)" "10200")
    
    # s-ui 配置
    SUI_SUB_URL=$(ask "suiSubUrl (s-ui 订阅地址)" "http://localhost:2096/sub/")
    SUI_API2_URL=$(ask "suiApi2Url (s-ui API 地址)" "http://localhost:2095")
    SUI_API2_PATH=$(ask "suiApi2Path (s-ui API 路径)" "/app/apiv2")
    
    # Agent 信息
    AGENT_NAME=$(ask "agentName (节点名称)" "子节点逻辑服1")
    AGENT_TAG=$(ask "agentTag (节点标签)" "子节点逻辑服")
    REPORT_VPS_TIME=$(ask "reportVpsTime (上报间隔，毫秒)" "600000")
    
    # 自动创建入站配置
    AUTO_CREATE_INBOUND=$(ask "auto_create_inbound (自动创建入站 true/false)" "false")
    AUTO_VPS_ID=$(ask "auto_vpsId (VPS ID)" "美国1")
    AUTO_UP_MBPS=$(ask "auto_up_mbps (上行限速 Mbps，0 不限)" "0")
    AUTO_DOWN_MBPS=$(ask "auto_down_mbps (下行限速 Mbps，0 不限)" "0")
    
    echo ""
    log "配置信息确认:"
    echo "=========================================="
    echo "  PID:                    $PID"
    echo "  brokerKey:              ${BROKER_KEY:0:16}..."
    echo "  brokerHost:             $BROKER_HOST"
    echo "  brokerPort:             $BROKER_PORT"
    echo "  suiApi2Key:             ${SUI_API_KEY:0:16}..."
    echo "  suiSubUrl:              $SUI_SUB_URL"
    echo "  suiApi2Url:             $SUI_API2_URL"
    echo "  suiApi2Path:            $SUI_API2_PATH"
    echo "  agentName:              $AGENT_NAME"
    echo "  agentTag:               $AGENT_TAG"
    echo "  reportVpsTime:          $REPORT_VPS_TIME"
    echo "  auto_create_inbound:    $AUTO_CREATE_INBOUND"
    echo "  auto_vpsId:             $AUTO_VPS_ID"
    echo "  auto_up_mbps:           $AUTO_UP_MBPS"
    echo "  auto_down_mbps:         $AUTO_DOWN_MBPS"
    echo "=========================================="
    
    local confirm=$(ask "确认以上配置？(y/n)" "y")
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "请重新运行脚本配置"
        exit 0
    fi

    # 创建 agent.json 配置文件
    local CONFIG_FILE="/opt/sui-agent/config/agent.json"
    
    cat > "$CONFIG_FILE" <<EOF
{
  "brokerKey": "$BROKER_KEY",
  "brokerHost": "$BROKER_HOST",
  "brokerPort": $BROKER_PORT,
  "pid": "$PID",
  "agentName": "$AGENT_NAME",
  "agentTag": "$AGENT_TAG",
  "reportVpsTime": $REPORT_VPS_TIME,
  "suiSubUrl": "$SUI_SUB_URL",
  "suiApi2Key": "$SUI_API_KEY",
  "suiApi2Url": "$SUI_API2_URL",
  "suiApi2Path": "$SUI_API2_PATH",
  "auto_create_inbound": $AUTO_CREATE_INBOUND,
  "auto_vpsId": "$AUTO_VPS_ID",
  "auto_up_mbps": $AUTO_UP_MBPS,
  "auto_down_mbps": $AUTO_DOWN_MBPS
}
EOF

    chown -R suiagent:suiagent /opt/sui-agent
    chmod 644 "$CONFIG_FILE"
    
    log "✅ Agent 配置文件已创建: $CONFIG_FILE"
    echo ""
    log "📌 两个 Key 的作用:"
    log "  - suiApi2Key: 用于 agent 调用 s-ui API (将写入 s-ui 数据库)"
    log "  - brokerKey:  用于 agent 集群内部通信 (仅 agent 使用)"
}

# ------------------------------
# 3. 安装 s-ui（官方）
# ------------------------------
install_sui() {
    log "安装 s-ui..."

    # 检查是否已安装
    if systemctl status s-ui &>/dev/null; then
        warn "s-ui 已安装，跳过"
        return 0
    fi

    # 下载并执行官方安装脚本
    if ! curl -sSL https://raw.githubusercontent.com/admin8800/s-ui/master/install.sh | bash; then
        err "s-ui 安装失败"
    fi

    sleep 3
    
    log "s-ui 安装完成"
}

# ------------------------------
# 4. 配置 s-ui 数据库（注入 suiApi2Key）
# ------------------------------
configure_sui_db() {
    log "配置 s-ui 数据库 - 注入 suiApi2Key..."

    # 查找数据库
    local DB_PATH=$(find_sui_db)
    if [ -z "$DB_PATH" ]; then
        err "未找到 s-ui 数据库"
    fi
    
    log "使用数据库: $DB_PATH"

    # 检查 suiApi2Key
    if [ ! -f /tmp/sui_api_key ]; then
        err "suiApi2Key 文件不存在"
    fi
    
    local SUI_API_KEY=$(cat /tmp/sui_api_key)
    
    # 检查 users 表，获取或创建用户
    local USER_ID=$(sqlite3 "$DB_PATH" "SELECT id FROM users LIMIT 1;" 2>/dev/null)
    
    if [ -z "$USER_ID" ]; then
        log "创建默认用户..."
        sqlite3 "$DB_PATH" <<EOF
INSERT INTO users (username, password, email, enable)
VALUES ('admin', 'admin123', 'admin@localhost', 1);
EOF
        USER_ID=$(sqlite3 "$DB_PATH" "SELECT id FROM users LIMIT 1;" 2>/dev/null)
        log "用户创建完成，ID: $USER_ID"
    fi
    
    log "使用 user_id: $USER_ID"

    # 检查 tokens 表是否存在
    local table_exists=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='tokens';" 2>/dev/null)
    
    if [ -z "$table_exists" ]; then
        log "创建 tokens 表..."
        sqlite3 "$DB_PATH" <<EOF
CREATE TABLE IF NOT EXISTS tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    desc TEXT,
    token TEXT,
    expiry INTEGER,
    user_id INTEGER
);
EOF
    fi

    # 将 suiApi2Key 写入 s-ui 数据库
    sqlite3 "$DB_PATH" <<EOF
INSERT OR REPLACE INTO tokens (desc, token, expiry, user_id)
VALUES ('sui-agent-api', '$SUI_API_KEY', 0, $USER_ID);
EOF

    if [ $? -eq 0 ]; then
        log "✅ suiApi2Key 已写入 s-ui 数据库"
    else
        err "suiApi2Key 写入数据库失败"
    fi

    log "suiApi2Key 配置完成"
}

# ------------------------------
# 5. 查找 s-ui 数据库路径
# ------------------------------
find_sui_db() {
    local db_paths=(
        "/usr/local/s-ui/db/s-ui.db"
        "/usr/local/s-ui.db"
        "/etc/s-ui/db/s-ui.db"
        "/opt/s-ui/db/s-ui.db"
    )
    
    for db in "${db_paths[@]}"; do
        if [ -f "$db" ]; then
            echo "$db"
            return 0
        fi
    done
    
    # 尝试 find 查找
    local found=$(find / -name "s-ui.db" -type f 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    
    return 1
}

# ------------------------------
# 6. 开启 BBR
# ------------------------------
enable_bbr() {
    log "检查并开启 BBR 加速..."

    local current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    log "当前 TCP 拥塞控制算法: $current_congestion"

    if [ "$current_congestion" = "bbr" ]; then
        log "BBR 已启用，跳过"
        return 0
    fi

    if ! modprobe tcp_bbr 2>/dev/null; then
        warn "当前内核不支持 BBR"
        return 1
    fi

    log "通过 s-ui 交互命令开启 BBR..."
    echo -e "18\n1" | s-ui || {
        warn "通过 s-ui 开启 BBR 失败，尝试直接配置 sysctl"
        enable_bbr_sysctl
    }

    sleep 2
    local new_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$new_congestion" = "bbr" ]; then
        log "✅ BBR 已成功启用"
    else
        warn "BBR 可能未成功启用，当前算法: $new_congestion"
        enable_bbr_sysctl
    fi
}

# ------------------------------
# 6.1 备用方案：直接配置 sysctl
# ------------------------------
enable_bbr_sysctl() {
    log "通过 sysctl 配置 BBR..."

    if ! modprobe tcp_bbr 2>/dev/null; then
        warn "内核不支持 BBR"
        return 1
    fi

    cat >> /etc/sysctl.conf <<EOF

# BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p /etc/sysctl.conf || {
        warn "应用 sysctl 配置失败"
        return 1
    }

    local new_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$new_congestion" = "bbr" ]; then
        log "✅ BBR 已通过 sysctl 启用"
    else
        warn "BBR 启用失败"
        return 1
    fi
}

# ------------------------------
# 6.2 检查 BBR 状态
# ------------------------------
check_bbr_status() {
    local congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    
    if [ "$congestion" = "bbr" ]; then
        echo "✅ BBR: 已启用 (算法: $congestion, qdisc: $qdisc)"
    else
        echo "❌ BBR: 未启用 (当前算法: $congestion)"
    fi
}

# ------------------------------
# 7. 启动 s-ui
# ------------------------------
start_sui() {
    log "启动 s-ui 服务..."
    
    systemctl enable s-ui --now || {
        err "s-ui 启动失败"
    }
    
    log "s-ui 已启动"
}

# ------------------------------
# 8. 等待 s-ui API 就绪
# ------------------------------
wait_sui() {
    log "等待 s-ui API 就绪..."

    # 从配置中读取 api url
    local SUI_API2_URL=$(jq -r '.suiApi2Url' /opt/sui-agent/config/agent.json 2>/dev/null || echo "http://localhost:2095")
    
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s "${SUI_API2_URL}" >/dev/null 2>&1; then
            log "s-ui API 已就绪: $SUI_API2_URL"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log "等待中... ($attempt/$max_attempts)"
        sleep 2
    done

    err "s-ui 启动超时，请检查服务状态: systemctl status s-ui"
}

# ------------------------------
# 9. 安装 sui-agent
# ------------------------------
install_agent() {
    log "安装 sui-agent..."

    # 下载 agent 安装脚本
    local AGENT_SCRIPT="/tmp/agent_install.sh"
    
    log "下载 agent 安装脚本..."
    if ! curl -sSL https://raw.githubusercontent.com/mcqwyhud/sui-group/main/agent_linux_install_v1.0.sh -o "$AGENT_SCRIPT"; then
        warn "从主仓库下载失败，尝试备用地址..."
        if ! curl -sSL https://raw.githubusercontent.com/mcqwyhud/sui-agent/main/install.sh -o "$AGENT_SCRIPT" 2>/dev/null; then
            err "无法下载 agent 安装脚本"
        fi
    fi
    
    chmod +x "$AGENT_SCRIPT"

    # 执行 agent 安装
    log "执行 agent 安装..."
    bash "$AGENT_SCRIPT"
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log "Agent 安装成功"
    else
        warn "Agent 安装可能失败，退出码: $exit_code"
    fi
}

# ------------------------------
# 10. 验证安装
# ------------------------------
verify_installation() {
    log "验证安装..."
    
    # 检查 s-ui
    if systemctl is-active --quiet s-ui; then
        log "✅ s-ui 运行正常"
    else
        warn "⚠️ s-ui 未运行"
    fi
    
    # 检查 agent
    if systemctl is-active --quiet sui-agent; then
        log "✅ sui-agent 运行正常"
    else
        warn "⚠️ sui-agent 未运行"
    fi
    
    # 检查 BBR
    log "BBR 状态: $(check_bbr_status)"
    
    # 显示端口监听
    log "端口监听状态:"
    ss -tlnp | grep -E ":(2095|2096|10200)" 2>/dev/null || {
        netstat -tlnp 2>/dev/null | grep -E ":(2095|2096|10200)" || echo "  无法查看端口状态"
    }
}

# ------------------------------
# 11. 显示完成信息
# ------------------------------
show_complete() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}SUI + Agent 安装完成！${NC}"
    echo "=========================================="
    echo ""
    echo "📋 服务信息:"
    echo "  - s-ui 端口: 2095 (API) / 2096 (Web)"
    echo "  - agent 端口: 10200 (Broker)"
    echo "  - BBR 状态: $(check_bbr_status)"
    echo ""
    echo "🔑 密钥信息:"
    echo "  - suiApi2Key: $(cat /tmp/sui_api_key 2>/dev/null || echo '未生成')"
    echo "  - brokerKey:  $(cat /tmp/broker_key 2>/dev/null || echo '未生成')"
    echo "  - PID:        $(jq -r '.pid' /opt/sui-agent/config/agent.json 2>/dev/null || echo '未生成')"
    echo ""
    echo "📂 配置文件:"
    echo "  - Agent 配置: /opt/sui-agent/config/agent.json"
    echo "  - s-ui 数据库: $(find_sui_db 2>/dev/null || echo '未找到')"
    echo ""
    echo "🛠️ 管理命令:"
    echo "  - s-ui:   systemctl {start|stop|restart|status} s-ui"
    echo "  - agent:  sui-a {start|stop|restart|status|logs}"
    echo ""
    echo "📊 查看日志:"
    echo "  - s-ui:   journalctl -u s-ui -f"
    echo "  - agent:  sui-a logs"
    echo ""
    echo "🌐 访问面板:"
    echo "  http://$(hostname -I | awk '{print $1}'):2096"
    echo "  (默认账号: admin / admin123)"
    echo ""
    echo "=========================================="
}

# ------------------------------
# 12. 清理临时文件
# ------------------------------
cleanup() {
    log "清理临时文件..."
    rm -f /tmp/agent_install.sh /tmp/agent_token 2>/dev/null
}

# ------------------------------
# 13. 主流程
# ------------------------------
main() {
    log "开始安装 SUI + SUI-Agent..."
    echo "=========================================="
    
    # 检查 root
    if [ "$EUID" -ne 0 ]; then
        err "请使用 root 用户运行此脚本"
    fi
    
    # 执行安装步骤
    install_base          # 1. 安装基础依赖
    pre_configure_agent   # 2. ⭐ 交互式配置 Agent（生成两个 Key）
    install_sui          # 3. 安装 s-ui
    configure_sui_db     # 4. ⭐ 将 suiApi2Key 写入 s-ui 数据库
    enable_bbr           # 5. 开启 BBR
    start_sui            # 6. 启动 s-ui
    wait_sui             # 7. 等待 API 就绪
    install_agent        # 8. 安装 Agent（使用已生成的配置）
    verify_installation  # 9. 验证
    show_complete        # 10. 显示完成信息
    cleanup              # 11. 清理
    
    log "安装流程完成！"
}

# 捕获错误
trap 'err "安装过程中发生错误，请检查日志"' ERR

# 执行主函数
main
