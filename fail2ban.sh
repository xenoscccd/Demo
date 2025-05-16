#!/bin/bash

# 日志文件配置
LOGFILE="/var/log/fail2ban_setup.log"
exec &> >(tee -a "$LOGFILE") # 重定向所有输出到日志文件和标准输出

# 用到仓库，全部套了代理，避免国内无法使用。
FAIL2BAN_REPO="${FAIL2BAN_REPO:-https://git.btsb.one/github.com/fail2ban/fail2ban.git}"
IPSUM_URL="${IPSUM_URL:-https://git.btsb.one/raw.githubusercontent.com/stamparm/ipsum/master/ipsum.txt}"
PYTHON3_MIN_VERSION="3.6" # Python3 最低版本要求

# 系统信息检测
# shellcheck source=/dev/null
source /etc/os-release
OS_ID="${ID:-unknown}"               # 操作系统ID
OS_MAJOR_VERSION="${VERSION_ID%%.*}" # 操作系统主版本号

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# 防火墙类型 (iptables 或 ufw)
FIREWALL_TYPE="iptables"

# 初始化包管理器
init_pkg_manager() {
    echo -e "${YELLOW}初始化包管理器并检测防火墙...${NC}"
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
        # 检查基于apt的系统上的UFW
        if command -v ufw >/dev/null; then
            FIREWALL_TYPE="ufw"
            echo -e "${GREEN}检测到 UFW 作为防火墙管理器。${NC}"
        else
            echo -e "${YELLOW}未找到 UFW，将使用 iptables。${NC}"
        fi
    else
        echo -e "${RED}不支持的包管理器${NC}"
        exit 1
    fi
    echo -e "${GREEN}包管理器: $PKG_MANAGER, 防火墙类型: $FIREWALL_TYPE ${NC}"
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请以root身份运行此脚本${NC}"
        exit 1
    fi
}

