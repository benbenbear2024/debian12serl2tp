#!/bin/sh
# Debian 12.13 — PPTP + L2TP
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FILES="$SCRIPT_DIR/files"
CHAP="/etc/ppp/chap-secrets"

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行: sudo bash $0"
  exit 1
fi
# 同步时间
echo "同步系统时间..."
timedatectl set-timezone Asia/Shanghai
timedatectl set-ntp true
systemctl restart systemd-timesyncd
echo "时间同步完成"
echo "当前时间: $(date)"
echo ""

echo "请输入服务器 IP 地址（默认: 10.0.10.254）:"
read -p "服务器 IP 地址: " SERVER_IP
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="10.0.10.254"
  echo "使用默认服务器 IP 地址: $SERVER_IP"
else
  echo "使用用户指定的服务器 IP 地址: $SERVER_IP"
fi

echo "\n是否安装防火墙规则？"
echo "1. 是（推荐）"
echo "2. 否"
read -p "请选择 (1/2): " FIREWALL_CHOICE
if [ -z "$FIREWALL_CHOICE" ] || [ "$FIREWALL_CHOICE" != "2" ]; then
  FIREWALL_INSTALL="yes"
  echo "将安装防火墙规则"
else
  FIREWALL_INSTALL="no"
  echo "将不安装防火墙规则"
fi

echo "\n是否开启 VPN 服务进程守护？"
echo "1. 是（推荐）"
echo "2. 否"
read -p "请选择 (1/2): " DAEMON_CHOICE
if [ -z "$DAEMON_CHOICE" ] || [ "$DAEMON_CHOICE" != "2" ]; then
  DAEMON_INSTALL="yes"
  echo "将开启进程守护"
  echo "\n请设置进程守护检查时间（单位：秒）"
  echo "建议范围: 30-3600 秒，默认: 300 秒"
  read -p "检查时间 (30-3600): " DAEMON_INTERVAL
  if [ -z "$DAEMON_INTERVAL" ]; then
    DAEMON_INTERVAL=300
    echo "使用默认检查时间: $DAEMON_INTERVAL 秒"
  elif ! echo "$DAEMON_INTERVAL" | grep -qE '^[0-9]+$'; then
    echo "输入无效，使用默认检查时间: 300 秒"
    DAEMON_INTERVAL=300
  elif [ "$DAEMON_INTERVAL" -lt 30 ] || [ "$DAEMON_INTERVAL" -gt 3600 ]; then
    echo "输入超出范围，使用默认检查时间: 300 秒"
    DAEMON_INTERVAL=300
  else
    echo "使用用户指定的检查时间: $DAEMON_INTERVAL 秒"
  fi
else
  DAEMON_INSTALL="no"
  echo "将不开启进程守护"
fi

echo "\n是否安装 mihomo 代理服务？"
echo "1. 是（默认）"
echo "2. 否"
read -p "请选择 (1/2): " MIHOMO_CHOICE
if [ -z "$MIHOMO_CHOICE" ] || [ "$MIHOMO_CHOICE" != "2" ]; then
  INSTALL_MIHOMO="yes"
  echo "将安装 mihomo"
else
  INSTALL_MIHOMO="no"
  echo "将不安装 mihomo"
fi

if [ -z "${VPN_SERVER_ID:-}" ]; then
  export VPN_SERVER_ID="$SERVER_IP"
  echo "未设置 VPN_SERVER_ID，使用服务器 IP 地址: $VPN_SERVER_ID"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y pptpd ppp iptables openssl xl2tpd strongswan

echo "安装必要的工具包..."
apt-get install -y net-tools iptables-persistent

# 安装 accel-ppp
echo "安装 accel-ppp..."
# 安装编译依赖
apt-get install -y build-essential git cmake libpcre2-dev libssl-dev liblua5.2-dev libcurl4-openssl-dev

# 克隆 accel-ppp 源码
echo "克隆 accel-ppp 源码..."
# 清理已存在的目录
if [ -d "/tmp/accel-ppp" ]; then
  echo "清理已存在的 accel-ppp 目录..."
  rm -rf /tmp/accel-ppp
fi
git clone https://github.com/accel-ppp/accel-ppp.git /tmp/accel-ppp

# 编译并安装
echo "编译 accel-ppp..."
cd /tmp/accel-ppp
mkdir -p build
cd build
cmake .. -DBUILD_IPOE_DRIVER=OFF -DBUILD_VLAN_MON_DRIVER=OFF
make -j$(nproc)
echo "安装 accel-ppp..."
make install

# 创建系统服务
echo "创建 accel-ppp 系统服务..."
cat > /etc/systemd/system/accel-ppp.service << 'EOF'
[Unit]
Description=Accel-PPP
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/accel-pppd -c /usr/local/etc/accel-ppp/accel-ppp.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 启用服务
systemctl daemon-reload
systemctl enable accel-ppp

