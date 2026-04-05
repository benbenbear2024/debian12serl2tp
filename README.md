# Debian L2TP/PPTP VPN 服务器部署脚本

这是一个用于在 Debian 12 系统上快速部署 PPTP 和 L2TP VPN 服务的自动化脚本。

## 功能特性

- **双协议支持**：同时支持 PPTP 和 L2TP 两种 VPN 协议
- **用户管理**：自动生成 200 个用户账号（user1-200），每个用户分配固定 IP 地址
- **IP 地址映射**：user1-200 对应 IP 地址 10.0.10.2-10.0.10.201，实现一一对应
- **防火墙配置**：可选安装防火墙规则，包含 VPN 相关端口和常用协议端口
- **进程守护**：可选开启进程守护，自动监控和重启 VPN 服务
- **网络隔离**：防止 VPN 客户端之间互相访问
- **状态监控**：提供状态查看脚本，方便监控 VPN 服务运行状态

## 系统要求

- 操作系统：Debian 12 或兼容系统
- 权限：需要 root 权限运行
- 网络：需要公网 IP 或内网 IP 地址

## 文件说明

```
debian-l2tp/
├── install.sh              # 主安装脚本
├── status.sh               # 状态查看脚本
├── files/                  # 配置文件目录
│   ├── pptpd.conf         # PPTP 配置文件
│   ├── options.pptpd      # PPTP 选项配置
│   ├── xl2tpd.conf        # L2TP 配置文件
│   └── options.xl2tpd     # L2TP 选项配置
└── README.md              # 本文档
```

## 安装步骤

### 1. 下载脚本

```bash
# 克隆或下载项目文件
git clone <repository-url>
cd debian-l2tp
```

### 2. 赋予执行权限

```bash
chmod +x install.sh status.sh
```

### 3. 运行安装脚本

```bash
sudo ./install.sh
```

### 4. 按照提示完成配置

安装过程中，脚本会提示您：

1. **服务器 IP 地址**：输入服务器的 IP 地址（默认：10.0.10.254）
2. **防火墙规则**：选择是否安装防火墙规则（推荐：是）
3. **进程守护**：选择是否开启进程守护（推荐：是）
   - 如果开启，设置检查时间（30-3600 秒，默认：300 秒）
4. **网络重启**：选择是否立即重启网络服务

## 使用方法

### VPN 连接信息

- **账号范围**：user1 ~ user200
- **密码**：88888888（所有账号密码相同）
- **IP 地址池**：
  - PPTP/L2TP：10.0.10.2 - 10.0.10.201
  - 服务器端：10.0.10.1

### Windows 客户端配置

#### PPTP 连接

1. 打开"设置" → "网络和 Internet" → "VPN"
2. 点击"添加 VPN 连接"
3. 配置如下：
   - VPN 提供商：Windows（内置）
   - 连接名称：自定义名称
   - 服务器名称或地址：您的服务器 IP 地址
   - VPN 类型：点对点隧道协议（PPTP）
   - 用户名：user1（或其他用户名）
   - 密码：88888888

#### L2TP 连接

1. 打开"设置" → "网络和 Internet" → "VPN"
2. 点击"添加 VPN 连接"
3. 配置如下：
   - VPN 提供商：Windows（内置）
   - 连接名称：自定义名称
   - 服务器名称或地址：您的服务器 IP 地址
   - VPN 类型：使用预共享密钥的 L2TP/IPsec
   - 预共享密钥：无需填写
   - 用户名：user1（或其他用户名）
   - 密码：88888888

#### Windows 7 客户端配置

**PPTP 连接设置：**

1. 打开"控制面板" → "网络和共享中心" → "设置新的连接或网络"
2. 选择"连接到工作区" → "使用我的 Internet 连接 (VPN)"
3. 输入服务器地址（您的服务器 IP 地址），点击"下一步"
4. 输入用户名（user1 等）和密码（88888888），点击"创建"
5. 点击"关闭"，然后在网络连接中找到刚创建的 VPN 连接

6. 右键点击 VPN 连接 → "属性"：
   - **安全** 选项卡：
     - VPN 类型：**点对点隧道协议 (PPTP)**
     - 数据加密：**可选加密（没有加密也可以连接）**
     - 点击"高级设置"：
       - 选择"允许这些协议"
       - 只勾选：**Microsoft CHAP Version 2 (MS-CHAP v2)**
   - **网络** 选项卡：
     - 取消勾选：**Internet 协议版本 6 (TCP/IPv6)**
     - 只保留：**Internet 协议版本 4 (TCP/IPv4)**
7. 点击"确定"，然后连接 VPN

**常见问题及解决方案：**

