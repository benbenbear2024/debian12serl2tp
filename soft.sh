#!/bin/bash
set -euo pipefail

# ==================== 配置区域 ====================
FIXED_PASSWORD="88888888"
SERVER_IP="10.0.10.254"
SERVER_GATEWAY="10.0.10.1"
VPN_CIDR="10.0.10.0/24"
LOG_FILE="/var/log/vpn_accel_install.log"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# 同步时间
echo "同步系统时间..."
timedatectl set-timezone Asia/Shanghai
timedatectl set-ntp true
systemctl restart systemd-timesyncd
sleep 12s
echo "时间同步完成"
echo "当前时间: $(date)"
echo ""

log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }
error() { log "${RED}错误: $1${NC}"; exit 1; }

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    error "请使用 root 权限运行此脚本"
fi

log "${GREEN}开始部署 VPN 服务 (accel-ppp PPTP + L2TP/IPsec) 固定IP分配...${NC}"

# ==================== 1. 安装依赖 ====================
log "安装系统依赖..."
apt update -qq
apt install -y wget build-essential gcc make git cmake net-tools nftables psmisc \
    libssl-dev libreadline-dev zlib1g-dev libpcre2-dev \
    libnl-3-dev libnl-genl-3-dev strongswan pptpd iptables-persistent

# ==================== 2. 配置静态 IP（只写配置，不立即应用）====================
log "配置服务器静态 IP: $SERVER_IP/24"
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$DEFAULT_IF" ]; then
    DEFAULT_IF=$(ls /sys/class/net | grep -E 'eth0|ens|eno' | head -n1)
fi
[ -z "$DEFAULT_IF" ] && error "无法检测到网卡"

# 备份原有配置
cp /etc/network/interfaces /etc/network/interfaces.bak 2>/dev/null || true

cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto $DEFAULT_IF
iface $DEFAULT_IF inet static
    address $SERVER_IP/24
    gateway $SERVER_GATEWAY
    dns-nameservers 8.8.8.8 1.1.1.1
EOF

log "静态 IP 配置已写入 /etc/network/interfaces，当前 IP 未改变（避免断开 SSH）"

# ==================== 3. 内核参数 ====================
log "启用 IP 转发并禁用反向路径过滤"
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl -p

# ==================== 4. 安装 accel-ppp ====================
log "安装 accel-ppp..."
cd /usr/local/src

# 清理已存在的目录
rm -rf /tmp/accel-ppp 2>/dev/null || true

# 尝试从 GitHub 直接克隆
ACCEL_PPP_URL="https://github.com/accel-ppp/accel-ppp.git"
CLONE_SUCCESS=false

echo "尝试从 GitHub 克隆 accel-ppp..."
git clone --depth=1 "$ACCEL_PPP_URL" /tmp/accel-ppp && CLONE_SUCCESS=true

# 如果克隆失败，尝试使用加速链接
if [ "$CLONE_SUCCESS" = false ]; then
    log "GitHub 克隆失败，尝试使用加速链接..."
    if [ -f "/tmp/debian-l2tp/github cdn.txt" ] || [ -f "github cdn.txt" ]; then
        CDN_FILE="github cdn.txt"
        [ -f "/tmp/debian-l2tp/github cdn.txt" ] && CDN_FILE="/tmp/debian-l2tp/github cdn.txt"
        # 只使用前 5 个加速链接
        head -n 5 "$CDN_FILE" | while IFS= read -r proxy; do
            if [ -n "$proxy" ]; then
                log "尝试加速链接: $proxy"
                git clone --depth=1 "${proxy}${ACCEL_PPP_URL}" /tmp/accel-ppp && CLONE_SUCCESS=true && break
            fi
        done
    fi
fi

[ ! -d "/tmp/accel-ppp" ] && error "无法下载 accel-ppp 源码"

