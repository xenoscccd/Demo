#!/bin/bash

# 日志文件配置
LOGFILE="/var/log/fail2ban_setup.log"

# 可配置变量（可通过环境变量覆盖）
FAIL2BAN_REPO="${FAIL2BAN_REPO:-https://git.btsb.one/github.com/fail2ban/fail2ban.git}"
IPSUM_URL="${IPSUM_URL:-https://git.btsb.one/raw.githubusercontent.com/stamparm/ipsum/master/ipsum.txt}"
PYTHON3_MIN_VERSION="3.6"

# 系统信息检测
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_MAJOR_VERSION="${VERSION_ID%%.*}"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 初始化包管理器
init_pkg_manager() {
    if command -v yum >/dev/null; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y -q"
        UPDATE_CMD="yum update -y -q"
        SERVICE_SUFFIX=""
    elif command -v dnf >/dev/null; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y -q"
        UPDATE_CMD="dnf update -y -q"
        SERVICE_SUFFIX=""
    elif command -v apt-get >/dev/null; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y -qq"
        UPDATE_CMD="apt-get update -y && apt-get upgrade -y -qq"
        SERVICE_SUFFIX=""
    else
        echo -e "${RED}不支持的包管理器${NC}" | tee -a $LOGFILE
        exit 1
    fi

    # case "$OS_ID" in
    # centos | rhel | fedora | ol)
    #     PKG_MANAGER="yum"
    #     INSTALL_CMD="yum install -y -q"
    #     UPDATE_CMD="yum update -y -q"
    #     SERVICE_SUFFIX=""
    #     # 启用EPEL（CentOS/RHEL 7+）
    #     if [[ "$OS_ID" =~ (centos|rhel) && ! -f /etc/yum.repos.d/epel.repo ]]; then
    #         echo -e "${YELLOW}启用EPEL仓库...${NC}" | tee -a $LOGFILE
    #         $INSTALL_CMD epel-release >>$LOGFILE 2>&1 || {
    #             echo -e "${RED}默认EPEL仓库启用失败，使用第三方EPEL仓库...${NC}" | tee -a $LOGFILE
    #             $INSTALL_CMD http://vault.epel.cloud//pub/epel/epel-release-latest-7.noarch.rpm >>$LOGFILE 2>&1
    #         }
    #     fi
    #     ;;
    # debian | ubuntu)
    #     PKG_MANAGER="apt"
    #     INSTALL_CMD="apt-get install -y -qq"
    #     UPDATE_CMD="apt-get update -y && apt-get upgrade -y -qq"
    #     SERVICE_SUFFIX=""
    #     ;;
    # *)
    #     echo -e "${RED}不支持的操作系统: $OS_ID${NC}" | tee -a $LOGFILE
    #     exit 1
    #     ;;
    # esac
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请以root身份运行此脚本${NC}" | tee -a $LOGFILE
        exit 1
    fi
}

# 检查并安装iptables
install_iptables() {
    echo -e "${YELLOW}[2/10] 检查iptables服务...${NC}" | tee -a $LOGFILE

    # 检查iptables命令是否存在
    if ! command -v iptables &>/dev/null; then
        echo -e "${YELLOW}安装iptables...${NC}" | tee -a $LOGFILE
        $INSTALL_CMD iptables >>$LOGFILE 2>&1 || {
            echo -e "${RED}iptables安装失败${NC}" | tee -a $LOGFILE
            exit 1
        }
    fi

    # 系统服务检查（CentOS）
    if [ "$PKG_MANAGER" = "yum" ]; then
        if ! rpm -q iptables-services &>/dev/null; then
            echo -e "${YELLOW}安装iptables-services...${NC}" | tee -a $LOGFILE
            $INSTALL_CMD iptables-services >>$LOGFILE 2>&1 || {
                echo -e "${RED}iptables-services安装失败${NC}" | tee -a $LOGFILE
                exit 1
            }
            systemctl enable iptables >>$LOGFILE 2>&1
            systemctl start iptables >>$LOGFILE 2>&1
        fi
    fi

    # Debian持久化支持
    if [ "$PKG_MANAGER" = "apt" ]; then
        if ! dpkg -l | grep -q iptables-persistent; then
            echo -e "${YELLOW}安装iptables-persistent...${NC}" | tee -a $LOGFILE
            export DEBIAN_FRONTEND=noninteractive
            $INSTALL_CMD iptables-persistent >>$LOGFILE 2>&1 || {
                echo -e "${RED}iptables-persistent安装失败${NC}" | tee -a $LOGFILE
                exit 1
            }
        fi
    fi
}