# 配置 accel-ppp
echo "配置 accel-ppp..."
mkdir -p /usr/local/etc/accel-ppp
cat > /usr/local/etc/accel-ppp/accel-ppp.conf << 'EOF'
[modules]
log_syslog
pptp
l2tp
ipoe
auth_mschap_v2

[core]
log-error=/var/log/accel-ppp/core.log
thread-count=4

[ppp]
verbose=1
auth=chap,mschapv2
mppe=require
check-ip=1
lcp-echo-interval=30
lcp-echo-failure=3

[ipoe]
enable=0

[pptp]
enable=1
ip-range=10.0.10.1-10.0.10.200
local-ip=10.0.10.254

[l2tp]
enable=1
ip-range=10.0.10.1-10.0.10.200
local-ip=10.0.10.254

[auth]
mschap-v2=1

[client-ip-range]
10.0.10.1-10.0.10.200

[log]
syslog=accel-ppp
level=3

[dns]
8.8.8.8
1.1.1.1
EOF

# 生成用户账号和静态 IP 分配配置
echo "生成用户账号和静态 IP 分配配置..."
mkdir -p /usr/local/etc/accel-ppp

# 生成 chap-secrets 文件
umask 077
{
  echo '# CHAP secrets — PPTP / L2TP 账号相同'
  echo '# client  server  secret  IP'
  for i in $(seq 1 200); do
    ip=10.0.10.$i
    echo "user$i * 88888888 $ip"
  done
} > "$CHAP.new"
mv "$CHAP.new" "$CHAP"
chmod 600 "$CHAP"
echo "用户账号生成完成"
echo "查看前 10 个用户账号:"
head -n 10 "$CHAP"

# 生成静态 IP 分配配置
cat > /usr/local/etc/accel-ppp/ip.cfg << 'EOF'
# 静态 IP 分配配置
# 格式: username IP_address
EOF

# 生成 user1-200 对应的静态 IP
for i in $(seq 1 200); do
  ip=10.0.10.$i
  echo "user$i $ip" >> /usr/local/etc/accel-ppp/ip.cfg
done

echo "静态 IP 分配配置生成完成"
echo "查看前 10 个静态 IP 配置:"
head -n 10 /usr/local/etc/accel-ppp/ip.cfg

# 修改 accel-ppp 配置，添加静态 IP 分配
echo "更新 accel-ppp 配置，添加静态 IP 分配..."
cat >> /usr/local/etc/accel-ppp/accel-ppp.conf << 'EOF'

[ip-config]
mode=file
file=/usr/local/etc/accel-ppp/ip.cfg

[chap-secrets]
file=/etc/ppp/chap-secrets
EOF

# 启动并启用 accel-ppp 服务
echo "启动 accel-ppp 服务..."
systemctl enable accel-ppp
systemctl start accel-ppp
systemctl status accel-ppp --no-pager

echo "accel-ppp 安装配置完成"

echo "配置 DNS 服务器..."
cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# 启用并重启 SoftEther VPN 服务...
echo "启用并重启 SoftEther VPN 服务..."
systemctl enable softether-vpnserver || echo "警告：softether-vpnserver 服务启用失败"
systemctl restart softether-vpnserver || echo "警告：softether-vpnserver 服务重启失败"
systemctl status softether-vpnserver --no-pager

echo "已设置 SoftEther VPN 服务开机自动启动"

echo "检查 VPN 相关端口状态..."
netstat -tuln | grep -E '1723|1701|500|4500|443|5555'

echo "检查 IP 转发状态..."
IP_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
if [ "$IP_FORWARD" -ne 1 ]; then
  echo "IP 转发未启用，正在启用..."
  echo 1 > /proc/sys/net/ipv4/ip_forward
  if grep -q "net.ipv4.ip_forward" /etc/sysctl.conf; then
    sed -i 's/net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  else
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  fi
  sysctl -p
  echo "IP 转发已启用"
else
  echo "IP 转发已启用"
fi

