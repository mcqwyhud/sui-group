#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SERVICE="sui-master"
SERVICE_FILE="/etc/systemd/system/sui-master.service"
JVM_CONF="/opt/sui-master/conf/jvm_opts"

print_info(){ echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }

# -------------------------
# 状态展示
# -------------------------
show_status(){
    echo ""
    echo "=============================="
    echo " SUI-MASTER 状态"
    echo "=============================="

    systemctl is-active --quiet $SERVICE && echo "服务状态: 🟢 运行中" || echo "服务状态: 🔴 已停止"

    echo -n "自重启策略: "
    grep -q "^Restart=no" $SERVICE_FILE && echo "❌ 关闭" || echo "✅ 开启(on-failure)"

    echo -n "JVM参数: "
    cat "$JVM_CONF" 2>/dev/null || echo "默认"

    echo "=============================="
    echo ""
}

# -------------------------
# JVM
# -------------------------
show_jvm(){
    cat "$JVM_CONF"
}

set_jvm(){
    echo "$1" > "$JVM_CONF"
    systemctl restart $SERVICE
    print_info "JVM已更新并重启"
}

# -------------------------
# 自重启控制
# -------------------------
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
    esac
}

# -------------------------
# 菜单
# -------------------------
menu(){
    while true; do
        show_status

        echo "========== SUI-M 菜单 =========="
        echo "1) 启动服务"
        echo "2) 停止服务"
        echo "3) 重启服务"
        echo "4) 查看日志"
        echo "5) JVM 参数"
        echo "6) 自重启 开启"
        echo "7) 自重启 关闭"
        echo "8) 服务状态"
        echo "0) 退出"
        echo "================================"
        read -p "请选择操作: " opt

        case $opt in
            1) systemctl start $SERVICE ;;
            2) systemctl stop $SERVICE ;;
            3) systemctl restart $SERVICE ;;
            4) journalctl -u $SERVICE -f ;;
            5)
                echo "当前JVM:"
                show_jvm
                read -p "输入新JVM(回车跳过): " j
                [ -n "$j" ] && set_jvm "$j"
                ;;
            6) autorestart on ;;
            7) autorestart off ;;
            8) systemctl status $SERVICE ;;
            0) exit 0 ;;
            *) print_warn "无效选项" ;;
        esac

        echo ""
        read -p "按回车继续..."
    done
}

# -------------------------
# 命令模式（兼容旧用法）
# -------------------------
case "$1" in
    start) systemctl start $SERVICE ;;
    stop) systemctl stop $SERVICE ;;
    restart) systemctl restart $SERVICE ;;
    status) systemctl status $SERVICE ;;
    logs) journalctl -u $SERVICE -f ;;

    jvm)
        [ "$2" = "set" ] && set_jvm "$3" || show_jvm
        ;;

    autorestart)
        autorestart "$2"
        ;;

    ""|menu)
        menu
        ;;

    *)
        echo "用法:"
        echo "  sui-m            # 进入菜单"
        echo "  sui-m start|stop|restart"
        echo "  sui-m autorestart on|off"
        ;;
esac
