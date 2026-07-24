#!/bin/bash
# ==============================
# SUI + SUI-Agent 一键安装脚本 v2.0
# 支持两种模式：
#   1. 交互式：直接运行，会提示输入
#   2. 非交互式：通过环境变量传递配置
#
# 非交互式使用示例：
#   export BROKER_HOST="192.168.1.100"
#   export BROKER_PORT="10200"
#   export AGENT_NAME="子节点逻辑服-1"
#   export AUTO_CREATE_INBOUND="true"
#   export AUTO_VPS_ID="美国1"
#   export GITHUB_TOKEN="your_github_token"
#   ./suiAndAgent_linux_install_v2.0.sh
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
# 检测是否为非交互式模式
# ------------------------------
is_non_interactive() {
    [ -n "$BROKER_HOST" ] || [ -n "$BROKER_PORT" ] || [ -n "$AGENT_NAME" ] || [ -n "$AUTO_CREATE_INBOUND" ]
}

# ------------------------------
# 检测是否为交互式终端
# ------------------------------
is_interactive_shell() {
    if [ -t 0 ] && [ -t 1 ]; then
        return 0
    else
        return 1
    fi
}

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
        local uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
        if [ -n "$uuid" ]; then
            echo "$uuid"
        else
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
# 获取配置值（优先环境变量，否则交互式询问）
# ------------------------------
get_config() {
    local var_name="$1"
    local prompt="$2"
    local default="$3"
    local value
    
    eval "value=\${$var_name:-}"
    
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi
    
    # 如果是非交互式模式但没有设置环境变量，使用默认值
    if is_non_interactive; then
        if [ -n "$default" ]; then
            echo "$default"
            return 0
        else
            err "非交互式模式下，必须设置环境变量 $var_name"
        fi
    fi
    
    # 交互式询问
    ask "$prompt" "$default"
}