# 编译并安装
log "编译 accel-ppp..."
cd /tmp/accel-ppp
mkdir -p build && cd build
cmake -DBUILD_DRIVER=TRUE -DRADIUS=FALSE ..
make -j$(nproc) || error "编译 accel-ppp 失败"
make install || error "安装 accel-ppp 失败"

# 创建日志目录
mkdir -p /var/log/accel-ppp
chown nobody:nogroup /var/log/accel-ppp

# 创建 systemd 服务
cat > /etc/systemd/system/accel-ppp.service << 'EOF'
[Unit]
Description=Accel-PPP VPN Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/accel-pppd -c /usr/local/etc/accel-ppp/accel-ppp.conf
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable accel-ppp

# ==================== 5. 配置 accel-ppp ====================
log "配置 accel-ppp..."
mkdir -p /usr/local/etc/accel-ppp

cat > /usr/local/etc/accel-ppp/accel-ppp.conf << EOF
[modules]
log_syslog
pptp
l2tp
auth_mschap_v2

[core]
thread-count=4

[ppp]
verbose=1
auth=mschapv2
mppe=require
lcp-echo-interval=30
lcp-echo-failure=3

[pptp]
enable=1
ip-range=10.0.10.2-10.0.10.201
local-ip=$SERVER_IP

[l2tp]
enable=1
ip-range=10.0.10.2-10.0.10.201
local-ip=$SERVER_IP

[dns]
server=8.8.8.8
server=1.1.1.1

[chap-secrets]
file=/etc/ppp/chap-secrets
EOF

# ==================== 6. 生成用户账号和固定 IP 分配配置 ====================
log "生成用户账号和固定 IP 分配配置..."

# 清空原有文件
> /etc/ppp/chap-secrets

# 批量生成账号密码+固定IP
# user1 -> 10.0.10.2, user2 -> 10.0.10.3, ..., user200 -> 10.0.10.201
for i in $(seq 1 200); do
    echo "user$i * $FIXED_PASSWORD 10.0.10.$((i+1))" >> /etc/ppp/chap-secrets
done

chmod 600 /etc/ppp/chap-secrets

log "用户账号生成完成，验证前 10 个用户："
head -11 /etc/ppp/chap-secrets | tail -10

USER_COUNT=$(grep -c "^user" /etc/ppp/chap-secrets 2>/dev/null || echo "0")
log "共生成 $USER_COUNT 个用户账号"

# ==================== 7. 安装并配置 strongSwan（IPsec 支持）====================
log "安装并配置 strongSwan（IPsec 支持）..."

# 配置 IPsec
cat > /etc/ipsec.conf << EOF
config setup
    charondebug="ike 2, knl 2, cfg 2"
    uniqueids=no

conn l2tp
    keyexchange=ikev1
    ike=aes128-sha1-modp2048,aes128-sha1-modp1024
    esp=aes128-sha1
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/1701
    authby=secret
    auto=add
EOF

# 配置预共享密钥
cat > /etc/ipsec.secrets << EOF
%any %any : PSK "$FIXED_PASSWORD"
EOF

chmod 600 /etc/ipsec.secrets

# 启动并启用 strongSwan 服务
systemctl enable strongswan-starter
systemctl restart strongswan-starter
sleep 2
systemctl status strongswan-starter --no-pager | grep -q "active (running)" || log "警告：strongSwan 未正常运行"

# ==================== 8. 启动 accel-ppp 服务 =====================
log "启动 accel-ppp 服务..."
systemctl start accel-ppp
sleep 3
systemctl status accel-ppp --no-pager | grep -q "active (running)" || {
    log "警告：accel-ppp 启动异常，检查日志..."
    journalctl -u accel-ppp -n 20 --no-pager 2>&1 | tail -15
}

# ==================== 9. 配置防火墙 (nftables) ====================
log "配置 nftables 防火墙..."

# 加载内核模块
modprobe nf_nat 2>/dev/null || true
modprobe ip_gre 2>/dev/null || true
modprobe esp4 2>/dev/null || true

# 清空并重建规则集
nft flush ruleset 2>/dev/null || true

