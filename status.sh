#!/bin/bash
# VPN 服务状态查看脚本
# 用于查看 PPTP、L2TP 服务状态、防火墙规则、mihomo 运行状态和进程守护信息

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行: sudo bash $0"
  exit 1
fi

echo "=========================================="
echo "VPN 服务状态查看脚本"
echo "=========================================="
echo ""

# 1. 查看 PPTP 和 L2TP 服务状态
echo "=== 1. VPN 服务状态 ==="
echo ""

echo "--- PPTP 服务状态 ---"
if systemctl is-active --quiet pptpd; then
  echo "状态: 运行中 (active)"
  systemctl status pptpd --no-pager | grep -E "Active:|Main PID:|Tasks:|Memory:|CPU:"
else
  echo "状态: 未运行 (inactive)"
fi
echo ""

echo "--- L2TP 服务状态 ---"
if systemctl is-active --quiet xl2tpd; then
  echo "状态: 运行中 (active)"
  systemctl status xl2tpd --no-pager | grep -E "Active:|Main PID:|Tasks:|Memory:|CPU:"
else
  echo "状态: 未运行 (inactive)"
fi
echo ""

echo "--- VPN 相关端口监听状态 ---"
echo "PPTP 端口 (TCP 1723):"
netstat -tuln | grep ":1723" || echo "  未监听"
echo "L2TP 端口 (UDP 1701):"
netstat -tuln | grep ":1701" || echo "  未监听"
echo ""

# 2. 查看防火墙放行的规则和端口
echo "=== 2. 防火墙规则 ==="
echo ""

echo "--- iptables 服务状态 ---"
if systemctl is-active --quiet iptables; then
  echo "状态: 运行中 (active)"
else
  echo "状态: 未运行 (inactive) 或不存在"
fi
echo ""

echo "--- INPUT 链规则 (放行的端口) ---"
iptables -L INPUT -n --line-numbers | grep -E "ACCEPT|Chain" || echo "  无规则"
echo ""

echo "--- VPN 相关规则 ---"
echo "PPTP 规则:"
iptables -L INPUT -n | grep -E "1723|gre" || echo "  无 PPTP 规则"
echo "L2TP 规则:"
iptables -L INPUT -n | grep "1701" || echo "  无 L2TP 规则"
echo ""

echo "--- NAT 转发规则 ---"
iptables -t nat -L POSTROUTING -n | grep MASQUERADE || echo "  无 NAT 转发规则"
echo ""

echo "--- 网络隔离规则 ---"
iptables -L FORWARD -n | grep "10.0.10.0/24" || echo "  无网络隔离规则"
echo ""

# 3. 查看 mihomo 是否运行
echo "=== 3. mihomo 运行状态 ==="
echo ""

if command -v mihomo > /dev/null; then
  echo "mihomo 已安装"
  if pgrep -x "mihomo" > /dev/null; then
    echo "状态: 运行中"
    ps aux | grep mihomo | grep -v grep
  else
    echo "状态: 未运行"
  fi
else
  echo "mihomo 未安装"
fi
echo ""

# 4. 查看进程守护详细信息
echo "=== 4. 进程守护信息 ==="
echo ""

echo "--- 守护脚本状态 ---"
if [ -f "/usr/local/bin/vpn-daemon.sh" ]; then
  echo "守护脚本: 存在"
  echo "路径: /usr/local/bin/vpn-daemon.sh"
  echo "权限: $(ls -l /usr/local/bin/vpn-daemon.sh | awk '{print $1}')"
else
  echo "守护脚本: 不存在"
fi
echo ""

echo "--- cron 任务状态 ---"
if crontab -l 2>/dev/null | grep -q "vpn-daemon.sh"; then
  echo "cron 任务: 已设置"
  echo "任务详情:"
  crontab -l 2>/dev/null | grep "vpn-daemon.sh"
  
  # 解析 cron 任务，计算检查频率
  CRON_LINE=$(crontab -l 2>/dev/null | grep "vpn-daemon.sh")
  CRON_MINUTE=$(echo "$CRON_LINE" | awk '{print $1}')
  if [[ "$CRON_MINUTE" == "*/"* ]]; then
    INTERVAL_MINUTES=${CRON_MINUTE#*/}
    INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))
    echo "检查频率: 每 $INTERVAL_MINUTES 分钟 ($INTERVAL_SECONDS 秒)"
  fi
else
  echo "cron 任务: 未设置"
fi
echo ""

echo "--- cron 服务状态 ---"
if systemctl is-active --quiet cron; then
  echo "状态: 运行中 (active)"
else
  echo "状态: 未运行 (inactive)"
fi
echo ""

echo "--- 守护日志 ---"
if [ -f "/var/log/vpn-daemon.log" ]; then
  echo "日志文件: 存在"
  echo "最近 10 条日志:"
  tail -10 /var/log/vpn-daemon.log
else
  echo "日志文件: 不存在"
fi
echo ""

# 5. 系统信息
echo "=== 5. 系统信息 ==="
echo ""

echo "--- IP 转发状态 ---"
IP_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
if [ "$IP_FORWARD" -eq 1 ]; then
  echo "IP 转发: 已启用"
else
  echo "IP 转发: 未启用"
fi
echo ""

echo "--- 网络接口信息 ---"
DEFAULT_IF=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -n "$DEFAULT_IF" ]; then
  echo "默认网络接口: $DEFAULT_IF"
  ip addr show $DEFAULT_IF | grep -E "inet |status"
else
  echo "未找到默认网络接口"
fi
echo ""

echo "=========================================="
echo "状态查看完成"
echo "=========================================="