# 设置防火墙 (UFW 或 iptables)
setup_firewall() {
    echo -e "${YELLOW}[2/10] 设置防火墙 ($FIREWALL_TYPE)...${NC}"
    local ssh_port
    ssh_port=$(awk '/^Port/ {print $2; exit}' /etc/ssh/sshd_config)
    ssh_port=${ssh_port:-22} # 如果未找到，则默认为22

    if [ "$FIREWALL_TYPE" = "ufw" ]; then
        # 设置 UFW
        if ! command -v ufw &>/dev/null; then
            echo -e "${YELLOW}未找到 UFW。正在安装 UFW...${NC}"
            $INSTALL_CMD ufw || {
                echo -e "${RED}UFW 安装失败${NC}"
                exit 1
            }
        fi
        echo -e "${YELLOW}配置 UFW...${NC}"
        ufw allow "$ssh_port/tcp"  # 允许 SSH
        ufw default deny incoming  # 默认拒绝入站连接
        ufw default allow outgoing # 默认允许出站连接
        # 下一行将提示确认。
        # 要自动执行，请使用 'yes | ufw enable' 或 'ufw --force enable'
        # 但是，如果 SSH 未正确允许，'--force' 可能有风险。
        if ! ufw status | grep -qw active; then
            echo -e "${YELLOW}启用 UFW。如果 SSH 未被允许，这可能会断开您的会话。请确保端口 $ssh_port 是开放的。${NC}"
            yes | ufw enable || { # 使用 'yes' 自动确认
                echo -e "${RED}启用 UFW 失败。${NC}"
                # 考虑此处不退出，因为如果ufw部分设置失败，fail2ban可能仍可与iptables一起工作
            }
        else
            echo -e "${GREEN}UFW 已激活。${NC}"
        fi
        ufw status verbose

        # 为ipset规则持久性安装iptables-persistent
        if ! dpkg -l | grep -q iptables-persistent; then
            echo -e "${YELLOW}为 ipset 规则持久性安装 iptables-persistent...${NC}"
            export DEBIAN_FRONTEND=noninteractive
            $INSTALL_CMD iptables-persistent || {
                echo -e "${RED}iptables-persistent 安装失败${NC}"
                # 不退出，因为fail2ban可能仍能运行
            }
        fi

    else
        # 设置 iptables (现有逻辑)
        if ! command -v iptables &>/dev/null; then
            echo -e "${YELLOW}正在安装 iptables...${NC}"
            $INSTALL_CMD iptables || {
                echo -e "${RED}iptables 安装失败${NC}"
                exit 1
            }
        fi

        if [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
            if ! rpm -q iptables-services &>/dev/null; then
                echo -e "${YELLOW}正在安装 iptables-services...${NC}"
                $INSTALL_CMD iptables-services || {
                    echo -e "${RED}iptables-services 安装失败${NC}"
                    exit 1
                }
                systemctl enable iptables
                systemctl start iptables
            fi
        elif [ "$PKG_MANAGER" = "apt" ]; then
            # 这部分适用于Debian上的iptables，如果UFW未被选择/可用
            if ! dpkg -l | grep -q iptables-persistent; then
                echo -e "${YELLOW}正在安装 iptables-persistent...${NC}"
                export DEBIAN_FRONTEND=noninteractive
                $INSTALL_CMD iptables-persistent || {
                    echo -e "${RED}iptables-persistent 安装失败${NC}"
                    exit 1
                }
            fi
        fi
    fi
    echo -e "${GREEN}防火墙设置完成。${NC}"
}

# 系统更新
system_update() {
    echo -e "${YELLOW}[1/10] 更新系统软件包...${NC}"
    eval "$UPDATE_CMD" >>"$LOGFILE" 2>&1 || {
        echo -e "${RED}系统更新失败${NC}"
        exit 1
    }
    echo -e "${GREEN}系统软件包已更新。${NC}"
}

# 安装rsyslog
install_rsyslog() {
    if ! command -v rsyslogd &>/dev/null; then
        echo -e "${YELLOW}[3/10] 正在安装 rsyslog...${NC}"
        $INSTALL_CMD rsyslog >>"$LOGFILE" 2>&1 || {
            echo -e "${RED}rsyslog 安装失败${NC}"
            exit 1
        }
        systemctl enable rsyslog --now
        echo -e "${GREEN}rsyslog 已安装并启用。${NC}"
    else
        echo -e "${GREEN}[3/10] rsyslog 已安装。${NC}"
    fi
}

# 配置SSH日志
configure_ssh() {
    local sshd_config="/etc/ssh/sshd_config"
    # 创建 sshd_config 文件的备份
    cp "$sshd_config" "${sshd_config}.bak-$(date +%s)"

    echo -e "${YELLOW}[4/10] 配置 SSH 日志级别...${NC}"
    if grep -q "^LogLevel" "$sshd_config"; then
        # 如果 LogLevel 存在，确保它是 INFO 或 VERBOSE
        if ! grep -q -E "^LogLevel\s+(INFO|VERBOSE)" "$sshd_config"; then
            sed -i "s/^LogLevel.*/LogLevel INFO/" "$sshd_config"
            echo -e "${YELLOW}SSH LogLevel 已更新为 INFO。${NC}"
        else
            echo -e "${GREEN}SSH LogLevel 已正确配置。${NC}"
        fi
    else
        echo "LogLevel INFO" >>"$sshd_config"
        echo -e "${YELLOW}SSH LogLevel 已设置为 INFO。${NC}"
    fi

    local ssh_service_name="sshd"
    [ "$OS_ID" = "debian" ] || [ "$OS_ID" = "ubuntu" ] && ssh_service_name="ssh"

    echo -e "${YELLOW}重启 SSH 服务 ($ssh_service_name)...${NC}"
    systemctl restart "$ssh_service_name" || {
        echo -e "${RED}SSH 服务重启失败${NC}"
        exit 1
    }
    echo -e "${GREEN}SSH 服务已重启。${NC}"
}

# 检查并安装Python3
check_python3() {
    echo -e "${YELLOW}[5/10] 检查 Python 3 安装情况...${NC}"
    if ! command -v python3 &>/dev/null; then
        echo -e "${YELLOW}未找到 Python3。尝试安装...${NC}"
        # 对于 CentOS 7，如果默认仓库没有最新的 Python 3，可能需要特殊处理
        if [[ "$OS_ID" == "centos" && "$OS_MAJOR_VERSION" == "7" ]]; then
            install_python3_centos7 || return 1
        else
            $INSTALL_CMD python3 || {
                echo -e "${RED}Python3 安装失败。${NC}"
                return 1
            }
        fi
    fi

    # 验证版本
    local py3_version
    py3_version=$(python3 -V 2>&1 | awk '{print $2}')
    if [[ -z "$py3_version" ]]; then
        echo -e "${RED}无法确定 Python3 版本。${NC}"
        return 1
    fi

    if [ "$(printf '%s\n' "$PYTHON3_MIN_VERSION" "$py3_version" | sort -V | head -n1)" != "$PYTHON3_MIN_VERSION" ]; then
        echo -e "${RED}Python3 版本过低 (当前 $py3_version, 需要 >= $PYTHON3_MIN_VERSION)${NC}"
        if [[ "$OS_ID" == "centos" && "$OS_MAJOR_VERSION" == "7" ]]; then
            echo -e "${YELLOW}尝试为 CentOS 7 安装合适的 Python3 版本...${NC}"
            install_python3_centos7 || return 1
            py3_version=$(python3 -V 2>&1 | awk '{print $2}') # 重新检查版本
            if [ "$(printf '%s\n' "$PYTHON3_MIN_VERSION" "$py3_version" | sort -V | head -n1)" != "$PYTHON3_MIN_VERSION" ]; then
                echo -e "${RED}尝试 CentOS 7 特定安装后仍无法满足 Python3 版本要求。${NC}"
                return 1
            fi
        else
            return 1
        fi
    fi
    echo -e "${GREEN}Python3 版本 $py3_version 符合要求。${NC}"

    # 检查pip3
    if ! command -v pip3 &>/dev/null; then
        echo -e "${YELLOW}未找到 pip3。正在安装 python3-pip...${NC}"
        $INSTALL_CMD python3-pip || {
            echo -e "${RED}python3-pip 安装失败${NC}"
            return 1
        }
    fi
    echo -e "${GREEN}pip3 可用。${NC}"
    return 0
}

# CentOS 7专用Python安装
install_python3_centos7() {
    echo -e "${YELLOW}正在为 CentOS 7 使用 SCL 安装 Python 3...${NC}"
    # 启用SCL仓库
    $INSTALL_CMD centos-release-scl || {
        echo -e "${RED}SCL 仓库启用失败${NC}"
        return 1
    }

    # 安装Python (例如, rh-python38 或 python36)
    # 首先尝试 rh-python38 因为它更新
    echo -e "${YELLOW}尝试安装 rh-python38...${NC}"
    if $INSTALL_CMD rh-python38-python rh-python38-python-pip; then
        echo -e "${YELLOW}设置 rh-python38 环境...${NC}"
        # 创建一个脚本来启用它，或者链接 python3/pip3
        ln -sf /opt/rh/rh-python38/root/usr/bin/python3 /usr/bin/python3
        ln -sf /opt/rh/rh-python38/root/usr/bin/pip3 /usr/bin/pip3
        # 测试 python3 命令是否适用于新版本
        if python3 -V &>/dev/null; then
            echo -e "${GREEN}rh-python38 安装并链接成功。${NC}"
            return 0
        fi
    fi

    echo -e "${YELLOW}rh-python38 安装失败或未找到，尝试 rh-python36...${NC}"
    $INSTALL_CMD rh-python36-python rh-python36-python-pip || {
        echo -e "${RED}rh-python36 安装失败${NC}"
        return 1
    }
    echo -e "${YELLOW}设置 rh-python36 环境...${NC}"
    ln -sf /opt/rh/rh-python36/root/usr/bin/python3 /usr/bin/python3
    ln -sf /opt/rh/rh-python36/root/usr/bin/pip3 /usr/bin/pip3

    if ! python3 -V &>/dev/null; then
        echo -e "${RED}安装后未找到 Python3 (来自 SCL) 命令。${NC}"
        return 1
    fi
    echo -e "${GREEN}Python 3 (来自 SCL) 安装成功。${NC}"
    return 0
}

# 安装系统依赖
install_dependencies() {
    echo -e "${YELLOW}[6/10] 安装系统依赖...${NC}"
    local deps=("git" "ipset") # ipset 对于 block_malicious_ips 至关重要

    # 调用 check_python3 以确保首先处理 Python 和 pip
    check_python3 || exit 1 # 如果 Python 设置失败则退出

    if [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
        # CentOS/RHEL/Fedora 特定的开发工具，如果从源代码构建（如果使用包则此处可选）
        # yum groupinstall -y -q "Development Tools" # 如果经常从源代码构建 fail2ban，则取消注释
        # 如果构建 python 模块，可能需要 python3-devel
        deps+=("python3-devel") # 如果需要，用于 fail2ban 源代码安装
    elif [ "$PKG_MANAGER" = "apt" ]; then
        deps+=("python3-dev") # 如果需要，用于 fail2ban 源代码安装
        deps+=("build-essential")
    fi

    $INSTALL_CMD "${deps[@]}" || {
        echo -e "${RED}依赖安装失败: ${deps[*]}${NC}"
        exit 1
    }
    echo -e "${GREEN}系统依赖已安装。${NC}"
}

# 安装fail2ban
install_fail2ban() {
    echo -e "${YELLOW}[7/10] 检查 Fail2ban 是否已安装...${NC}"
    if command -v fail2ban-client &>/dev/null; then
        echo -e "${GREEN}Fail2ban 已安装。${NC}"
        echo -e "${YELLOW}继续配置现有的 Fail2ban 并更新黑名单。${NC}"
        # 如果已安装，确保其已配置并且黑名单已更新
        configure_fail2ban # 确保配置是最新的
        block_malicious_ips
        setup_cron_job
        echo -e "${GREEN}\nFail2ban 设置/更新完成！${NC}"
        echo -e "${YELLOW}详细日志: $LOGFILE${NC}"
        exit 0
    fi

    echo -e "${YELLOW}正在安装 Fail2ban...${NC}"
    # 首先尝试从系统包安装
    if [[ "$PKG_MANAGER" =~ ^(yum|dnf|apt)$ ]]; then
        echo -e "${YELLOW}尝试从 $PKG_MANAGER 仓库安装 Fail2ban...${NC}"
        if $INSTALL_CMD fail2ban; then
            echo -e "${GREEN}Fail2ban 通过 $PKG_MANAGER 成功安装。${NC}"
            # 如果通过包管理器安装，确保服务已启用
            if [ ! -f "/etc/fail2ban/action.d/jail.conf" ] || ! systemctl is-enabled fail2ban >/dev/null 2>&1; then
                echo -e "${RED}检测到不完整安装，执行卸载...${NC}" | tee -a $LOGFILE
                $PKG_MANAGER remove -y fail2ban >>$LOGFILE 2>&1
                rm -rf /etc/fail2ban
            else
                echo -e "${GREEN}系统源安装验证通过${NC}" | tee -a $LOGFILE
            fi
        else
            echo -e "${YELLOW}从 $PKG_MANAGER 安装 Fail2ban 失败。将尝试从源代码安装。${NC}"
        fi
    fi

    # 回退到源代码安装
    echo -e "${YELLOW}尝试从源代码 ($FAIL2BAN_REPO) 安装 Fail2ban...${NC}"
    if ! command -v git &>/dev/null; then
        echo -e "${YELLOW}未安装 git。正在安装 git...${NC}"
        $INSTALL_CMD git || {
            echo -e "${RED}git 安装失败。无法从源代码安装 Fail2ban。${NC}"
            exit 1
        }
    fi

    if [ -d "fail2ban" ]; then
        echo -e "${YELLOW}克隆前删除现有的 'fail2ban' 目录...${NC}"
        rm -rf "fail2ban"
    fi

    echo -e "${YELLOW}克隆 Fail2ban 仓库: $FAIL2BAN_REPO${NC}"
    git clone --depth 1 "$FAIL2BAN_REPO" fail2ban || { # 浅克隆以提高速度
        echo -e "${RED}克隆 Fail2ban 仓库失败。${NC}"
        exit 1
    }
    cd fail2ban || {
        echo -e "${RED}进入 fail2ban 目录失败。${NC}"
        exit 1
    }

    echo -e "${YELLOW}运行 Fail2ban setup.py install...${NC}"
    python3 setup.py install || {
        echo -e "${RED}从源代码安装 Fail2ban 失败。${NC}"
        cd ..
        rm -rf fail2ban # 清理
        exit 1
    }
    touch /etc/fail2ban/py.installed # 标记为从源代码安装以进行服务设置
    cd ..
    # rm -rf fail2ban # 安装后可选择清理源代码目录

    echo -e "${GREEN}Fail2ban 从源代码成功安装。${NC}"
}

# 配置fail2ban
configure_fail2ban() {
    echo -e "${YELLOW}[8/10] 配置 Fail2ban...${NC}"
    local ssh_port
    ssh_port=$(awk '/^Port/ {print $2; exit}' /etc/ssh/sshd_config)
    ssh_port=${ssh_port:-22}

    local jail_local_path="/etc/fail2ban/jail.local"
    local log_path="/var/log/auth.log"     # Debian/Ubuntu 默认日志路径
    local fail2ban_action="$FIREWALL_TYPE" # 根据检测使用 "ufw" 或 "iptables"

    if [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
        log_path="/var/log/secure" # RHEL/CentOS/Fedora 日志路径
    fi

    # 如果使用 ufw，确保 action 是 ufw。Fail2ban 通常附带 ufw actions。
    # 例如：action = ufw-ssh-iptables 或类似。为简单起见，使用 'ufw'
    # 并依赖 fail2ban 的内部解析或通用的 ufw.conf。
    # 如果在 fail2ban 的配置中定义了，更具体的 action 可能是 %(action_ufw)s。
    # 我们将使用一个通用名称，并假设 fail2ban 的默认 action 配置会处理它。
    # 或者，如果我们知道确切的 action 名称，可以更明确。
    # 目前，将使用 `action = ufw` 或 `action = iptables`。
    # Fail2ban 的默认 jail.conf 通常有：
    # banaction = iptables-multiport
    # banaction_allports = iptables-allports
    # 对于 UFW，它可能是这样的：
    # banaction = ufw
    # 我们将直接在 jail.local 中设置 'action' 行。

    echo -e "${YELLOW}创建/更新 $jail_local_path...${NC}"
    # 如果 jail.local 不存在则创建，或者如果我们想确保我们的设置则覆盖
    # 对于此脚本，我们将覆盖以确保应用设置。
    # 如果保留用户更改很重要，请考虑备份现有的 jail.local。
    if [ -f "$jail_local_path" ]; then
        echo -e "${YELLOW}备份现有 $jail_local_path 到 ${jail_local_path}.bak-$(date +%s)${NC}"
        cp "$jail_local_path" "${jail_local_path}.bak-$(date +%s)"
    fi

    cat >"$jail_local_path" <<EOF
[DEFAULT]
# 忽略的IP、CIDR掩码或DNS主机的逗号分隔列表。
# 对于本地网络、VPN等很有用。
ignoreip = 127.0.0.1/8 ::1

# 默认封禁动作 (可以在jails中覆盖)
# 对于 UFW: ufw, ufw-new 等 (检查 /etc/fail2ban/action.d/)
# 对于 iptables: iptables-multiport, iptables-allports 等
# 我们根据 FIREWALL_TYPE 设置此项
banaction = ${fail2ban_action}
# 默认封禁时间、查找时间和最大重试次数
bantime  = 7d
findtime = 5m
maxretry = 5

[sshd]
enabled = true
port    = $ssh_port
# filter  = sshd # filter 通常默认为 sshd，除非自定义，否则无需指定
logpath = $log_path
maxretry = 3
bantime = 7d # SSH 的封禁时间更长
# 可选：增量封禁
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 8w

EOF
    echo -e "${GREEN}$jail_local_path 已配置。${NC}"

    # 服务管理
    echo -e "${YELLOW}确保 Fail2ban 服务已启用并启动...${NC}"
    if command -v systemctl &>/dev/null; then
        # 如果从源代码安装，服务文件可能需要手动设置。
        if [ -f /etc/fail2ban/py.installed ] && [ ! -f /usr/lib/systemd/system/fail2ban.service ] && [ ! -f /lib/systemd/system/fail2ban.service ]; then
            echo -e "${YELLOW}Fail2ban 从源代码安装，尝试复制服务文件...${NC}"
            if [ -d "fail2ban" ]; then # 检查源代码目录是否仍然存在
                if [ "$PKG_MANAGER" = "apt" ]; then
                    if [ -f "fail2ban/build/fail2ban.service" ]; then # 检查常见的构建路径
                        cp fail2ban/build/fail2ban.service /lib/systemd/system/fail2ban.service
                    elif [ -f "fail2ban/files/fail2ban.service" ]; then # 检查另一个常见路径
                        cp fail2ban/files/fail2ban.service /lib/systemd/system/fail2ban.service
                    fi
                elif [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
                    if [ -f "fail2ban/files/redhat-systemd/fail2ban.service" ]; then
                        cp fail2ban/files/redhat-systemd/fail2ban.service /usr/lib/systemd/system/
                    fi
                fi
                systemctl daemon-reload
            else
                echo -e "${YELLOW}未找到 Fail2ban 源代码目录 'fail2ban'。无法复制服务文件。可能需要手动设置。${NC}"
            fi
        fi
        systemctl enable fail2ban${SERVICE_SUFFIX}
        systemctl restart fail2ban${SERVICE_SUFFIX} || {
            echo -e "${RED}重启 fail2ban 服务失败。请使用 'systemctl status fail2ban' 和日志检查状态。${NC}"
            echo -e "${RED}同时检查 'fail2ban-client status' 和 'fail2ban-client status sshd'。${NC}"
            # 考虑不退出，以允许黑名单更新
        }
    elif command -v service &>/dev/null; then # 适用于没有 systemd 的旧系统
        if [ "$PKG_MANAGER" = "apt" ]; then
            update-rc.d fail2ban defaults
            service fail2ban restart
        else # 假设是旧版 RHEL/CentOS 的 chkconfig
            chkconfig fail2ban on
            service fail2ban restart
        fi
    else
        echo -e "${YELLOW}无法确定服务管理器。请手动管理 Fail2ban 服务。${NC}"
    fi
    echo -e "${GREEN}Fail2ban 服务已处理。${NC}"
}

# 添加恶意IP黑名单 (使用 ipset 和 iptables)
block_malicious_ips() {
    echo -e "${YELLOW}[9/10] 更新恶意IP黑名单 (ipsum)...${NC}"

    if ! command -v ipset &>/dev/null; then
        echo -e "${RED}未找到 ipset 命令。无法管理 ipsum 黑名单。请安装 ipset。${NC}"
        return 1
    fi
    if ! command -v iptables &>/dev/null && [ "$FIREWALL_TYPE" != "ufw" ]; then # 如果 ufw 是主要的，用户可能不会直接使用 iptables
        echo -e "${RED}未找到 iptables 命令。无法应用 ipsum 黑名单规则。${NC}"
        return 1
    elif ! command -v iptables &>/dev/null && [ "$FIREWALL_TYPE" == "ufw" ]; then
        echo -e "${YELLOW}未找到 iptables 命令，但 UFW 已激活。正在为 ipset 集成安装 iptables...${NC}"
        $INSTALL_CMD iptables || {
            echo -e "${RED}为 ipset 安装 iptables 失败。${NC}"
            return 1
        }
    fi

    # 如果 ipset 集合不存在则创建
    ipset create -exist ipsum hash:ip maxelem 1000000 # 增加 maxelem
    ipset flush ipsum                                 # 清空现有条目以刷新列表

    echo -e "${YELLOW}从以下地址下载 IP 黑名单: $IPSUM_URL${NC}"
    if curl --compressed -sL "$IPSUM_URL" -o /tmp/ipsum.txt; then
        echo -e "${GREEN}IP 黑名单下载成功。${NC}"
        # 处理并将 IP 添加到集合
        # awk: 不是注释行 (#)，并且评分 ($2) >= 3
        awk '!/^#/ && $2 >= 3 {print $1}' /tmp/ipsum.txt | while IFS= read -r ip; do
            # 验证 IP 格式 (简单检查)
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                ipset add ipsum "$ip" nomatch 2>/dev/null # 安静地添加
            fi
        done
        rm /tmp/ipsum.txt
        echo -e "${GREEN}IP 黑名单已处理并添加到 ipset 'ipsum'。数量: $(ipset list ipsum | wc -l)${NC}"
    else
        echo -e "${RED}从 $IPSUM_URL 下载恶意 IP 黑名单失败${NC}"
        return 1 # 如果下载失败则至关重要
    fi

    # 应用 iptables 规则以丢弃来自 'ipsum' 集合中 IP 的流量
    # 在添加之前检查规则是否已存在以避免重复
    if ! iptables -C INPUT -m set --match-set ipsum src -j DROP &>/dev/null; then
        echo -e "${YELLOW}添加 ipsum 黑名单的 iptables 规则...${NC}"
        iptables -I INPUT 1 -m set --match-set ipsum src -j DROP # 插入到 INPUT 链的顶部
    else
        echo -e "${GREEN}ipsum 黑名单的 iptables 规则已存在。${NC}"
    fi

    # 持久化 iptables 规则
    echo -e "${YELLOW}持久化防火墙规则...${NC}"
    if [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
        if command -v iptables-save &>/dev/null && [ -f /etc/sysconfig/iptables ]; then
            iptables-save >/etc/sysconfig/iptables
            echo -e "${GREEN}iptables 规则已为 RHEL/CentOS 系列保存。${NC}"
        elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
            echo -e "${YELLOW}Firewalld 已激活。ipset/iptables 规则可能需要通过 firewalld 直接规则进行管理以实现持久性。此脚本不会自动执行此操作。${NC}"
            echo -e "${YELLOW}目前，该规则处于活动状态，但如果 firewalld 覆盖 iptables，则可能无法在重新启动后保持。${NC}"
        else
            echo -e "${YELLOW}无法确定如何为 RHEL/CentOS 系列保存 iptables 规则。需要手动检查。${NC}"
        fi
    elif [ "$PKG_MANAGER" = "apt" ]; then
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
            netfilter-persistent start # 确保它处于活动状态
            echo -e "${GREEN}Netfilter 规则 (包括 ipset/iptables) 已通过 netfilter-persistent 为 Debian/Ubuntu 保存。${NC}"
        elif command -v iptables-save &>/dev/null; then # 如果 netfilter-persistent 不存在则回退
            iptables-save >/etc/iptables/rules.v4
            echo -e "${GREEN}iptables 规则已保存到 /etc/iptables/rules.v4 (Debian/Ubuntu)。${NC}"
        else
            echo -e "${YELLOW}未找到 netfilter-persistent。ipsum 的 iptables 规则在 Debian/Ubuntu 上重新启动后可能无法保持。${NC}"
        fi
    else
        echo -e "${YELLOW}不支持的包管理器用于 iptables 规则持久化。需要手动检查。${NC}"
    fi
}

# 配置定时任务
setup_cron_job() {
    echo -e "${YELLOW}[10/10] 设置每日黑名单更新的 cron 任务...${NC}"
    local update_script_path="/etc/fail2ban/update_ipset.sh"

    # 创建更新脚本
    cat >"$update_script_path" <<EOF
#!/bin/bash
LOGFILE="/var/log/ipset_update.log"
IPSUM_URL="$IPSUM_URL" # 使用主脚本中的变量
OS_ID_CRON="\$(. /etc/os-release && echo \$ID)" # 在 cron 脚本内部获取 OS_ID

echo "\$(date): 开始更新 IP 黑名单" >> \$LOGFILE

if ! command -v ipset &>/dev/null; then
    echo "\$(date): 未找到 ipset 命令。正在退出。" >> \$LOGFILE
    exit 1
fi
if ! command -v iptables &>/dev/null; then
    echo "\$(date): 未找到 iptables 命令。正在退出。" >> \$LOGFILE
    exit 1
fi
if ! command -v curl &>/dev/null; then
    echo "\$(date): 未找到 curl 命令。正在退出。" >> \$LOGFILE
    exit 1
fi


ipset create -exist ipsum hash:ip maxelem 1000000 # 确保集合存在，增加 maxelem
ipset flush ipsum >> \$LOGFILE 2>&1

echo "\$(date): 从 \$IPSUM_URL 下载黑名单" >> \$LOGFILE
if curl --compressed -sL "\$IPSUM_URL" -o /tmp/ipsum_cron.txt; then
    awk '!/^#/ && \$2 >= 3 {print \$1}' /tmp/ipsum_cron.txt | while IFS= read -r ip; do
        if [[ "\$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ipset add ipsum "\$ip" nomatch >> \$LOGFILE 2>&1
        fi
    done
    rm /tmp/ipsum_cron.txt
    echo "\$(date): IP 黑名单已处理。数量: \$(ipset list ipsum | wc -l)" >> \$LOGFILE
else
    echo "\$(date): 从 \$IPSUM_URL 下载 IP 黑名单失败" >> \$LOGFILE
    exit 1
fi

# 确保 iptables 规则存在 (如果不存在则插入)
if ! iptables -C INPUT -m set --match-set ipsum src -j DROP &>/dev/null; then
    iptables -I INPUT 1 -m set --match-set ipsum src -j DROP >> \$LOGFILE 2>&1
    echo "\$(date): 已添加 ipsum 的 iptables 规则。" >> \$LOGFILE
else
    echo "\$(date): ipsum 的 iptables 规则已存在。" >> \$LOGFILE
fi

# 持久化规则
echo "\$(date): 持久化防火墙规则..." >> \$LOGFILE
if [[ "\$OS_ID_CRON" =~ ^(centos|rhel|fedora|ol|rocky|almalinux)$ ]]; then
    if command -v iptables-save &>/dev/null && [ -f /etc/sysconfig/iptables ]; then
         iptables-save > /etc/sysconfig/iptables
         echo "\$(date): iptables 规则已为 RHEL 系列保存。" >> \$LOGFILE
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        echo "\$(date): Firewalld 已激活。规则持久性可能需要手动配置 firewalld。" >> \$LOGFILE
    else
        echo "\$(date): 无法为 RHEL 系列保存 iptables 规则。" >> \$LOGFILE
    fi
elif [[ "\$OS_ID_CRON" =~ ^(debian|ubuntu)$ ]]; then
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >> \$LOGFILE 2>&1
        echo "\$(date): Netfilter 规则已通过 netfilter-persistent 保存。" >> \$LOGFILE
    elif command -v iptables-save &>/dev/null; then # 如果 netfilter-persistent 不存在则回退
        iptables-save > /etc/iptables/rules.v4
        echo "\$(date): iptables 规则已保存到 /etc/iptables/rules.v4。" >> \$LOGFILE
    else
        echo "\$(date): 无法为 Debian/Ubuntu 保存 iptables 规则。" >> \$LOGFILE
    fi
else
    echo "\$(date): OS_ID \$OS_ID_CRON 未在 cron 中明确处理规则持久化。" >> \$LOGFILE
fi
echo "\$(date): IP 黑名单更新完成。" >> \$LOGFILE
EOF

    chmod +x "$update_script_path"

    # 添加/更新 cron 任务
    # 删除此脚本的现有任务以防止重复，然后添加新的任务
    (
        crontab -l 2>/dev/null | grep -v "$update_script_path"
        echo "0 3 * * * $update_script_path"
    ) | crontab -

    echo -e "${GREEN}Cron 任务已配置为每天凌晨3点更新 IP 黑名单。${NC}"
    echo -e "${GREEN}更新脚本: $update_script_path。日志: /var/log/ipset_update.log${NC}"
}

# 主执行流程
main() {
    check_root
    init_pkg_manager # 检测 PKG_MANAGER 和 FIREWALL_TYPE
    system_update
    setup_firewall # 根据 FIREWALL_TYPE 处理 UFW 或 iptables
    install_rsyslog
    configure_ssh
    install_dependencies # 包括 Python 检查
    install_fail2ban
    configure_fail2ban  # 使用 FIREWALL_TYPE 进行 action 配置
    block_malicious_ips # 直接使用 ipset 和 iptables
    setup_cron_job      # Cron 脚本也使用 ipset/iptables 并尝试持久化

    echo -e "${GREEN}\nFail2ban 安装和配置完成！${NC}"
    echo -e "${YELLOW}通常建议重新启动，或者至少验证所有服务是否正常运行。${NC}"
    echo -e "${YELLOW}查看 Fail2ban 日志: /var/log/fail2ban.log${NC}"
    echo -e "${YELLOW}检查 Fail2ban 状态: fail2ban-client status (以及 fail2ban-client status sshd)${NC}"
    if [ "$FIREWALL_TYPE" = "ufw" ]; then
        echo -e "${YELLOW}检查 UFW 状态: ufw status verbose${NC}"
    fi
    echo -e "${YELLOW}完整设置日志: $LOGFILE${NC}"
}

# 执行主程序
main