# 处理s-ui数据库模板下载（仅交互式使用）
handle_sui_db() {
    local DB_DIR="/usr/local/s-ui/db/"
    local DB_FILE="${DB_DIR}s-ui.db"
    
    if [ -z "$SUI_DB_URL" ]; then
        return 0
    fi
    
    log "检测到数据库模板链接，开始下载..."
    
    # 停止 s-ui 服务，避免文件锁
    if systemctl is-active --quiet s-ui; then
        log "停止 s-ui 服务以安全操作数据库..."
        systemctl stop s-ui
        sleep 1
    fi
    
    # 备份已有数据库
    if [ -f "$DB_FILE" ]; then
        local BACKUP_FILE="${DB_FILE}.bak.$(date +%s)"
        log "发现已有数据库，备份到 $BACKUP_FILE"
        cp "$DB_FILE" "$BACKUP_FILE"
    fi
    
    mkdir -p "$DB_DIR"
    log "正在下载数据库模板..."
    if curl -sSL --connect-timeout 30 --max-time 120 "$SUI_DB_URL" -o "$DB_FILE"; then
        if [ -s "$DB_FILE" ] && file "$DB_FILE" | grep -q "SQLite"; then
            chmod 644 "$DB_FILE"
            log "✅ 数据库下载成功并验证通过"
            return 0
        else
            rm -f "$DB_FILE"
            if [ -f "$BACKUP_FILE" ]; then
                mv "$BACKUP_FILE" "$DB_FILE"
                log "下载的文件无效，已恢复原有数据库"
            else
                log "下载的文件无效，已删除，将使用默认初始化"
            fi
            return 1
        fi
    else
        log "下载失败"
        if [ -f "$BACKUP_FILE" ]; then
            mv "$BACKUP_FILE" "$DB_FILE"
            log "下载失败，已恢复原有数据库"
        else
            log "下载失败，将使用默认初始化"
        fi
        return 1
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
# 2. 安装 s-ui（官方）
# ------------------------------
install_sui() {
    log "安装 s-ui..."

    if systemctl status s-ui &>/dev/null; then
        warn "s-ui 已安装，跳过"
        return 0
    fi

    if ! curl -sSL https://raw.githubusercontent.com/admin8800/s-ui/master/install.sh | bash; then
        err "s-ui 安装失败"
    fi

    sleep 3
    log "s-ui 安装完成"
}

# ------------------------------
# 3. 配置 Agent 和 s-ui
# ------------------------------
configure_agent_and_sui() {
    log "开始配置 Agent 和 s-ui..."
    
    mkdir -p /opt/sui-agent/{config,logs,data,conf}
    
    # 创建 suiagent 用户（静默）
    if ! id -u suiagent &>/dev/null; then
        useradd -r -s /bin/false suiagent
        log "用户 suiagent 创建成功"
    fi
    
    local is_non_interactive=$(is_non_interactive && echo "true" || echo "false")
    
    if [ "$is_non_interactive" = "false" ]; then
        echo ""
        log "请输入配置信息（直接回车使用默认值）"
        echo "=========================================="
        echo ""
    fi
    
    # ==========================================
    # 生成 PID
    # ==========================================
    PID=$(gen_uuid)
    log "自动生成 PID: $PID"
    
    # ==========================================
    # 生成或获取 suiApi2Key
    # ==========================================
    if [ -n "$SUI_API_KEY" ]; then
        SUI_API_KEY="$SUI_API_KEY"
        log "使用指定的 suiApi2Key: ${SUI_API_KEY:0:16}..."
    else
        SUI_API_KEY=$(gen_random 32)
        log "生成 suiApi2Key: ${SUI_API_KEY:0:16}..."
    fi
    
    # ==========================================
    # 生成或获取 brokerKey
    # ==========================================
    if [ -n "$BROKER_KEY" ]; then
        BROKER_KEY="$BROKER_KEY"
        log "使用指定的 brokerKey: ${BROKER_KEY:0:16}..."
    else
        BROKER_KEY=$(gen_random 32)
        log "生成 brokerKey: ${BROKER_KEY:0:16}..."
    fi
    
    echo "$SUI_API_KEY" > /tmp/sui_api_key
    echo "$BROKER_KEY" > /tmp/broker_key
    chmod 600 /tmp/sui_api_key /tmp/broker_key
    
    echo ""
    
    # ==========================================
    # 获取所有配置
    # ==========================================
    BROKER_HOST=$(get_config "BROKER_HOST" "brokerHost (集群网关地址)" "127.0.0.1")
    BROKER_PORT=$(get_config "BROKER_PORT" "brokerPort (集群网关端口)" "10200")
    SUI_SUB_URL=$(get_config "SUI_SUB_URL" "suiSubUrl (s-ui 订阅地址)" "http://127.0.0.1:2096/sub/")
    SUI_API2_URL=$(get_config "SUI_API2_URL" "suiApi2Url (s-ui API 地址)" "http://127.0.0.1:2095")
    SUI_API2_PATH=$(get_config "SUI_API2_PATH" "suiApi2Path (s-ui API 路径)" "/app/apiv2")
    AGENT_NAME=$(get_config "AGENT_NAME" "agentName (节点名称)" "子节点逻辑服1")
    AGENT_TAG=$(get_config "AGENT_TAG" "agentTag (节点标签)" "子节点逻辑服")
    REPORT_VPS_TIME=$(get_config "REPORT_VPS_TIME" "reportVpsTime (上报间隔，毫秒)" "600000")
    AUTO_CREATE_INBOUND=$(get_config "AUTO_CREATE_INBOUND" "auto_create_inbound (自动创建入站 true/false)" "false")
    AUTO_VPS_ID=$(get_config "AUTO_VPS_ID" "auto_vpsId (VPS ID)" "美国1")

    # ====== 新增：交互式询问数据库模板链接（仅交互式） ======
    SUI_DB_URL=""
    if [ "$is_non_interactive" = "false" ]; then
        SUI_DB_URL=$(ask "数据库模板链接（留空跳过）" "")
    fi
    # ====== 新增结束 ======
    
    # 如果是交互式模式，显示确认信息
    if [ "$is_non_interactive" = "false" ]; then
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
        echo "  auto_vpsId:             $AUTO_VPS_ID"
        # ====== 新增：显示数据库模板链接（如有） ======
        if [ -n "$SUI_DB_URL" ]; then
            echo "  数据库模板:             $SUI_DB_URL"
        else
            echo "  数据库模板:             未设置"
        fi
        # ====== 新增结束 ======
        echo "=========================================="
        
        local confirm=$(ask "确认以上配置？(y/n)" "y")
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log "请重新运行脚本配置"
            exit 0
        fi
    else
        log "非交互式模式，使用以下配置:"
        echo "  BROKER_HOST:            $BROKER_HOST"
        echo "  BROKER_PORT:            $BROKER_PORT"
        echo "  AGENT_NAME:             $AGENT_NAME"
        echo "  AUTO_CREATE_INBOUND:    $AUTO_CREATE_INBOUND"
        echo "  AUTO_VPS_ID:            $AUTO_VPS_ID"
    fi

    # ==========================================
    # 创建 agent.json
    # ==========================================
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
  "suiCheckInterval": 10000,
  "auto_create_inbound": true,
  "auto_vpsId": "$AUTO_VPS_ID"
}
EOF

    chown -R suiagent:suiagent /opt/sui-agent
    chmod 644 "$CONFIG_FILE"
    
    log "✅ Agent 配置文件已创建: $CONFIG_FILE"

    # ====== 新增：如果提供了数据库模板链接，则下载 ======
    if [ -n "$SUI_DB_URL" ]; then
        handle_sui_db
    fi
    # ====== 新增结束 ======
    
    # ==========================================
    # 配置 s-ui 数据库
    # ==========================================
    log "配置 s-ui 数据库..."

    local DB_PATH=$(find_sui_db)
    if [ -z "$DB_PATH" ]; then
        err "未找到 s-ui 数据库"
    fi
    
    log "使用数据库: $DB_PATH"

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

    sqlite3 "$DB_PATH" <<EOF
INSERT OR REPLACE INTO tokens (desc, token, expiry, user_id)
VALUES ('sui-agent-api', '$SUI_API_KEY', 0, $USER_ID);
EOF

    if [ $? -eq 0 ]; then
        log "✅ suiApi2Key 已写入 s-ui 数据库"
    else
        err "suiApi2Key 写入数据库失败"
    fi
    
    # ==========================================
    # 重启 s-ui
    # ==========================================
    log "重启 s-ui..."
    
    if systemctl is-active --quiet s-ui; then
        systemctl restart s-ui
        if [ $? -eq 0 ]; then
            log "✅ s-ui 重启成功"
        else
            warn "s-ui 重启失败"
        fi
    else
        systemctl start s-ui
        if [ $? -eq 0 ]; then
            log "✅ s-ui 启动成功"
        else
            warn "s-ui 启动失败"
        fi
    fi
    
    log "✅ 所有配置已完成"
}