if [ "$FIREWALL_INSTALL" = "yes" ]; then
  echo "检查防火墙规则..."
  
  if ! command -v iptables > /dev/null; then
    echo "iptables 未安装，正在安装..."
    apt-get install -y iptables iptables-persistent
  else
    echo "iptables 已安装"
  fi
  
  echo "检查 iptables 服务状态..."
  if systemctl is-active --quiet iptables; then
    echo "iptables 服务已启动"
  else
    echo "iptables 服务未启动，正在启动..."
    systemctl start iptables 2>/dev/null || {
      echo "警告：无法启动 iptables 服务，可能是因为系统使用的是 nftables 或其他防火墙后端"
      echo "继续配置防火墙规则..."
    }
  fi

  echo "检查系统防火墙状态..."
  FIREWALL_STATUS=0
  if command -v ufw > /dev/null; then
    echo "发现 UFW 防火墙"
    FIREWALL_STATUS=1
  fi
  if command -v firewalld > /dev/null; then
    echo "发现 firewalld 防火墙"
    FIREWALL_STATUS=1
  fi

  if [ "$FIREWALL_STATUS" -eq 1 ]; then
    echo "警告：系统已安装其他防火墙，请确保 VPN 相关端口已开放"
  fi

  echo "配置防火墙规则..."
  iptables -F
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  iptables -A INPUT -p gre -j ACCEPT
  iptables -A INPUT -p tcp --dport 1723 -j ACCEPT
  iptables -A INPUT -p udp --dport 1701 -j ACCEPT
  iptables -A INPUT -p udp --dport 500 -j ACCEPT
  iptables -A INPUT -p udp --dport 4500 -j ACCEPT

  iptables -A INPUT -p tcp --dport 7890 -j ACCEPT
  iptables -A INPUT -p tcp --dport 7891 -j ACCEPT
  iptables -A INPUT -p tcp --dport 7892 -j ACCEPT
  iptables -A INPUT -p tcp --dport 9090 -j ACCEPT
  iptables -A INPUT -p tcp --dport 9999 -j ACCEPT

  iptables -A INPUT -p tcp --dport 22 -j ACCEPT
  iptables -A INPUT -p tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp --dport 443 -j ACCEPT
  iptables -A INPUT -p tcp --dport 21 -j ACCEPT
  iptables -A INPUT -p tcp --dport 25 -j ACCEPT
  iptables -A INPUT -p tcp --dport 110 -j ACCEPT
  iptables -A INPUT -p tcp --dport 143 -j ACCEPT
  iptables -A INPUT -p udp --dport 53 -j ACCEPT
  iptables -A INPUT -p tcp --dport 3389 -j ACCEPT

  
  iptables -I FORWARD 1 -d 10.0.10.254 -j ACCEPT
  iptables -A FORWARD -s 10.0.10.0/24 -d 10.0.10.0/24 -j DROP


  WAN_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  if [ -n "$WAN_IF" ]; then
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
    echo "已添加 NAT 转发规则（出口网卡: $WAN_IF）"
  fi

  echo "保存防火墙规则..."
  iptables-save > /etc/iptables/rules.v4
  iptables-restore < /etc/iptables/rules.v4
  echo "防火墙规则已立即生效"
else
  echo "跳过防火墙规则配置"
  echo "添加 noipx 选项到 PPTP 配置..."
  echo "noipx" >> /etc/ppp/options.pptpd
  echo "添加 noipx 选项到 L2TP 配置..."
  echo "noipx" >> /etc/ppp/options.xl2tpd
  echo "已添加 noipx 选项，禁止 VPN 客户端之间的 IPX 协议通信"
fi

if [ "$DAEMON_INSTALL" = "yes" ]; then
  echo "创建 VPN 服务守护脚本..."
  cat > /usr/local/bin/vpn-daemon.sh << 'EOF'
#!/bin/bash
if ! systemctl is-active --quiet accel-ppp; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - accel-ppp 服务未运行，正在启动..." >> /var/log/vpn-daemon.log
  systemctl start accel-ppp
  if systemctl is-active --quiet accel-ppp; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - accel-ppp 服务启动成功" >> /var/log/vpn-daemon.log
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - accel-ppp 服务启动失败" >> /var/log/vpn-daemon.log
  fi
fi
EOF

  chmod +x /usr/local/bin/vpn-daemon.sh
  echo "VPN 服务守护脚本已创建: /usr/local/bin/vpn-daemon.sh"

  DAEMON_MINUTES=$((DAEMON_INTERVAL / 60))
  echo "添加 cron 任务，每 $DAEMON_INTERVAL 秒（$DAEMON_MINUTES 分钟）检查一次 VPN 服务状态..."
  if ! crontab -l 2>/dev/null | grep -q "vpn-daemon.sh"; then
    (crontab -l 2>/dev/null; echo "*/$DAEMON_MINUTES * * * * /usr/local/bin/vpn-daemon.sh") | crontab -
    echo "cron 任务已添加，每 $DAEMON_MINUTES 分钟执行一次 VPN 服务守护脚本"
  else
    echo "cron 任务已存在，跳过添加"
  fi

  systemctl enable cron 2>/dev/null || true
  systemctl start cron 2>/dev/null || true
  echo "cron 服务已启动"
else
  echo "跳过进程守护配置"
fi

