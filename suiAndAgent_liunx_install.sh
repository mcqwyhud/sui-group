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
# 1. 基础依赖
# ------------------------------
install_base() {
    log "安装基础依赖..."
    
    detect_os
    
    case "$OS" in
        ubuntu|debian)
            apt update -y
            apt install -y curl wget jq sqlite3
            ;;
        centos|rhel|almalinux|rocky|fedora)
            yum install -y curl wget jq sqlite
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

    # 检查是否已安装
    if systemctl status s-ui &>/dev/null; then
        warn "s-ui 已安装，跳过"
        return 0
    fi

    # 下载并执行官方安装脚本
    if ! curl -sSL https://raw.githubusercontent.com/admin8800/s-ui/master/install.sh | bash; then
        err "s-ui 安装失败"
    fi

    sleep 5

    # 启动服务
    systemctl enable s-ui --now || {
        err "s-ui 启动失败"
    }
    
    log "s-ui 安装完成"
}

# ------------------------------
# 3. 开启 BBR（新增）
# ------------------------------
enable_bbr() {
    log "检查并开启 BBR 加速..."

    # 检查当前 TCP 拥塞控制算法
    local current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    log "当前 TCP 拥塞控制算法: $current_congestion"

    # 检查是否已启用 BBR
    if [ "$current_congestion" = "bbr" ]; then
        log "BBR 已启用，跳过"
        return 0
    fi

    # 检查内核是否支持 BBR
    if ! modprobe tcp_bbr 2>/dev/null; then
        warn "当前内核不支持 BBR，尝试升级内核？"
        warn "跳过 BBR 配置"
        return 1
    fi

    log "通过 s-ui 交互命令开启 BBR..."

    # 使用 s-ui 命令开启 BBR（选项 18 -> 1）
    # 注意：s-ui 命令需要交互式输入，使用 expect 或 echo 管道
    if command -v expect &>/dev/null; then
        # 使用 expect 更可靠
        expect <<EOF
set timeout 10
spawn s-ui
expect "请输入数字"
send "18\r"
expect "请输入数字"
send "1\r"
expect eof
EOF
    else
        # 使用 echo 管道
        echo -e "18\n1" | s-ui || {
            warn "通过 s-ui 开启 BBR 失败，尝试直接配置 sysctl"
            # 备用方案：直接配置 sysctl
            enable_bbr_sysctl
        }
    fi

    # 验证 BBR 是否已启用
    sleep 2
    local new_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$new_congestion" = "bbr" ]; then
        log "✅ BBR 已成功启用"
    else
        warn "BBR 可能未成功启用，当前算法: $new_congestion"
        log "尝试直接配置 sysctl..."
        enable_bbr_sysctl
    fi
}

# ------------------------------
# 3.1 备用方案：直接配置 sysctl
# ------------------------------
enable_bbr_sysctl() {
    log "通过 sysctl 配置 BBR..."

    # 检查内核支持
    if ! modprobe tcp_bbr 2>/dev/null; then
        warn "内核不支持 BBR，请升级内核到 4.9+"
        return 1
    fi

    # 配置 sysctl
    cat >> /etc/sysctl.conf <<EOF

# BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    # 应用配置
    sysctl -p /etc/sysctl.conf || {
        warn "应用 sysctl 配置失败"
        return 1
    }

    # 验证
    local new_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$new_congestion" = "bbr" ]; then
        log "✅ BBR 已通过 sysctl 启用"
    else
        warn "BBR 启用失败，当前算法: $new_congestion"
        return 1
    fi
}

# ------------------------------
# 3.2 检查 BBR 状态（用于显示）
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
# 4. 等待 s-ui API 就绪
# ------------------------------
wait_sui() {
    log "等待 s-ui 启动..."

    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if curl -s http://127.0.0.1:2095 >/dev/null 2>&1; then
            log "s-ui API 已就绪"
            return 0
        fi
        
        # 也检查面板端口
        if curl -s http://127.0.0.1:2096 >/dev/null 2>&1; then
            log "s-ui Web 已就绪"
            return 0
        fi
        
        attempt=$((attempt + 1))
        log "等待中... ($attempt/$max_attempts)"
        sleep 2
    done

    err "s-ui 启动超时，请检查服务状态: systemctl status s-ui"
}