# ------------------------------
# 4. 查找 s-ui 数据库路径
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
    
    local found=$(find / -name "s-ui.db" -type f 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi
    
    return 1
}

# ------------------------------
# 5. 开启 BBR
# ------------------------------
enable_bbr() {
    log "检查并开启 BBR..."

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

    log "通过 sysctl 配置 BBR..."
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
        log "✅ BBR 已成功启用"
    else
        warn "BBR 启用失败，当前算法: $new_congestion"
        return 1
    fi
}

# ------------------------------
# 6. 等待 s-ui API 就绪
# ------------------------------
wait_sui() {
    log "等待 s-ui API 就绪..."

    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://127.0.0.1:2095 >/dev/null 2>&1; then
            log "s-ui API 已就绪"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log "等待中... ($attempt/$max_attempts)"
        sleep 2
    done

    err "s-ui 启动超时，请检查服务状态: systemctl status s-ui"
}

# ------------------------------
# 7. 安装 sui-agent（支持交互式/非交互式）
# ------------------------------
install_agent() {
    log "安装 sui-agent..."

    # ==========================================
    # 1. 获取 GitHub Token（交互式或环境变量）
    # ==========================================
    if [ -z "$GITHUB_TOKEN" ]; then
        # 检测是否为交互式环境且不是非交互式模式
        if is_interactive_shell && ! is_non_interactive; then
            echo ""
            log "检测到交互式环境，请输入 GitHub Token"
            echo "（私有仓库需要 Token，公开仓库可以跳过）"
            read -p "GitHub Token (按回车跳过): " input_token
            if [ -n "$input_token" ]; then
                GITHUB_TOKEN="$input_token"
                export GITHUB_TOKEN="$input_token"
                log "✅ Token 已设置"
            else
                warn "未输入 Token，将尝试公开下载"
            fi
        else
            warn "非交互式环境，GITHUB_TOKEN 未设置"
            warn "将尝试公开下载，如果失败请设置环境变量 GITHUB_TOKEN"
        fi
    else
        log "✅ 使用环境变量中的 GITHUB_TOKEN"
    fi

    # ==========================================
    # 2. 下载 Agent 安装脚本
    # ==========================================
    local AGENT_SCRIPT="/tmp/agent_install.sh"
    log "下载 agent 安装脚本..."
    
    if [ -n "$GITHUB_TOKEN" ]; then
        log "使用 GitHub Token 下载..."
        curl -sSL -H "Authorization: token $GITHUB_TOKEN" \
            https://raw.githubusercontent.com/mcqwyhud/sui-group/main/agent_linux_install_v1.0.sh \
            -o "$AGENT_SCRIPT" 2>/dev/null || {
                warn "从主仓库下载失败，尝试备用地址..."
                curl -sSL -H "Authorization: token $GITHUB_TOKEN" \
                    https://raw.githubusercontent.com/mcqwyhud/sui-agent/main/install.sh \
                    -o "$AGENT_SCRIPT" 2>/dev/null || {
                        err "无法下载 agent 安装脚本（需要 GITHUB_TOKEN）"
                    }
            }
    else
        log "尝试公开下载..."
        curl -sSL https://raw.githubusercontent.com/mcqwyhud/sui-group/main/agent_linux_install_v1.0.sh \
            -o "$AGENT_SCRIPT" 2>/dev/null || {
                warn "公开下载失败，尝试备用地址..."
                curl -sSL https://raw.githubusercontent.com/mcqwyhud/sui-agent/main/install.sh \
                    -o "$AGENT_SCRIPT" 2>/dev/null || {
                        warn "无法下载 agent 安装脚本，将尝试手动安装..."
                        install_agent_manual
                        return $?
                    }
            }
    fi
    
    if [ ! -f "$AGENT_SCRIPT" ] || [ ! -s "$AGENT_SCRIPT" ]; then
        warn "Agent 安装脚本下载失败或为空，尝试手动安装..."
        install_agent_manual
        return $?
    fi
    
    chmod +x "$AGENT_SCRIPT"

    # ==========================================
    # 3. ⭐ 根据是否有 Token 决定子脚本的执行方式
    # ==========================================
    if [ -n "$GITHUB_TOKEN" ]; then
        # 【有 Token】→ 非交互式执行（子脚本不会询问 Token）
        log "检测到 GITHUB_TOKEN，以非交互式方式执行 agent 安装..."
        export GITHUB_TOKEN="$GITHUB_TOKEN"
        bash "$AGENT_SCRIPT" </dev/null
    else
        # 【无 Token】→ 交互式执行（子脚本会询问 Token 和配置）
        log "未检测到 GITHUB_TOKEN，以交互式方式执行 agent 安装..."
        log "（子脚本将提示输入 Token 和配置信息）"
        bash "$AGENT_SCRIPT"
    fi
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log "✅ Agent 安装成功"
    else
        warn "Agent 安装失败，退出码: $exit_code"
        log "尝试手动安装 Agent..."
        install_agent_manual
    fi
}