if [ "$INSTALL_MIHOMO" = "yes" ]; then
  echo "\n=== 开始安装 mihomo ==="
  if [ -f "$SCRIPT_DIR/install-mihomo.sh" ]; then
    chmod +x "$SCRIPT_DIR/install-mihomo.sh"
    bash "$SCRIPT_DIR/install-mihomo.sh"
  else
    echo "错误: 未找到 install-mihomo.sh 脚本"
  fi
fi

echo "配置服务器网络地址为 $SERVER_IP..."
cp /etc/network/interfaces /etc/network/interfaces.bak 2>/dev/null || true
echo "已备份原有网络配置文件"
echo "获取默认网络接口..."
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
echo "默认网络接口: $DEFAULT_IF"
if [ -z "$DEFAULT_IF" ]; then
  DEFAULT_IF="ens18"
  echo "未找到默认网络接口，使用默认值: $DEFAULT_IF"
fi
echo "创建新的网络配置文件..."
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto $DEFAULT_IF
iface $DEFAULT_IF inet static
    address $SERVER_IP/24
    gateway 10.0.10.1
    dns-nameservers 8.8.8.8 1.1.1.1
EOF
echo "网络配置文件已创建，内容如下:"
cat /etc/network/interfaces

echo "\n网络配置已更新，需要重启网络服务使配置生效。"
echo "重启网络服务可能会导致网络连接暂时中断。"
echo "1. 立即重启网络服务（默认）"
echo "2. 稍后手动执行网络重启 systemctl restart networking"
read -p "请选择 (1/2): " RESTART_CHOICE
if [ -z "$RESTART_CHOICE" ] || [ "$RESTART_CHOICE" != "2" ]; then
  echo "重启网络服务..."
  systemctl restart networking || {
    echo "警告：网络服务重启失败，请手动重启网络接口"
    echo "尝试使用 ifdown/ifup 命令重启网络接口..."
    ifdown $DEFAULT_IF && ifup $DEFAULT_IF || echo "ifdown/ifup 命令执行失败"
  }
  echo "检查网络配置是否生效..."
  ip addr show $DEFAULT_IF
else
  echo "\n网络服务未重启，配置将在下次系统启动或手动重启网络服务后生效。"
  echo "手动重启网络服务的命令："
  echo "  systemctl restart networking"
  echo "  或"
  echo "  ifdown $DEFAULT_IF && ifup $DEFAULT_IF"
  echo "\n检查网络配置的命令："
  echo "  ip addr show $DEFAULT_IF"
fi

echo "\n=== IP 地址更改提示 ==="
echo "服务器 IP 地址已更改为: $SERVER_IP"
echo "请使用新的 IP 地址连接 VPN 服务"
echo "=======================\n"

echo "等待网络连接稳定..."
sleep 3

echo "检查网络状态..."
ip addr show $DEFAULT_IF

cat << EOF

=== 安装完成 ===
账号: user1 ~ user200  密码: 88888888

地址池:
  PPTP/L2TP: 10.0.10.1 - 10.0.10.200（服务器端 10.0.10.254）

服务端身份: $VPN_SERVER_ID
  Windows「服务器地址」必须与设置一致（同一域名或同一 IP）。

Windows 添加 VPN:
  • PPTP 连接:
    - 类型: PPTP
    - 服务器: $VPN_SERVER_ID
    - 登录信息类型: 用户名和密码
    - 用户名/密码: userN / 88888888
  
  • L2TP 连接:
    - 类型: L2TP/IPsec 预共享密钥
    - 服务器: $VPN_SERVER_ID
    - 预共享密钥: 88888888
    - 登录信息类型: 用户名和密码
    - 用户名/密码: userN / 88888888

放行端口:
  - VPN 相关: PPTP (TCP 1723 + GRE)、L2TP (UDP 1701)、IPsec (UDP 500, 4500)
  - 常用协议: SSH (TCP 22)、HTTP (TCP 80)、HTTPS (TCP 443)、FTP (TCP 21)、SMTP (TCP 25)、POP3 (TCP 110)、IMAP (TCP 143)、DNS (UDP 53)、RDP (TCP 3389)
  - 其他: TCP 7890, 7891, 7892, 9090, 9999

日志查看:
  - accel-ppp: journalctl -u accel-ppp -f
  - accel-ppp 详细日志: /var/log/accel-ppp/
EOF

if [ "$INSTALL_MIHOMO" = "yes" ]; then
  cat << EOF

Mihomo 信息:
  - 配置文件: /etc/mihomo/config.yaml
  - 控制面板: http://127.0.0.1:9090
  - 代理端口: 7890 (HTTP/SOCKS5)
  - 服务管理: systemctl start/stop/restart mihomo
  - 查看状态: systemctl status mihomo
  - 查看日志: journalctl -u mihomo -f
EOF
fi