# ------------------------------
# 5. 创建 API Token
# ------------------------------
create_token() {
    log "创建 API Token..."

    # 查找数据库
    local DB_PATH=$(find_sui_db)
    if [ -z "$DB_PATH" ]; then
        warn "未找到 s-ui 数据库，尝试使用默认路径"
        DB_PATH="/usr/local/s-ui/db/s-ui.db"
        
        if [ ! -f "$DB_PATH" ]; then
            err "无法找到 s-ui 数据库，请确认 s-ui 已正确安装"
        fi
    fi
    
    log "使用数据库: $DB_PATH"

    # 检查 sqlite3 是否可用
    if ! command -v sqlite3 &>/dev/null; then
        err "sqlite3 未安装，请先安装 sqlite3"
    fi

    # 检查 tokens 表是否存在
    local table_exists=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='tokens';" 2>/dev/null)
    
    if [ -z "$table_exists" ]; then
        warn "tokens 表不存在，尝试创建..."
        sqlite3 "$DB_PATH" <<EOF
CREATE TABLE IF NOT EXISTS tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    desc TEXT,
    token TEXT,
    expiry INTEGER,
    user_id INTEGER
);
EOF
        log "tokens 表创建完成"
    fi

    # 获取用户 ID
    USER_ID=$(sqlite3 "$DB_PATH" "SELECT id FROM users LIMIT 1;" 2>/dev/null)
    
    if [ -z "$USER_ID" ]; then
        warn "未找到用户，使用默认 user_id=1"
        USER_ID=1
    fi
    
    log "使用 user_id: $USER_ID"

    # 生成 API Token
    API_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d "=+/" | head -c 32)
    
    # 插入 token
    sqlite3 "$DB_PATH" <<EOF
INSERT OR REPLACE INTO tokens (desc, token, expiry, user_id)
VALUES ('auto-install-token', '$API_TOKEN', 0, $USER_ID);
EOF

    if [ $? -eq 0 ]; then
        log "API Token 创建成功"
        echo "$API_TOKEN" > /tmp/sui_api_token
        chmod 600 /tmp/sui_api_token
    else
        err "API Token 创建失败"
    fi
}

# ------------------------------
# 6. 查找 s-ui 数据库路径
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
# 7. 安装 sui-agent
# ------------------------------
install_agent() {
    log "安装 sui-agent..."

    # 检查 token 文件
    if [ ! -f /tmp/sui_api_token ]; then
        err "API Token 文件不存在，请先创建 token"
    fi
    
    API_TOKEN=$(cat /tmp/sui_api_token)
    
    if [ -z "$API_TOKEN" ]; then
        err "API Token 为空"
    fi

    log "使用 API Token: ${API_TOKEN:0:8}..."

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

    # 执行 agent 安装，传入 token
    log "执行 agent 安装..."
    
    # 方式1: 通过环境变量传递
    export SUI_API_TOKEN="$API_TOKEN"
    
    # 方式2: 通过参数传递（如果脚本支持）
    if grep -q "\$1" "$AGENT_SCRIPT" 2>/dev/null; then
        bash "$AGENT_SCRIPT" "$API_TOKEN"
    else
        # 方式3: 通过文件传递
        echo "$API_TOKEN" > /tmp/agent_token
        bash "$AGENT_SCRIPT"
    fi
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log "Agent 安装成功"
    else
        warn "Agent 安装可能失败，退出码: $exit_code"
        warn "请手动执行: bash $AGENT_SCRIPT $API_TOKEN"
    fi
}

# ------------------------------
# 8. 验证安装
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
        warn "⚠️ sui-agent 未运行，尝试手动启动..."
        systemctl start sui-agent 2>/dev/null || {
            warn "无法启动 sui-agent，请检查配置"
        }
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
    echo "  - BBR 状态: $(check_bbr_status)"
    echo ""
    echo "🔑 API Token: $(cat /tmp/sui_api_token 2>/dev/null || echo '未生成')"
    echo ""
    echo "📂 配置文件:"
    echo "  - s-ui 数据库: $(find_sui_db 2>/dev/null || echo '未找到')"
    echo "  - Agent 配置: /opt/sui-agent/config/agent.json"
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
    echo ""
    echo "=========================================="
}

# ------------------------------
# 10. 清理临时文件
# ------------------------------
cleanup() {
    log "清理临时文件..."
    rm -f /tmp/agent_install.sh /tmp/agent_token 2>/dev/null
}

# ------------------------------
# 11. 主流程
# ------------------------------
main() {
    log "开始安装 SUI + SUI-Agent..."
    echo "=========================================="
    
    # 检查 root
    if [ "$EUID" -ne 0 ]; then
        err "请使用 root 用户运行此脚本"
    fi
    
    # 执行安装步骤
    install_base
    install_sui
    enable_bbr          # ⭐ 新增：开启 BBR
    wait_sui
    create_token
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
