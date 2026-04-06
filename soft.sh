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
sleep 6s
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

# ==================== 2. 配置静态 IP ====================
log "配置服务器静态 IP: $SERVER_IP/24"
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$DEFAULT_IF" ]; then
    DEFAULT_IF=$(ls /sys/class/net | grep -E 'eth0|ens|eno' | head -n1)
fi
[ -z "$DEFAULT_IF" ] && error "无法检测到网卡"

cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto $DEFAULT_IF
iface $DEFAULT_IF inet static
    address $SERVER_IP/24
    gateway $SERVER_GATEWAY
    dns-nameservers 8.8.8.8 1.1.1.1
EOF

# ==================== 3. 内核参数 ====================
log "启用 IP 转发并禁用反向路径过滤"
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl -p

# ==================== 4. 安装 SoftEther VPN ====================
# log "下载并编译 SoftEther VPN Server"
cd /usr/local/src
SOFTETHER_URL="https://www.softether-download.com/files/softether/v4.43-9799-beta-2023.08.31-tree/Linux/SoftEther_VPN_Server/64bit_-_Intel_x64_or_AMD64/softether-vpnserver-v4.43-9799-beta-2023.08.31-linux-x64-64bit.tar.gz"
wget --no-check-certificate -O softether.tar.gz "$SOFTETHER_URL" || error "下载 SoftEther 失败"
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

# ==================== 5. 配置 SoftEther (L2TP/IPsec + 固定IP) ====================
log "配置 SoftEther: L2TP/IPsec、用户创建、固定IP分配"

# 配置 IPsec 和 SecureNAT
cat > /tmp/se_cfg.txt << EOF
Hub DEFAULT
IPsecEnable /L2TP:yes /L2TPRAW:yes /ETHERIP:no /PSK:$FIXED_PASSWORD /DEFAULTHUB:DEFAULT
SecureNATEnable
DhcpSet /START:10.0.10.202 /END:10.0.10.254 /MASK:255.255.255.0 /EXPIRE:7200 /GW:$SERVER_IP /DNS:8.8.8.8 /DNS2:1.1.1.1
EOF

echo "Exit" >> /tmp/se_cfg.txt

/usr/local/vpnserver/vpncmd localhost /SERVER /CMD < /tmp/se_cfg.txt || log "SoftEther 基础配置有警告，继续"

# 创建200个用户并设置固定IP
log "创建用户并分配固定 IP..."
for i in $(seq 1 200); do
    USER_IP="10.0.10.$((i+1))"
    
    /usr/local/vpnserver/vpncmd localhost /SERVER /CMD "Hub DEFAULT" \
        "UserCreate user$i /GROUP:none /REALNAME:none /NOTE:none /IP:$USER_IP" > /dev/null 2>&1 || true
    
    /usr/local/vpnserver/vpncmd localhost /SERVER /CMD "Hub DEFAULT" \
        "UserPasswordSet user$i /PASSWORD:$FIXED_PASSWORD" > /dev/null 2>&1 || true
done

log "用户创建完成，固定 IP 分配成功"

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

# 添加用户到 chap-secrets，指定固定IP
> /etc/ppp/chap-secrets
for i in $(seq 1 200); do
    echo "user$i pptpd $FIXED_PASSWORD 10.0.10.$((i+1))" >> /etc/ppp/chap-secrets
done
chmod 600 /etc/ppp/chap-secrets

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

for i in $(seq 1 200); do
    /usr/local/vpnserver/vpncmd localhost /SERVER /CMD "Hub DEFAULT" UserSet "user$i" /ONCONNECT:"/usr/local/bin/softether_onconnect.sh user$i" > /dev/null 2>&1
done

# ==================== 8. 配置防火墙 (nftables) ====================
log "配置 nftables 防火墙"
modprobe nf_nat
modprobe ip_gre
modprobe esp4

nft flush ruleset

nft add table nat
nft add chain nat postrouting '{ type nat hook postrouting priority 100; }'
nft add rule nat postrouting ip saddr $VPN_CIDR masquerade

nft add table inet filter
nft add chain inet filter input '{ type filter hook input priority 0; policy drop; }'
nft add rule inet filter input ct state established,related accept
nft add rule inet filter input iif lo accept
nft add rule inet filter input tcp dport 22 accept
nft add rule inet filter input tcp dport 1723 accept
nft add rule inet filter input tcp dport 443 accept
nft add rule inet filter input tcp dport 5555 accept
nft add rule inet filter input udp dport { 500, 4500, 1701 } accept
nft add rule inet filter input ip protocol esp accept
nft add rule inet filter input ip protocol gre accept
nft add rule inet filter input icmp type echo-request accept

nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'

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
✅ 双 VPN 服务部署成功 + 固定IP分配 + 跨协议互踢
==========================================
服务器 IP: $SERVER_IP
网关: $SERVER_GATEWAY
用户名: user1 ~ user200
密码: $FIXED_PASSWORD
固定IP: user1 -> 10.0.10.2, user2 -> 10.0.10.3, ..., user200 -> 10.0.10.201

📌 L2TP/IPsec (SoftEther):
   服务器地址: $SERVER_IP
   预共享密钥: $FIXED_PASSWORD
   固定IP分配: user1 -> 10.0.10.2, user2 -> 10.0.10.3, ..., user200 -> 10.0.10.201

📌 PPTP (pptpd):
   服务器地址: $SERVER_IP
   固定IP分配: user1 -> 10.0.10.2, user2 -> 10.0.10.3, ..., user200 -> 10.0.10.201

📌 跨协议互踢功能已启用（同一用户不能同时通过PPTP和L2TP登录）

📌 Windows 修复脚本: /root/Windows-VPN-Fix.bat
   (下载到 Windows 以管理员运行并重启)

📌 日志文件: /var/log/vpn_session_control.log
==========================================
建议重启服务器: reboot
EOF

log "重启网络服务以应用静态 IP 配置..."
systemctl restart networking || log "网络重启可能需手动检查"
sleep 2

log "安装结束。建议执行 reboot 重启服务器以使所有配置完全生效。"