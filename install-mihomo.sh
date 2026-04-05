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
    log_info "设置 Mihomo 服务开机启动..."
    systemctl enable mihomo
    log_info "Mihomo 服务已设置为开机启动"
    log_info "注意：由于尚未配置 mihomo，服务未立即启动"
    log_info "请在配置 ${CONFIG_DIR}/config.yaml 后重启服务"
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
        log_warn "配置文件不存在，请手动配置 ${CONFIG_DIR}/config.yaml"
    fi
    
    log_info "服务状态: 已设置开机启动（未运行）"
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
    
    start_service
    
    check_installation
    
    print_info
}

main "$@"
