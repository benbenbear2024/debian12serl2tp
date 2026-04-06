#!/bin/bash
set -euo pipefail

# ==================== 配置区域 ====================
FIXED_PASSWORD="88888888"
SERVER_IP="10.0.10.254"
SERVER_GATEWAY="10.0.10.1"
VPN_CIDR="10.0.10.0/24"
LOG_FILE="/var/log/vpn_dual_install.log"

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

log "${GREEN}开始部署双 VPN 服务 (SoftEther L2TP/IPsec + pptpd PPTP) 并启用固定IP分配及跨协议互踢...${NC}"

# ==================== 1. 安装依赖 ====================
log "安装系统依赖..."
apt update -qq
apt install -y wget build-essential gcc make net-tools nftables pptpd psmisc \
    libssl-dev libreadline-dev zlib1g-dev

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
log "请在所有安装完成后手动重启服务器，或执行: systemctl restart networking"

# ==================== 3. 内核参数 ====================
log "启用 IP 转发并禁用反向路径过滤"
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl -p

# ==================== 4. 安装 SoftEther VPN ====================
log "安装 SoftEther VPN Server"
cd /usr/local/src

SOFTETHER_LOCAL="/root/softether-vpnserver-v4.43-9799-beta-2023.08.31-linux-x64-64bit.tar.gz"
SOFTETHER_URL="https://www.softether-download.com/files/softether/v4.43-9799-beta-2023.08.31-tree/Linux/SoftEther_VPN_Server/64bit_-_Intel_x64_or_AMD64/softether-vpnserver-v4.43-9799-beta-2023.08.31-linux-x64-64bit.tar.gz"

if [ -f "$SOFTETHER_LOCAL" ]; then
    log "发现本地 SoftEther 安装包，使用本地文件..."
    cp "$SOFTETHER_LOCAL" softether.tar.gz
else
    log "本地未找到 SoftEther 安装包，从网上下载..."
    wget --no-check-certificate -O softether.tar.gz "$SOFTETHER_URL" || error "下载 SoftEther 失败"
fi

tar xzf softether.tar.gz
cd vpnserver
echo -e "1\n1\n" | make || error "编译 SoftEther 失败"
mkdir -p /usr/local/vpnserver
cp -r * /usr/local/vpnserver/
cd /usr/local/vpnserver
chmod 600 *
chmod 700 vpnserver vpncmd

# 创建 systemd 服务
cat > /etc/systemd/system/vpnserver.service << 'EOF'
[Unit]
Description=SoftEther VPN Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/vpnserver/vpnserver start
ExecStop=/usr/local/vpnserver/vpnserver stop
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vpnserver
systemctl start vpnserver || error "SoftEther 服务启动失败"
sleep 2
systemctl status vpnserver --no-pager | grep -q "active (running)" || error "SoftEther 未正常运行"

# ==================== 5. 配置 SoftEther (L2TP/IPsec + 动态IP池) ====================
log "配置 SoftEther: L2TP/IPsec，启用 SecureNAT，动态 IP 池 10.0.10.202-254"

# 配置 IPsec，启用 SecureNAT 并设置 DHCP 池（动态分配）
cat > /tmp/se_cfg.txt << EOF
Hub DEFAULT
IPsecEnable /L2TP:yes /L2TPRAW:yes /ETHERIP:no /PSK:$FIXED_PASSWORD /DEFAULTHUB:DEFAULT
SetHub /AuthType:0
SecureNATEnable
DhcpSet /START:10.0.10.202 /END:10.0.10.254 /MASK:255.255.255.0 /EXPIRE:7200 /GW:$SERVER_IP /DNS:8.8.8.8 /DNS2:1.1.1.1
EOF

/usr/local/vpnserver/vpncmd localhost /SERVER < /tmp/se_cfg.txt || log "SoftEther 基础配置有警告，继续"

# 创建200个用户并设置密码（无需静态 IP）
log "创建用户并设置密码（仅用于 L2TP 认证，IP 动态分配）..."
for i in $(seq 1 200); do
    # 删除可能存在的旧用户（忽略错误）
    echo -e "Hub DEFAULT\nUserDelete user$i" | /usr/local/vpnserver/vpncmd localhost /SERVER > /dev/null 2>&1 || true
    # 创建新用户
    echo -e "Hub DEFAULT\nUserCreate user$i /GROUP:none /REALNAME:none /NOTE:none" | \
        /usr/local/vpnserver/vpncmd localhost /SERVER > /dev/null 2>&1 || true
    # 设置密码
    echo -e "Hub DEFAULT\nUserPasswordSet user$i /PASSWORD:$FIXED_PASSWORD" | \
        /usr/local/vpnserver/vpncmd localhost /SERVER > /dev/null 2>&1 || true
done

log "SoftEther 配置完成，用户将获得动态 IP (10.0.10.202-254)"
systemctl restart vpnserver

# ==================== 6. 配置 pptpd (PPTP + 固定IP) ====================
log "配置 pptpd"
cat > /etc/pptpd.conf << EOF
option /etc/ppp/pptpd-options
logwtmp
localip $SERVER_IP
remoteip 10.0.10.2-201
EOF

# 配置 DNS，并确保没有 maxconn 行
sed -i 's/#ms-dns/ms-dns/g' /etc/ppp/pptpd-options
sed -i 's/ms-dns 10.0.0.1/ms-dns 8.8.8.8\nms-dns 1.1.1.1/' /etc/ppp/pptpd-options
sed -i '/^maxconn/d' /etc/ppp/pptpd-options
# 确保服务器名称为 pptpd
grep -q "^name pptpd" /etc/ppp/pptpd-options || echo "name pptpd" >> /etc/ppp/pptpd-options

