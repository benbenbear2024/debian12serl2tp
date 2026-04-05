#!/bin/bash

MIHOMO_VERSION="v1.19.22"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/mihomo"
LOG_DIR="/var/log/mihomo"

GITHUB_MIRRORS=(
    "https://ghproxy.homeboyc.cn/"
    "https://shrill-pond-3e81.hunsh.workers.dev/"
    "https://mirror.ghproxy.com/"
    "https://gh-proxy.com/"
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
    
    if [ $mirror_index -ge ${#GITHUB_MIRRORS[@]} ]; then
        log_error "所有镜像站点都尝试失败，请检查网络连接"
        return 1
    fi
    
    local mirror="${GITHUB_MIRRORS[$mirror_index]}"
    local download_url="${mirror}${url}"
    
    log_info "尝试使用镜像: $mirror"
    log_info "下载地址: $download_url"
    
    if wget -q --show-progress -O "$output" "$download_url"; then
        log_info "下载成功"
        return 0
    else
        log_warn "镜像 $mirror 下载失败，尝试下一个镜像..."
        rm -f "$output"
        download_file "$url" "$output" $((mirror_index + 1))
    fi
}

download_mihomo() {
    local arch=$(detect_arch)
    local os=$(detect_os)
    local filename="mihomo-linux-${arch}-${MIHOMO_VERSION}.gz"
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
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - localhost.ptlogin2.qq.com
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - tls://8.8.8.8:853
    - tls://1.1.1.1:853

proxies:

proxy-groups:

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
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
    log_info "启动 Mihomo 服务..."
    systemctl enable mihomo
    systemctl start mihomo
    
    sleep 2
    
    if systemctl is-active --quiet mihomo; then
        log_info "Mihomo 服务启动成功"
    else
        log_error "Mihomo 服务启动失败"
        systemctl status mihomo --no-pager
        exit 1
    fi
}

check_installation() {
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
        log_error "配置文件不存在"
        exit 1
    fi
    
    if systemctl is-active --quiet mihomo; then
        log_info "服务状态: 运行中"
    else
        log_warn "服务状态: 未运行"
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
    echo "注意事项:"
    echo "  1. 请编辑配置文件添加代理节点"
    echo "  2. 配置文件路径: ${CONFIG_DIR}/config.yaml"
    echo "  3. 修改配置后需重启服务: systemctl restart mihomo"
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
    
    create_config
    
    create_systemd_service
    
    start_service
    
    check_installation
    
    print_info
}

main "$@"
