#!/bin/bash

MIHOMO_VERSION="v1.19.22"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/mihomo"
LOG_DIR="/var/log/mihomo"

GITHUB_MIRRORS=(
    "https://ghfast.top/"
    "https://gh.llkk.cc/"
    "https://gh-proxy.org/"
    "https://hk.gh-proxy.org/"
    "https://cdn.gh-proxy.org/"
    "https://edgeone.gh-proxy.org/"
    "https://gh.bugdey.us.kg"
    
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armhf)
            echo "armv7"
            ;;
        mips)
            echo "mips"
            ;;
        mipsle)
            echo "mipsle"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

download_file() {
    local url=$1
    local output=$2
    local mirror_index=$3
    local max_retries=3
    
    if [ $mirror_index -ge ${#GITHUB_MIRRORS[@]} ]; then
        log_error "所有镜像站点都尝试失败，请检查网络连接"
        return 1
    fi
    
    local mirror="${GITHUB_MIRRORS[$mirror_index]}"
    local download_url="${mirror}${url}"
    
    log_info "尝试使用镜像: $mirror"
    log_info "下载地址: $download_url"
    
    # 尝试下载，最多重试 3 次
    for ((i=1; i<=$max_retries; i++)); do
        log_info "第 $i 次尝试下载..."
        if wget -q --show-progress --timeout=30 --tries=1 --no-check-certificate -O "$output" "$download_url"; then
            log_info "下载成功"
            return 0
        else
            log_warn "第 $i 次尝试失败，等待 3 秒后重试..."
            sleep 3
        fi
    done
    
    log_warn "镜像 $mirror 下载失败，尝试下一个镜像..."
    rm -f "$output"
    download_file "$url" "$output" $((mirror_index + 1))
}

download_mihomo() {
    local arch=$(detect_arch)
    local os=$(detect_os)
    local filename
    
    if [ "$arch" = "amd64" ]; then
        filename="mihomo-linux-${arch}-compatible-${MIHOMO_VERSION}.gz"
    else
        filename="mihomo-linux-${arch}-${MIHOMO_VERSION}.gz"
    fi
    
    local github_url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${filename}"
    
    log_info "系统架构: $arch"
    log_info "操作系统: $os"
    log_info "Mihomo 版本: $MIHOMO_VERSION"
    log_info "文件名: $filename"
    
    local temp_file="/tmp/${filename}"
    
    log_info "开始下载 Mihomo..."
    
    if download_file "$github_url" "$temp_file" 0; then
        log_info "解压文件..."
        gunzip -f "$temp_file"
        
        local binary_file="${temp_file%.gz}"
        chmod +x "$binary_file"
        
        log_info "安装 Mihomo 到 $INSTALL_DIR..."
        mv "$binary_file" "${INSTALL_DIR}/mihomo"
        
        log_info "Mihomo 安装成功"
        return 0
    else
        return 1
    fi
}

create_directories() {
    log_info "创建配置目录..."
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
}

create_config() {
    log_info "创建配置文件..."
    
    if [ ! -f "${CONFIG_DIR}/config.yaml" ]; then
        cat > "${CONFIG_DIR}/config.yaml" << 'EOF'
mixed-port: 7890
redir-port: 7892
tproxy-port: 7893
authentication: [""]
allow-lan: true
mode: rule
log-level: info
ipv6: true
external-controller: :9999
external-ui: ui
secret: "88888888"
        
tun: {enable: true, stack: system, device: utun, auto-route: true, dns-hijack: ["tcp://8.8.8.8:53", "8.8.8.8:53"]}
experimental: {ignore-resolve-fail: true, interface-name: en0}
dns:
    enable: true
    ipv6: false
    listen: 0.0.0.0:53
    enhanced-mode: fake-ip
    fake-ip-range: 198.18.0.1/16
    use-hosts: true
    default-nameserver: [223.5.5.5, 119.29.29.29,127.0.0.1:53]
    nameserver: ['https://dns.alidns.com/dns-query', 'https://doh.pub/dns-query',127.0.0.1:53]
    fallback: ['https://dns.google/dns-query', 'https://1.1.1.1/dns-query', 'https://dns.cloudflare.com/dns-query',8.8.8.8]
    fallback-filter: { geoip: true, geoip-code: CN, ipcidr: [240.0.0.0/4, 0.0.0.0/32] }
    fake-ip-filter: ['*.lan', '*.local', localhost.ptlogin2.qq.com]
store-selected: true
find-process-mode: "off"

rules:
    - SRC-IP-CIDR,10.0.10.2/32,Name1
    - SRC-IP-CIDR,10.0.10.3/32,Name2
    - SRC-IP-CIDR,10.0.10.4/32,Name3
    - SRC-IP-CIDR,10.0.10.5/32,Name4
    - SRC-IP-CIDR,10.0.10.6/32,Name5
    - SRC-IP-CIDR,10.0.10.7/32,Name6
    - SRC-IP-CIDR,10.0.10.8/32,Name7
    - SRC-IP-CIDR,10.0.10.9/32,Name8
    - SRC-IP-CIDR,10.0.10.10/32,Name9
    - SRC-IP-CIDR,10.0.10.11/32,Name10
proxies:
    - {name: 'Name1', rename: '🇭🇰香港-01 T 1.0x', type: trojan, server: productandservice.infralinkplus.com, port: 27101, password: edbdb7f9-6b83-4d54-c39e-0fc5e6533c72, udp: true, skip-cert-verify: true, sni: claude.1maxai.com, network: tcp}
    - {name: 'Name2', rename: '🇭🇰香港-02 T 1.0x', type: trojan, server: productandservice.infralinkplus.com, port: 27102, password: edbdb7f9-6b83-4d54-c39e-0fc5e6533c72, udp: true, skip-cert-verify: true, sni: claude.1maxai.com, network: tcp}
    - {name: 'Name3', rename: '🇭🇰香港-03 S 1.0x 时段2-7 0.5x', type: ss, server: productandservice.infralinkplus.com, port: 55201, password: 'MGU2Nzk1ZjI4MjNlYzk4Yw==:ZWRiZGI3ZjktNmI4My00ZA==', udp: true, cipher: 2022-blake3-aes-128-gcm}
    - {name: 'Name4', rename: '🇭🇰香港-06 H 0.1x', type: hysteria2, server: records.hy.ecmtxt.com, port: 10443, password: edbdb7f9-6b83-4d54-c39e-0fc5e6533c72, skip-cert-verify: true, sni: records.hy.ecmtxt.com, up: 30, down: 30, hop-interval: 60}
    - {name: 'Name5', rename: '🇭🇰香港-07 H 0.1x', type: hysteria2, server: records.hk01.ecmtxt.com, port: 10564, password: edbdb7f9-6b83-4d54-c39e-0fc5e6533c72, skip-cert-verify: true, sni: records.hk01.ecmtxt.com, up: 30, down: 30, hop-interval: 60}
    - {name: 'Name6', rename: '🇯🇵日本-01 S 1.0x', type: ss, server: productandservice.infralinkplus.com, port: 27001, password: 'MGU2Nzk1ZjI4MjNlYzk4Yw==:ZWRiZGI3ZjktNmI4My00ZA==', udp: true, cipher: 2022-blake3-aes-128-gcm}
    - {name: 'Name7', rename: '🇯🇵日本-02 S 1.0x', type: ss, server: productandservice.infralinkplus.com, port: 27002, password: 'MGU2Nzk1ZjI4MjNlYzk4Yw==:ZWRiZGI3ZjktNmI4My00ZA==', udp: true, cipher: 2022-blake3-aes-128-gcm}
    - {name: 'Name8', rename: '🇯🇵日本-03 S 1.0x', type: ss, server: productandservice.infralinkplus.com, port: 22271, password: 'MGU2Nzk1ZjI4MjNlYzk4Yw==:ZWRiZGI3ZjktNmI4My00ZA==', udp: true, cipher: 2022-blake3-aes-128-gcm}
    - {name: 'Name9', rename: '🇯🇵日本-04 S 1.0x', type: ss, server: productandservice.infralinkplus.com, port: 22269, password: 'MGU2Nzk1ZjI4MjNlYzk4Yw==:ZWRiZGI3ZjktNmI4My00ZA==', udp: true, cipher: 2022-blake3-aes-128-gcm}
    - {name: 'Name10', rename: '🇯🇵日本-05 H 0.1x', type: hysteria2, server: records.jp01.ecmtxt.com, port: 10443, password: edbdb7f9-6b83-4d54-c39e-0fc5e6533c72, skip-cert-verify: true, sni: vgraxiw73sj1.sdkdns.vip, up: 30, down: 30, hop-interval: 60}
   

EOF
        log_info "配置文件创建成功: ${CONFIG_DIR}/config.yaml"
    else
        log_warn "配置文件已存在，跳过创建"
    fi
}

create_systemd_service() {
    log_info "创建 systemd 服务..."
    
    cat > /etc/systemd/system/mihomo.service << 'EOF'
[Unit]
Description=Mihomo Proxy Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    log_info "Systemd 服务创建成功"
}

start_service() {
    local start_now=$1
    log_info "设置 Mihomo 服务开机启动..."
    systemctl enable mihomo
    log_info "Mihomo 服务已设置为开机启动"
    
    if [ "$start_now" = "yes" ]; then
        log_info "启动 Mihomo 服务..."
        systemctl start mihomo
        if systemctl is-active --quiet mihomo; then
            log_info "Mihomo 服务已启动"
        else
            log_warn "Mihomo 服务启动失败，请检查配置文件"
        fi
    else
        log_info "由于未生成配置文件，服务未立即启动"
        log_info "请在配置 ${CONFIG_DIR}/config.yaml 后执行以下命令启动服务："
        log_info "  systemctl start mihomo"
    fi
}

check_installation() {
    local start_now=$1
    log_info "检查安装..."
    
    if [ -f "${INSTALL_DIR}/mihomo" ]; then
        local version=$(${INSTALL_DIR}/mihomo -v)
        log_info "Mihomo 版本: $version"
    else
        log_error "Mihomo 二进制文件不存在"
        exit 1
    fi
    
    if [ -f "${CONFIG_DIR}/config.yaml" ]; then
        log_info "配置文件: ${CONFIG_DIR}/config.yaml"
    else
        log_warn "配置文件不存在，请手动配置 ${CONFIG_DIR}/config.yaml"
    fi
    
    if [ "$start_now" = "yes" ] && systemctl is-active --quiet mihomo; then
        log_info "服务状态: 运行中"
    else
        log_info "服务状态: 已设置开机启动（未运行）"
    fi
}

print_info() {
    echo ""
    echo "=========================================="
    echo "Mihomo 安装完成"
    echo "=========================================="
    echo ""
    echo "安装信息:"
    echo "  - 版本: $MIHOMO_VERSION"
    echo "  - 安装目录: $INSTALL_DIR"
    echo "  - 配置目录: $CONFIG_DIR"
    echo "  - 日志目录: $LOG_DIR"
    echo ""
    echo "服务管理:"
    echo "  - 启动服务: systemctl start mihomo"
    echo "  - 停止服务: systemctl stop mihomo"
    echo "  - 重启服务: systemctl restart mihomo"
    echo "  - 查看状态: systemctl status mihomo"
    echo "  - 查看日志: journalctl -u mihomo -f"
    echo ""
    echo "配置文件: ${CONFIG_DIR}/config.yaml"
    echo "控制面板: http://127.0.0.1:9090"
    echo "代理端口: 7890 (HTTP/SOCKS5)"
    echo ""
    echo "重要提示:"
    echo "  1. 服务已设置为开机启动，但未立即运行"
    echo "  2. 请先编辑配置文件添加代理节点"
    echo "  3. 配置完成后执行: systemctl start mihomo"
    echo "  4. 重启服务器后服务会自动启动"
    echo ""
}

main() {
    echo "=========================================="
    echo "Mihomo 安装脚本"
    echo "=========================================="
    echo ""
    
    check_root
    
    log_info "开始安装 Mihomo..."
    
    if ! command -v wget &> /dev/null; then
        log_info "安装 wget..."
        apt-get update -qq
        apt-get install -y wget
    fi
    
    if ! command -v gunzip &> /dev/null; then
        log_info "安装 gzip..."
        apt-get install -y gzip
    fi
    
    download_mihomo || exit 1
    
    create_directories
    
    echo ""
    echo "是否生成默认配置文件？"
    echo "1. 否（默认，推荐已有配置文件的用户选择）"
    echo "2. 是"
    read -p "请选择 (1/2): " CONFIG_CHOICE
    if [ -z "$CONFIG_CHOICE" ] || [ "$CONFIG_CHOICE" != "2" ]; then
        CREATE_CONFIG="no"
        log_info "将不生成配置文件"
    else
        CREATE_CONFIG="yes"
        log_info "将生成默认配置文件"
    fi
    
    if [ "$CREATE_CONFIG" = "yes" ]; then
        create_config
    else
        log_info "跳过配置文件生成，请手动配置 ${CONFIG_DIR}/config.yaml"
    fi
    
    create_systemd_service
    
    start_service "$CREATE_CONFIG"
    
    check_installation "$CREATE_CONFIG"
    
    print_info
}

main "$@"