# 系统更新
system_update() {
    echo -e "${YELLOW}[1/10] 正在更新系统软件包...${NC}" | tee -a $LOGFILE
    eval $UPDATE_CMD >>$LOGFILE 2>&1 || {
        echo -e "${RED}系统更新失败${NC}" | tee -a $LOGFILE
        exit 1
    }
}

# 安装rsyslog
install_rsyslog() {
    if ! command -v rsyslogd &>/dev/null; then
        echo -e "${YELLOW}[3/10] 正在安装rsyslog...${NC}" | tee -a $LOGFILE
        $INSTALL_CMD rsyslog >>$LOGFILE 2>&1 || {
            echo -e "${RED}rsyslog安装失败${NC}" | tee -a $LOGFILE
            exit 1
        }
        systemctl enable rsyslog --now >>$LOGFILE 2>&1
    fi
}

# 配置SSH日志
configure_ssh() {
    local sshd_config="/etc/ssh/sshd_config"
    cp "$sshd_config" "${sshd_config}.bak-$(date +%s)"

    echo -e "${YELLOW}[4/10] 配置SSH日志级别...${NC}" | tee -a $LOGFILE
    if grep "^LogLevel" -q $sshd_config; then
        echo -e "${YELLOW}SSH日志级别已配置${NC}" | tee -a $LOGFILE
    else
        echo "LogLevel INFO" >>"$sshd_config"
    fi

    local ssh_service_name="sshd"
    [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ] && ssh_service_name="ssh"

    systemctl restart "$ssh_service_name" >>$LOGFILE 2>&1 || {
        echo -e "${RED}SSH服务重启失败${NC}" | tee -a $LOGFILE
        exit 1
    }
}

# 检查并安装Python3
check_python3() {
    if ! command -v python3 &>/dev/null; then
        echo -e "${YELLOW}[5/10] 正在安装Python3...${NC}" | tee -a $LOGFILE
        install_python3_centos7
        return $?
    fi

    # 验证版本
    local py3_version=$(python3 -V 2>&1 | awk '{print $2}')
    if [ "$(printf '%s\n' "$PYTHON3_MIN_VERSION" "$py3_version" | sort -V | head -n1)" != "$PYTHON3_MIN_VERSION" ]; then
        echo -e "${RED}Python3版本过低 (需要 >= $PYTHON3_MIN_VERSION，当前 $py3_version)${NC}" | tee -a $LOGFILE
        return 1
    fi

    # 检查pip3
    if ! command -v pip3 &>/dev/null; then
        echo -e "${YELLOW}安装python3-pip...${NC}" | tee -a $LOGFILE
        $INSTALL_CMD python3-pip >>$LOGFILE 2>&1 || {
            echo -e "${RED}pip3安装失败${NC}" | tee -a $LOGFILE
            return 1
        }
    fi

    return 0
}