# ------------------------------
# 7.1 手动安装 Agent（备用方案）
# ------------------------------
install_agent_manual() {
    log "手动安装 sui-agent..."

    mkdir -p /opt/sui-agent/{config,logs,data,conf}
    
    if ! id -u suiagent &>/dev/null; then
        useradd -r -s /bin/false suiagent
        log "用户 suiagent 创建成功"
    fi
    
    # ==========================================
    # 获取 Token（如果是交互式环境）
    # ==========================================
    if [ -z "$GITHUB_TOKEN" ]; then
        if is_interactive_shell && ! is_non_interactive; then
            echo ""
            log "手动安装需要 GitHub Token 下载 JAR 文件"
            read -p "GitHub Token (按回车跳过): " input_token
            if [ -n "$input_token" ]; then
                GITHUB_TOKEN="$input_token"
                export GITHUB_TOKEN="$input_token"
                log "✅ Token 已设置"
            fi
        fi
    fi

    # ==========================================
    # 下载 JAR 文件
    # ==========================================
    local JAR_URL="https://github.com/mcqwyhud/sui-agent/releases/latest/download/sui-agent.jar"
    local JAR_FILE="/opt/sui-agent/sui-agent.jar"
    
    log "下载 Agent JAR 文件..."
    
    if [ -n "$GITHUB_TOKEN" ]; then
        log "使用 GitHub Token 下载 JAR..."
        curl -sSL -H "Authorization: token $GITHUB_TOKEN" \
            "$JAR_URL" -o "$JAR_FILE" 2>/dev/null || {
                warn "JAR 下载失败，尝试使用 GitHub API..."
                local API_URL="https://api.github.com/repos/mcqwyhud/sui-agent/releases/latest"
                local DOWNLOAD_URL=$(curl -sSL -H "Authorization: token $GITHUB_TOKEN" \
                    "$API_URL" 2>/dev/null | grep -o '"browser_download_url": "[^"]*\.jar"' | head -1 | cut -d'"' -f4)
                if [ -n "$DOWNLOAD_URL" ]; then
                    curl -sSL -H "Authorization: token $GITHUB_TOKEN" \
                        "$DOWNLOAD_URL" -o "$JAR_FILE"
                fi
            }
    else
        log "尝试直接下载 JAR（公开仓库）..."
        curl -sSL "$JAR_URL" -o "$JAR_FILE" 2>/dev/null || {
            warn "JAR 下载失败（可能需要 GITHUB_TOKEN）"
            return 1
        }
    fi
    
    if [ ! -f "$JAR_FILE" ]; then
        err "无法下载 Agent JAR 文件"
    fi
    
    if [ ! -s "$JAR_FILE" ]; then
        err "下载的 JAR 文件为空"
    fi
    
    chown suiagent:suiagent "$JAR_FILE"
    chmod 644 "$JAR_FILE"
    
    # ==========================================
    # 创建 systemd 服务
    # ==========================================
    log "创建 systemd 服务..."
    cat > /etc/systemd/system/sui-agent.service <<'EOF'
[Unit]
Description=SUI Agent Service
After=network.target

[Service]
Type=simple
User=suiagent
Group=suiagent
WorkingDirectory=/opt/sui-agent
ExecStart=/usr/bin/java -jar /opt/sui-agent/sui-agent.jar
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sui-agent
    systemctl start sui-agent
    
    sleep 2
    
    if systemctl is-active --quiet sui-agent; then
        log "✅ sui-agent 安装并启动成功"
    else
        warn "sui-agent 启动失败，请检查日志: journalctl -u sui-agent -f"
        log "手动启动命令: systemctl start sui-agent"
    fi
}