# NAT 表（IP 伪装）
nft add table nat
nft add chain nat postrouting '{ type nat hook postrouting priority 100; }'
nft add rule nat postrouting ip saddr $VPN_CIDR masquerade

# Filter 表（防火墙）
nft add table inet filter
nft add chain inet filter input '{ type filter hook input priority 0; policy drop; }'
nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'

# 基本允许规则
nft add rule inet filter input ct state established,related accept
nft add rule inet filter input iif lo accept

# 管理端口
nft add rule inet filter input tcp dport 22 accept

# PPTP
nft add rule inet filter input tcp dport 1723 accept
nft add rule inet filter input ip protocol gre accept

# L2TP/IPsec
nft add rule inet filter input udp dport 500 accept
nft add rule inet filter input udp dport 4500 accept
nft add rule inet filter input udp dport 1701 accept
nft add rule inet filter input ip protocol esp accept

# ICMP (ping)
nft add rule inet filter input icmp type echo-request accept

# 常用端口
nft add rule inet filter input tcp dport 80 accept
nft add rule inet filter input tcp dport 443 accept
nft add rule inet filter input tcp dport 3389 accept

# 保存规则
nft list ruleset > /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

# ==================== 10. 生成 Windows 修复脚本 ====================
cat > /root/Windows-VPN-Fix.bat << 'WINEOF'
@echo off
echo 修复 Windows VPN 连接问题（请以管理员身份运行）
sc config RasMan start= auto
sc start RasMan
sc config RemoteAccess start= auto
sc start RemoteAccess
sc config PolicyAgent start= auto
sc start PolicyAgent
reg add "HKLM\SYSTEM\CurrentControlSet\Services\PolicyAgent" /v AssumeUDPEncapsulationContextOnSendRule /t REG_DWORD /d 2 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Services\RasMan\Parameters" /v ProhibitIpSec /t REG_DWORD /d 0 /f
netsh winsock reset
netsh int ip reset
echo 修复完成，请重启电脑后测试 VPN
pause
WINEOF

# ==================== 11. 完成输出 ====================
log "${GREEN}所有组件部署完成！${NC}"
cat << EOF
==========================================
✅ VPN 服务部署成功 (accel-ppp PPTP + L2TP/IPsec)
==========================================
服务器 IP: $SERVER_IP (当前可能未生效，需要重启)
网关: $SERVER_GATEWAY
用户名: user1 ~ user200
密码: $FIXED_PASSWORD

📌 PPTP 连接：
   服务器地址: $SERVER_IP
   用户名: userN (如 user1, user50, user200)
   密码: $FIXED_PASSWORD
   固定IP: user1→10.0.10.2, user2→10.0.10.3, …, user200→10.0.10.201

📌 L2TP/IPsec 连接：
   服务器地址: $SERVER_IP
   预共享密钥(PSK): $FIXED_PASSWORD
   用户名: userN (如 user1, user50, user200)
   密码: $FIXED_PASSWORD
   固定IP: user1→10.0.10.2, user2→10.0.10.3, …, user200→10.0.10.201

📌 放行端口:
   PPTP: TCP 1723 + GRE
   L2TP/IPsec: UDP 500, 4500, 1701 + ESP

📌 Windows 修复脚本: /root/Windows-VPN-Fix.bat
   (下载到 Windows 以管理员运行并重启)

📌 日志查看:
   accel-ppp: journalctl -u accel-ppp -f
   strongSwan: journalctl -u strongswan-starter -f
==========================================
⚠️ 重要提示：
   1. 服务器 IP 配置文件已更新为 $SERVER_IP，但当前会话仍使用旧 IP。
   2. 请手动重启服务器（执行 reboot）以使新 IP 生效。
   3. 如果当前 SSH 连接 IP 不是 $SERVER_IP，重启后请使用新 IP 连接。
==========================================
EOF

log "安装结束。请手动执行 reboot 重启服务器使所有配置生效。"