# CentOS 7专用Python安装
install_python3_centos7() {
    # 启用SCL仓库
    $INSTALL_CMD centos-release-scl >>$LOGFILE 2>&1 || {
        echo -e "${RED}SCL仓库启用失败${NC}" | tee -a $LOGFILE
        return 1
    }

    # 安装Python 3.6
    echo -e "${YELLOW}安装rh-python36...${NC}" | tee -a $LOGFILE
    $INSTALL_CMD rh-python36 >>$LOGFILE 2>&1 || {
        echo -e "${RED}Python3安装失败${NC}" | tee -a $LOGFILE
        return 1
    }

    # 配置环境
    echo -e "${YELLOW}设置Python3环境...${NC}" | tee -a $LOGFILE
    cat >/etc/profile.d/python36.sh <<EOF
#!/bin/bash
source /opt/rh/rh-python36/enable
export PATH=\$PATH:/opt/rh/rh-python36/root/bin
EOF
    source /etc/profile.d/python36.sh

    # 验证安装
    if ! command -v python3 &>/dev/null; then
        echo -e "${RED}Python3安装验证失败${NC}" | tee -a $LOGFILE
        return 1
    fi

    # 安装pip
    echo -e "${YELLOW}配置pip3...${NC}" | tee -a $LOGFILE
    python3 -m ensurepip >>$LOGFILE 2>&1 || {
        echo -e "${RED}pip3安装失败${NC}" | tee -a $LOGFILE
        return 1
    }

    return 0
}

# 安装系统依赖
install_dependencies() {
    echo -e "${YELLOW}[6/10] 正在安装系统依赖...${NC}" | tee -a $LOGFILE
    local deps=(git ipset)

    if [ "$PKG_MANAGER" = "yum" ]; then
        # CentOS特殊依赖
        yum groupinstall -y -q "Development Tools" >>$LOGFILE 2>&1
        deps+=(python3-pip)
        check_python3 || exit 1
    else
        # Debian系列
        deps+=(python3-pip)
    fi

    $INSTALL_CMD "${deps[@]}" >>$LOGFILE 2>&1 || {
        echo -e "${RED}依赖安装失败${NC}" | tee -a $LOGFILE
        exit 1
    }
}

# 安装fail2ban
install_fail2ban() {
    echo -e "${YELLOW}[7/10] 检查当前是否已经安装fail2ban...${NC}" | tee -a $LOGFILE
    if command -v fail2ban-client &>/dev/null; then
        echo -e "${YELLOW}fail2ban已经安装${NC},跳过安装 执行添加恶意黑名单脚本" | tee -a $LOGFILE
        block_malicious_ips
        setup_cron_job
        echo -e "${GREEN}\n安装完成！建议重启系统以确保所有配置生效${NC}" | tee -a $LOGFILE
        echo -e "${YELLOW}详细日志请查看: $LOGFILE${NC}"
        exit 0
    fi
    echo -e "${YELLOW}[7/10] 正在安装fail2ban...${NC}" | tee -a $LOGFILE
    # 先通过系统包安装
    if [[ "$PKG_MANAGER" =~ ^(yum|dnf|apt)$ ]]; then
        ${INSTALL_CMD} fail2ban >>$LOGFILE 2>&1 || {
            echo -e "${RED}通过系统源fail2ban安装失败${NC}" | tee -a $LOGFILE
        }
    else
        # 检查git是否安装
        if ! command -v git &>/dev/null; then
            echo -e "${YELLOW}安装git...${NC}" | tee -a $LOGFILE
            $INSTALL_CMD git >>$LOGFILE 2>&1 || {
                echo -e "${RED}git安装失败，无法继续${NC}" | tee -a $LOGFILE
                exit 1
            }
        fi

        # 克隆仓库
        echo -e "${YELLOW}克隆仓库: $FAIL2BAN_REPO${NC}" | tee -a $LOGFILE
        git clone "$FAIL2BAN_REPO" >>$LOGFILE 2>&1 || {
            echo -e "${RED}仓库克隆失败${NC}" | tee -a $LOGFILE
            exit 1
        }
        cd fail2ban || exit 1
        python3 setup.py install >>$LOGFILE 2>&1 && touch /etc/fail2ban/py.installed || {
            echo -e "${RED}fail2ban安装失败${NC}" | tee -a $LOGFILE
            exit 1
        }
        cd ..
    fi
}