# ------------------------------
# 8. 验证安装
# ------------------------------
verify_installation() {
    log "验证安装..."
    
    if systemctl is-active --quiet s-ui; then
        log "✅ s-ui 运行正常"
    else
        warn "⚠️ s-ui 未运行"
    fi
    
    if systemctl is-active --quiet sui-agent; then
        log "✅ sui-agent 运行正常"
    else
        warn "⚠️ sui-agent 未运行"
    fi
    
    local congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    log "BBR 状态: $congestion"
    
    log "端口监听状态:"
    ss -tlnp | grep -E ":(2095|2096|10200)" 2>/dev/null || {
        netstat -tlnp 2>/dev/null | grep -E ":(2095|2096|10200)" || echo "  无法查看端口状态"
    }
}

# ------------------------------
# 9. 显示完成信息
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
    echo "  - BBR 状态: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
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
    echo "  - agent:  systemctl {start|stop|restart|status} sui-agent"
    echo ""
    echo "📊 查看日志:"
    echo "  - s-ui:   journalctl -u s-ui -f"
    echo "  - agent:  journalctl -u sui-agent -f"
    echo ""
    echo "🌐 访问面板:"
    echo "  http://$(hostname -I | awk '{print $1}'):2095/app/"
    echo "  (默认账号: admin / admin123)"
    echo "  地址或账号密码不正确时可执行 s-ui 命令自行查看"
    echo "  使用正确地址如无法访问，请检查安全组/防火墙规则"
    echo ""
    echo "=========================================="
}

# ------------------------------
# 10. 清理临时文件
# ------------------------------
cleanup() {
    log "清理临时文件..."
    rm -f /tmp/agent_install.sh /tmp/agent_token /tmp/main_script.sh 2>/dev/null
}

# ------------------------------
# 11. 主流程
# ------------------------------
main() {
    log "开始安装 SUI + SUI-Agent v2.0..."
    echo "=========================================="
    
    if [ "$EUID" -ne 0 ]; then
        err "请使用 root 用户运行此脚本"
    fi
    
    # 显示 GITHUB_TOKEN 状态
    if [ -n "$GITHUB_TOKEN" ]; then
        log "✅ GITHUB_TOKEN 已设置"
    else
        if is_interactive_shell && ! is_non_interactive; then
            log "ℹ️ 交互式环境，如需访问私有仓库请在后续输入 Token"
        else
            warn "⚠️ GITHUB_TOKEN 未设置，如果仓库是私有的将无法下载"
        fi
    fi
    
    install_base
    install_sui
    configure_agent_and_sui
    enable_bbr || true
    wait_sui
    install_agent
    verify_installation
    show_complete
    cleanup
    
    log "安装流程完成！"
}

# 捕获错误
trap 'err "安装过程中发生错误，请检查日志"' ERR

# 执行主函数
main
