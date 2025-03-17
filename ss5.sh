#!/usr/bin/env bash

# 严格模式
set -euo pipefail

# 全局配置
readonly SCRIPT_NAME="Socks5 Proxy Manager"
readonly VERSION="2.1"
readonly BIN_PATH="/usr/local/bin/socks"
readonly CONFIG_DIR="/etc/socks"
readonly SERVICE_FILE="/etc/systemd/system/sockd.service"
readonly REPO_URL="https://wp.xenosccc.tech/socks"

# 颜色定义
readonly RED='\033[31m'
readonly GREEN='\033[32m'
readonly YELLOW='\033[33m'
readonly BLUE='\033[34m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# 依赖检查
readonly DEPENDENCIES=(curl wget lsof jq iptables)

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${RESET} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${RESET} $1"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $1" >&2; }

# 检查 Root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "必须使用 root 权限运行此脚本"
        exit 1
    fi
}

# 系统检测
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
    else
        log_error "无法检测操作系统"
        exit 1
    fi

    case "${OS_ID}" in
        centos|rhel|almalinux|rocky)
            if [[ "${OS_VERSION}" =~ ^7|8|9 ]]; then
                PKG_MANAGER="yum"
            else
                log_error "CentOS/RHEL 版本 ${OS_VERSION} 不受支持"
                exit 1
            fi
            ;;
        debian|ubuntu)
            if [[ "${OS_ID}" == "debian" && "${OS_VERSION}" =~ ^9|10|11|12 ]] || \
               [[ "${OS_ID}" == "ubuntu" && "${OS_VERSION}" =~ ^18.04|20.04|22.04|24.04 ]]; then
                PKG_MANAGER="apt"
            else
                log_error "${OS_ID} 版本 ${OS_VERSION} 不受支持"
                exit 1
            fi
            ;;
        *)
            log_error "不支持的操作系统: ${OS_ID}"
            exit 1
            ;;
    esac
}

# 安装依赖
install_dependencies() {
    log_info "正在安装系统依赖..."
    
    case "${PKG_MANAGER}" in
        yum)
            yum install -q -y epel-release
            yum install -q -y "${DEPENDENCIES[@]}"
            ;;
        apt)
            apt-get update -qq
            apt-get install -qq -y "${DEPENDENCIES[@]}"
            ;;
    esac

    if ! command -v jq &>/dev/null; then
        log_error "依赖安装失败: jq 未找到"
        exit 1
    fi
}

# 防火墙管理
manage_firewall() {
    local action=$1
    local port=$2

    case "${PKG_MANAGER}" in
        yum)
            if systemctl is-active --quiet firewalld; then
                firewall-cmd --permanent "--${action}-port=${port}/tcp"
                firewall-cmd --permanent "--${action}-port=${port}/udp"
                firewall-cmd --reload
            else
                if [[ "${action}" == "add" ]]; then
                    iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT
                    iptables -I INPUT -p udp --dport "${port}" -j ACCEPT
                else
                    iptables -D INPUT -p tcp --dport "${port}" -j ACCEPT
                    iptables -D INPUT -p udp --dport "${port}" -j ACCEPT
                fi
                service iptables save
            fi
            ;;
        apt)
            ufw "${action}" "${port}/tcp"
            ufw "${action}" "${port}/udp"
            ufw reload > /dev/null
            ;;
    esac
}

# 生成随机密码
generate_password() {
    tr -dc 'A-Za-z0-9!@#$%^&*()' </dev/urandom | head -c 16
}

# 服务管理
service_manager() {
    case $1 in
        start|stop|restart|status)
            systemctl "$1" sockd.service
            ;;
        enable)
            systemctl enable --now sockd.service
            ;;
        disable)
            systemctl disable --now sockd.service
            ;;
    esac
}

# 安装主程序
install_socks() {
    log_info "正在下载主程序..."
    if ! curl -fsSL "${REPO_URL}" -o "${BIN_PATH}"; then
        log_error "文件下载失败"
        exit 1
    fi

    chmod 755 "${BIN_PATH}"
    log_success "主程序安装完成"
}