# 配置fail2ban
configure_fail2ban() {
    echo -e "${YELLOW}[8/10] 正在配置fail2ban...${NC}" | tee -a $LOGFILE
    port=$(cat /etc/ssh/sshd_config | grep "^Port" | awk '{print $2}')
    if [ -z "$port" ]; then
        port=22
    fi
    # 初始化配置文件
    if [ ! -f /etc/fail2ban/jail.local ]; then
        echo -e "${YELLOW}初始化配置文件...${NC}" | tee -a $LOGFILE
        if [[ "$PKG_MANAGER" =~ ^(yum|dnf|apt)$ ]]; then
            cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
# 配置忽略检测的 IP (段），添加多个需要用空格隔开
ignoreip = 127.0.0.1/8
[sshd]
enabled = true
# ssh的端口
port = ${port}
# 配置使用的匹配规则文件（位于 /etc/fail2ban/filter.d 目录中）
filter = sshd    
# 日志文件路径
logpath = /var/log/secure
# 配置 IP 封禁的持续时间（years/months/weeks/days/hours/minutes/seconds）
bantime  = 7d
# 是否开启增量禁止，可选
bantime.increment = true
# 如果上面为false则不生效，增量禁止的指数因子，这里设置为168的意思就是每次增加 168*(2^ban次数) (封禁时长类似这样 - 1小时 -> 7天 -> 14天 ...):
bantime.factor = 168
# 配置 IP 封禁的持续时间（years/months/weeks/days/hours/minutes/seconds）
maxretry = 3
# 配置使用的匹配规则文件（位于 /etc/fail2ban/filter.d 目录中）
action = iptables
EOF
        else
            cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
# 配置忽略检测的 IP (段)，添加多个需要用空格隔开
ignoreip = 127.0.0.1/8
[sshd]
enabled = true
# ssh的端口
port = ${port}
# 配置使用的匹配规则文件（位于 /etc/fail2ban/filter.d 目录中）
filter = sshd
# 日志文件路径
logpath = /var/log/auth.log
# 配置 IP 封禁的持续时间（years/months/weeks/days/hours/minutes/seconds）
bantime  = 7d
# 是否开启增量禁止，可选
bantime.increment = true
# 如果上面为false则不生效，增量禁止的指数因子，这里设置为168的意思就是每次增加 168*(2^ban次数) (封禁时长类似这样 - 1小时 -> 7天 -> 14天 ...):
bantime.factor = 168
# 最大封禁时间，8w 表示8周，可选
bantime.maxtime = 8w
# 配置计算封禁 IP 的具体滑动窗口大小
findtime  = 5m
# 配置在 findtime 时间内发生多少次失败登录然后将 IP 封禁
maxretry = 3
# 配置封禁 IP 的手段（位于 /etc/fail2ban/action.d 目录中），可通过 iptables、firewalld 或者 TCP Wrapper 等，此处设置为 hostsdeny 代表使用 TCP Wrapper
action = iptables
EOF
        fi
    else
        echo "jail.local already exists, skipping creation." | tee -a $LOGFILE
    fi

    # 服务管理
    if [ -f /etc/fail2ban/py.installed ]; then
        if [ "$PKG_MANAGER" = "apt" ]; then
            if [ -d "fail2ban" ]; then
                cp fail2ban/files/debian-initd /etc/init.d/fail2ban
                cp fail2ban/build/fail2ban.service /usr/lib/systemd/system/fail2ban.service
                update-rc.d fail2ban defaults
                service fail2ban start >>$LOGFILE 2>&1
                systemctl enable fail2ban >>$LOGFILE 2>&1
            else
                echo "fail2ban directory not found. Please check your script's location or download the necessary files." | tee -a $LOGFILE
            fi
        else
            if [ -d "/usr/lib/systemd/system/" ]; then
                cp files/redhat-systemd/* /usr/lib/systemd/system/
                systemctl daemon-reload
                systemctl enable fail2ban${SERVICE_SUFFIX} >>$LOGFILE 2>&1
                systemctl start fail2ban${SERVICE_SUFFIX} >>$LOGFILE 2>&1
            else
                echo "/usr/lib/systemd/system/ directory not found. Please check your system configuration." | tee -a $LOGFILE
            fi
        fi
    else
        if [ "$PKG_MANAGER" = "apt" ]; then
            update-rc.d fail2ban defaults
            service fail2ban start >>$LOGFILE 2>&1
        else
            chkconfig --add fail2ban
            chkconfig fail2ban on
            service fail2ban start >>$LOGFILE 2>&1
        fi
    fi
}
# 添加恶意IP黑名单
block_malicious_ips() {
    echo -e "${YELLOW}[9/10] 正在更新恶意IP黑名单...${NC}" | tee -a $LOGFILE

    # 创建ipset集合
    ipset create -exist ipsum hash:ip
    ipset flush ipsum

    # 下载并处理IP列表
    echo -e "${YELLOW}下载IP列表: $IPSUM_URL${NC}" | tee -a $LOGFILE
    curl --compressed -s "$IPSUM_URL" >/tmp/ipsum.txt || {
        echo -e "${RED}恶意IP列表下载失败${NC}" | tee -a $LOGFILE
        return 1
    }

    cat /tmp/ipsum.txt | awk '!/#/ && $2 >=3 {print $1}' |
        while read -r ip; do
            ipset add ipsum "$ip" 2>/dev/null
        done

    # 应用iptables规则
    iptables -D INPUT -m set --match-set ipsum src -j DROP 2>/dev/null
    iptables -I INPUT -m set --match-set ipsum src -j DROP

    # 规则持久化
    if [ "$PKG_MANAGER" = "yum" ]; then
        service iptables save >>$LOGFILE 2>&1 || {
            echo -e "${YELLOW}iptables规则保存失败，可能需要手动保存${NC}" | tee -a $LOGFILE
        }
    else
        netfilter-persistent save >>$LOGFILE 2>&1 || {
            echo -e "${YELLOW}iptables规则保存失败，可能需要手动保存${NC}" | tee -a $LOGFILE
        }
    fi
}

# 配置定时任务
setup_cron_job() {
    echo -e "${YELLOW}[10/10] 配置定时更新任务...${NC}" | tee -a $LOGFILE

    # 创建更新脚本
    cat >/etc/fail2ban/update_ipset.sh <<EOF
#!/bin/bash
LOGFILE="/var/log/ipset_update.log"
IPSUM_URL="$IPSUM_URL"

# 获取系统信息
source /etc/os-release
OS_ID="\${ID:-unknown}"

# 创建ipset（如果不存在）
ipset create -exist ipsum hash:ip
ipset flush ipsum

echo "\$(date) 开始更新IP黑名单" >> \$LOGFILE

# 下载并处理IP列表
curl --compressed -s "\$IPSUM_URL" | \\
    awk '!/#/ && \$2 >=3 {print \$1}' | \\
    while read -r ip; do
        ipset add ipsum "\$ip" 2>/dev/null
    done

# 确保iptables规则存在
iptables -D INPUT -m set --match-set ipsum src -j DROP 2>/dev/null
iptables -I INPUT -m set --match-set ipsum src -j DROP

# 规则持久化
if [[ "\$OS_ID" =~ (centos|rhel|fedora|ol) ]]; then
    service iptables save >> \$LOGFILE 2>&1 || {
        echo "\$(date) iptables规则保存失败" >> \$LOGFILE
    }
else
    netfilter-persistent save >> \$LOGFILE 2>&1 || {
        echo "\$(date) iptables规则保存失败" >> \$LOGFILE
    }
fi

echo "\$(date) 更新完成" >> \$LOGFILE
EOF

    chmod +x /etc/fail2ban/update_ipset.sh

    # 添加cron任务
    (
        crontab -l 2>/dev/null
        echo "0 3 * * * /etc/fail2ban/update_ipset.sh"
    ) | crontab -
    echo -e "${GREEN}定时任务配置完成，每天凌晨3点自动更新IP黑名单${NC}" | tee -a $LOGFILE
}

# 主执行流程
main() {
    check_root
    init_pkg_manager
    system_update
    install_iptables
    install_rsyslog
    configure_ssh
    install_dependencies
    install_fail2ban
    configure_fail2ban
    block_malicious_ips
    setup_cron_job

    echo -e "${GREEN}\n安装完成！建议重启系统以确保所有配置生效${NC}" | tee -a $LOGFILE
    echo -e "${YELLOW}详细日志请查看: $LOGFILE${NC}"
}

# 执行主程序
main