# 生成 chap-secrets 文件（固定 IP）
log "生成 PPTP 用户账号（固定 IP 分配）..."
cat > /etc/ppp/chap-secrets << 'EOF'
# Secrets for authentication using CHAP
# client    server    secret    IP addresses
EOF

for i in $(seq 1 200); do
    IP_ADDR="10.0.10.$((i+1))"
    echo "user$i pptpd $FIXED_PASSWORD $IP_ADDR" >> /etc/ppp/chap-secrets
done
chmod 600 /etc/ppp/chap-secrets

log "PPTP 用户生成完成，验证前 5 个用户："
head -8 /etc/ppp/chap-secrets | tail -5

systemctl enable pptpd
systemctl restart pptpd || error "pptpd 启动失败"
systemctl status pptpd --no-pager | grep -q "active (running)" || error "pptpd 未正常运行"

# ==================== 7. 创建跨协议互踢脚本 ====================
log "创建会话控制脚本"

cat > /usr/local/bin/check_softether_session.sh << 'SCRIPT'
#!/bin/bash
USERNAME="$1"
/usr/local/vpnserver/vpncmd localhost /SERVER /CMD "Hub DEFAULT" SessionList 2>/dev/null | grep -q "| $USERNAME |"
exit $?
SCRIPT
chmod +x /usr/local/bin/check_softether_session.sh

cat > /usr/local/bin/kill_pptp_user.sh << 'SCRIPT'
#!/bin/bash
USERNAME="$1"
pid=$(ps aux | grep "pppd call pptpd" | grep "name $USERNAME" | awk '{print $2}')
if [ -n "$pid" ]; then
    kill -9 $pid
    echo "$(date) - Killed PPTP session for $USERNAME" >> /var/log/vpn_session_control.log
fi
SCRIPT
chmod +x /usr/local/bin/kill_pptp_user.sh

mkdir -p /etc/ppp/ip-up.d
cat > /etc/ppp/ip-up.d/90-check-softether << 'SCRIPT'
#!/bin/bash
USERNAME="$6"
if [ -z "$USERNAME" ]; then exit 0; fi
if /usr/local/bin/check_softether_session.sh "$USERNAME"; then
    logger "PPTP: User $USERNAME already in SoftEther, disconnecting current PPTP"
    kill -9 $PPPD_PID
fi
SCRIPT
chmod +x /etc/ppp/ip-up.d/90-check-softether

cat > /usr/local/bin/softether_onconnect.sh << 'SCRIPT'
#!/bin/bash
USERNAME="$1"
echo "$(date) - L2TP user $USERNAME connected, killing PPTP sessions" >> /var/log/vpn_session_control.log
/usr/local/bin/kill_pptp_user.sh "$USERNAME"
exit 0
SCRIPT
chmod +x /usr/local/bin/softether_onconnect.sh

# 为所有用户设置连接时执行的脚本（onconnect）
for i in $(seq 1 200); do
    /usr/local/vpnserver/vpncmd localhost /SERVER /CMD "Hub DEFAULT" UserSet "user$i" /ONCONNECT:"/usr/local/bin/softether_onconnect.sh user$i" > /dev/null 2>&1
done

# ==================== 8. 配置防火墙 (nftables) ====================
log "配置 nftables 防火墙（完整规则）"

# 加载内核模块
modprobe nf_nat
modprobe ip_gre
modprobe esp4

# 清空并重建规则集
nft flush ruleset

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

# SoftEther 管理
nft add rule inet filter input tcp dport 443 accept
nft add rule inet filter input tcp dport 5555 accept

# ICMP (ping)
nft add rule inet filter input icmp type echo-request accept

# 保存规则
nft list ruleset > /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

# ==================== 9. 生成 Windows 修复脚本 ====================
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

# ==================== 10. 完成输出 ====================
log "${GREEN}所有组件部署完成！${NC}"
cat << EOF
==========================================
✅ 双 VPN 服务部署成功 + PPTP固定IP分配 + 跨协议互踢
==========================================
服务器 IP: $SERVER_IP (当前可能未生效，需要重启)
网关: $SERVER_GATEWAY
用户名: user1 ~ user200
密码: $FIXED_PASSWORD

📌 L2TP/IPsec (SoftEther)：
   服务器地址: $SERVER_IP
   预共享密钥: $FIXED_PASSWORD
   IP分配: 动态 IP 池 10.0.10.202-254（每次连接可能不同）

📌 PPTP (pptpd)：
   服务器地址: $SERVER_IP
   固定IP分配: user1→10.0.10.2, user2→10.0.10.3, …, user200→10.0.10.201

📌 跨协议互踢功能已启用（同一用户不能同时通过PPTP和L2TP登录）

📌 Windows 修复脚本: /root/Windows-VPN-Fix.bat
   (下载到 Windows 以管理员运行并重启)

📌 日志文件: /var/log/vpn_session_control.log
==========================================
⚠️ 重要提示：
   1. 服务器 IP 配置文件已更新为 $SERVER_IP，但当前会话仍使用旧 IP。
   2. 请手动重启服务器（执行 reboot）以使新 IP 生效。
   3. 如果当前 SSH 连接 IP 不是 $SERVER_IP，重启后请使用新 IP 连接。
==========================================
EOF

log "安装结束。请手动执行 reboot 重启服务器使所有配置生效。"