# 配置文件生成
generate_config() {
    local port=$1
    local user=$2
    local password=$3

    mkdir -p "${CONFIG_DIR}"
    cat > "${CONFIG_DIR}/config.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "AsIs"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": "$port",
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "$user",
            "pass": "$passwd"
          }
        ],
        "udp": true
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
}

# 显示连接信息
show_connection() {
    local ip=$(curl -4fsSL https://api.ip.sb/ip || hostname -I | awk '{print $1}')
    local port=$1
    local user=$2
    local password=$3

    cat <<EOF

${BOLD}====== 连接信息 ======${RESET}
地址: ${GREEN}${ip}${RESET}
端口: ${GREEN}${port}${RESET}
用户: ${GREEN}${user}${RESET}
密码: ${GREEN}${password}${RESET}
协议: ${GREEN}socks5${RESET}
加密: ${GREEN}none${RESET}

EOF
    echo "上述信息已保存至: /root/socks5-info.txt"
}

# 安装流程
install() {
    check_root
    detect_os
    install_dependencies

    # 用户输入
    local port
    while :; do
        read -rp "请输入监听端口 [1024-65535] (默认: 随机生成): " port
        if [[ -z "${port}" ]]; then
            port=$(shuf -i 20000-65000 -n 1)
            break
        elif [[ "${port}" =~ ^[0-9]+$ ]] && [ "${port}" -ge 1024 ] && [ "${port}" -le 65535 ]; then
            break
        else
            log_error "无效端口号"
        fi
    done

    local user
    while :; do
        read -rp "请输入用户名 (默认: admin_$(shuf -i 1000-9999 -n 1)): " user
        user=${user:-"admin_$(shuf -i 1000-9999 -n 1)"}
        [[ "${user}" =~ ^[a-zA-Z0-9_-]+$ ]] && break
        log_error "用户名只能包含字母、数字、下划线和连字符"
    done

    local password
    while :; do
        read -rp "请输入密码 (默认: 随机生成): " password
        if [[ -z "${password}" ]]; then
            password=$(generate_password)
            break
        elif [[ "${#password}" -ge 5 ]]; then
            break
        else
            log_error "密码长度至少5位"
        fi
    done

    # 安装流程
    install_socks
    generate_config "${port}" "${user}" "${password}"
    manage_firewall add "${port}"

    # 服务配置
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=SOCKS5 Proxy Service
After=network.target

[Service]
Type=simple
LimitNOFILE=1048576
ExecStart=${BIN_PATH} -c ${CONFIG_DIR}/config.json
Restart=on-failure
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    service_manager enable
    service_manager start

    if systemctl is-active --quiet sockd.service; then
        show_connection "${port}" "${user}" "${password}"
        log_success "安装完成"
    else
        log_error "服务启动失败，请检查日志：journalctl -u sockd.service"
        exit 1
    fi
}

# 卸载流程
uninstall() {
    check_root
    local port=$(jq -r '.inbounds[0].port' "${CONFIG_DIR}/config.json" 2>/dev/null || echo "")

    log_warning "开始卸载..."
    service_manager stop
    service_manager disable
    rm -f "${BIN_PATH}" "${SERVICE_FILE}"
    rm -rf "${CONFIG_DIR}"
    systemctl daemon-reload

    if [[ -n "${port}" ]]; then
        manage_firewall delete "${port}"
    fi

    log_success "已完全卸载"
}

# 主菜单
main_menu() {
    clear
    echo -e "${BOLD}${SCRIPT_NAME} v${VERSION}${RESET}"
    echo "------------------------"
    echo "1. 安装 SOCKS5 代理"
    echo "2. 卸载 SOCKS5 代理"
    echo "3. 服务状态检查"
    echo "4. 退出脚本"
    echo "------------------------"

    read -rp "请输入选项 [1-4]: " choice
    case $choice in
        1) install ;;
        2) uninstall ;;
        3) service_manager status ;;
        4) exit 0 ;;
        *) log_error "无效选项"; sleep 1; main_menu ;;
    esac
}

# 脚本入口
trap "echo -e '\n操作已取消'; exit 1" SIGINT
main_menu