- **连接时出现"错误 800"**：检查服务器 IP 地址是否正确，防火墙是否开放 1723 端口
- **连接时出现"错误 619"**：检查 PPTP 服务是否运行，防火墙是否允许 GRE 协议
- **连接时出现"错误 691"**：检查用户名和密码是否正确
- **连接成功但无法访问网络**：检查 IP 转发是否开启，防火墙 NAT 规则是否正确

### 查看服务状态

```bash
# 运行状态查看脚本
sudo ./status.sh
```

状态脚本会显示：
- PPTP 和 L2TP 服务状态
- 防火墙规则和端口
- mihomo 运行状态
- 进程守护详细信息
- 系统网络信息

### 服务管理命令

```bash
# 查看 PPTP 服务状态
systemctl status pptpd

# 查看 L2TP 服务状态
systemctl status xl2tpd

# 重启 PPTP 服务
systemctl restart pptpd

# 重启 L2TP 服务
systemctl restart xl2tpd

# 查看 PPTP 日志
journalctl -u pptpd -f

# 查看 L2TP 日志
journalctl -u xl2tpd -f
```

## 配置说明

### 防火墙端口

如果选择安装防火墙规则，以下端口会被开放：

**VPN 相关端口**：
- PPTP：TCP 1723 + GRE 协议
- L2TP：UDP 1701

**常用协议端口**：
- SSH：TCP 22
- HTTP：TCP 80
- HTTPS：TCP 443
- FTP：TCP 21
- SMTP：TCP 25
- POP3：TCP 110
- IMAP：TCP 143
- DNS：UDP 53
- RDP：TCP 3389

**其他端口**：
- TCP 7890, 7891, 7892, 9090, 9999

### 进程守护

如果选择开启进程守护，系统会：

1. 创建守护脚本：`/usr/local/bin/vpn-daemon.sh`
2. 添加 cron 定时任务，定期检查 VPN 服务状态
3. 如果服务停止，自动重启服务
4. 记录操作日志到：`/var/log/vpn-daemon.log`

### 网络隔离

脚本会配置网络隔离规则，防止 VPN 客户端之间互相访问，提高安全性。

## 故障排查

### 1. VPN 连接失败

**检查服务状态**：
```bash
sudo ./status.sh
```

**检查端口监听**：
```bash
netstat -tuln | grep -E '1723|1701'
```

**查看服务日志**：
```bash
journalctl -u pptpd -f
journalctl -u xl2tpd -f
```

### 2. 防火墙问题

**检查防火墙规则**：
```bash
iptables -L -n
```

**检查 NAT 转发**：
```bash
iptables -t nat -L -n
```

### 3. 进程守护问题

**检查 cron 任务**：
```bash
crontab -l
```

**查看守护日志**：
```bash
tail -f /var/log/vpn-daemon.log
```

### 4. 网络连接问题

**检查 IP 转发**：
```bash
sysctl net.ipv4.ip_forward
```

**检查网络接口**：
```bash
ip addr show
```

## 注意事项

1. **安全性**：
   - 默认密码为 88888888，建议在生产环境中修改
   - 建议开启防火墙规则，保护服务器安全
   - 建议开启进程守护，确保服务持续运行

2. **网络配置**：
   - 安装脚本会修改网络配置，请确保有备用访问方式
   - 如果网络配置失败，可能需要手动重启网络服务

3. **用户管理**：
   - 用户账号信息存储在 `/etc/ppp/chap-secrets`
   - 如需修改密码，直接编辑该文件

4. **兼容性**：
   - 本脚本专为 Debian 12 设计
   - 在其他系统上可能需要调整

5. **mihomo 集成**：
   - 如果您使用 mihomo，需要手动配置分流规则
   - 脚本不会自动配置 mihomo

## 卸载

如需卸载 VPN 服务，执行以下命令：

```bash
# 停止服务
systemctl stop pptpd xl2tpd

# 禁用服务
systemctl disable pptpd xl2tpd

# 卸载软件包
apt-get remove --purge pptpd xl2tpd ppp

# 删除配置文件
rm -rf /etc/pptpd.conf /etc/ppp/options.pptpd
rm -rf /etc/xl2tpd/xl2tpd.conf /etc/ppp/options.xl2tpd
rm -rf /etc/ppp/chap-secrets

# 删除守护脚本
rm -f /usr/local/bin/vpn-daemon.sh
crontab -l | grep -v "vpn-daemon.sh" | crontab -

# 清理防火墙规则（如果需要）
iptables -F
iptables -t nat -F
```

## 技术支持

如有问题或建议，请提交 Issue 或 Pull Request。

## 许可证

本项目采用 MIT 许可证。

## 更新日志

### v1.0.0
- 初始版本
- 支持 PPTP 和 L2TP 双协议
- 支持 200 个用户账号
- 支持防火墙规则配置
- 支持进程守护
- 提供状态查看脚本
