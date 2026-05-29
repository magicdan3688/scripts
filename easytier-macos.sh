#!/bin/bash
# ================================================================
# EasyTier 专属管理脚本 (macOS Launchd 定制版)
# 专为 magicdan 组网环境优化
# ================================================================
set -euo pipefail

# ----------------------------------------------------------------
# 常量定义
# ----------------------------------------------------------------
readonly INSTALL_DIR="/usr/local/bin"
readonly PLIST_FILE="/Library/LaunchDaemons/com.easytier.node.plist"
readonly SERVICE_NAME="com.easytier.node"
readonly LOCAL_MIRROR="http://202.189.23.82:1880/chfs/shared/easytier"
readonly LOG_ERR="/var/log/easytier.err"
readonly LOG_OUT="/var/log/easytier.log"

readonly PROXY_LIST=(
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxylist.com/"
    "https://mirror.ghproxy.com/"
)

# ----------------------------------------------------------------
# 彩色输出
# ----------------------------------------------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()    { echo -e "${GREEN}[INFO]${RESET}  $*" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
title()   { echo -e "\n${BOLD}${BLUE}>>> $* ${RESET}" >&2; }
success() { echo -e "${BOLD}${GREEN}$*${RESET}" >&2; }

TMP_ZIP=$(mktemp /tmp/easytier_XXXXXX.zip)

cleanup() {
    rm -f "$TMP_ZIP"
}
trap cleanup EXIT
trap 'echo; error "脚本被中断"; exit 130' INT TERM

# ----------------------------------------------------------------
# 前置检查
# ----------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此脚本需要 root 权限运行，请使用 sudo 运行此脚本。"
        exit 1
    fi
}

check_macos() {
    if [ "$(uname)" != "Darwin" ]; then
        error "此脚本专为 macOS 设计，当前系统不支持。"
        exit 1
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64) echo "x86_64"  ;;
        arm64)  echo "aarch64" ;; # Apple Silicon 映射为 aarch64
        *)
            error "不支持的 CPU 架构: $(uname -m)"
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------
# 下载与解压
# ----------------------------------------------------------------
prompt_version() {
    local choice ver
    while true; do
        printf "\n请选择要安装的 EasyTier 版本:\n" >&2
        printf "  ${BOLD}1)${RESET} v2.6.4（最新版，默认）\n" >&2
        printf "  ${BOLD}2)${RESET} v2.4.5（稳定版）\n" >&2
        printf "请输入选项 [1/2]（默认: 1）: " >&2
        read -r choice </dev/tty
        choice="${choice:-1}"
        case "$choice" in
            1) ver="v2.6.4"; break ;;
            2) ver="v2.4.5"; break ;;
            *) warn "无效选项 '${choice}'，请输入 1 或 2。" ;;
        esac
    done
    echo "$ver"
}

prompt_download_method() {
    local choice
    while true; do
        printf "\n请选择下载方式:\n" >&2
        printf "  ${BOLD}1)${RESET} GitHub 代理下载（推荐）\n" >&2
        printf "  ${BOLD}2)${RESET} 直接从 GitHub 下载（需直连环境）\n" >&2
        printf "请输入选项 [1/2]（默认: 1）: " >&2
        read -r choice </dev/tty
        choice="${choice:-1}"
        case "$choice" in
            1) echo "proxy";  return 0 ;;
            2) echo "direct"; return 0 ;;
            *) warn "无效选项 '${choice}'，请输入 1 或 2。" ;;
        esac
    done
}

download_and_extract() {
    local arch="$1"
    local version="$2"
    local download_method="$3"
    local base_name="easytier-macos-${arch}"
    local zip_name="${base_name}-${version}.zip"
    local rel_path="${version}/${zip_name}"
    local github_url="https://github.com/EasyTier/EasyTier/releases/download/${rel_path}"

    title "下载 EasyTier ${version} (${arch} for macOS)"

    local download_success=false
    if [ "$download_method" = "proxy" ]; then
        for proxy in "${PROXY_LIST[@]}"; do
            info "尝试代理: ${proxy}"
            if curl -fL --connect-timeout 10 "${proxy}${github_url}" -o "$TMP_ZIP" 2>/dev/null; then
                info "代理下载成功: ${proxy}"
                download_success=true
                break
            fi
            warn "代理 ${proxy} 失败，尝试下一个..."
        done
    else
        info "直接从 GitHub 下载: ${github_url}"
        if curl -fL --connect-timeout 15 "$github_url" -o "$TMP_ZIP"; then
            download_success=true
        fi
    fi

    if [ "$download_success" = false ]; then
        error "下载失败，请检查网络或更换下载方式。"
        return 1
    fi

    title "解压并安装核心文件"
    unzip -o "$TMP_ZIP" -d "/tmp/easytier_extract" >/dev/null 2>&1
    
    mkdir -p "$INSTALL_DIR"
    
    # 将提取的文件移动到目标目录
    local bin_path="/tmp/easytier_extract/${base_name}/easytier-core"
    if [ -f "$bin_path" ]; then
        cp "$bin_path" "${INSTALL_DIR}/easytier-core"
        chmod +x "${INSTALL_DIR}/easytier-core"
        info "easytier-core 已成功安装到 ${INSTALL_DIR}"
    else
        error "解压失败，未找到 easytier-core 文件。"
        rm -rf "/tmp/easytier_extract"
        return 1
    fi
    rm -rf "/tmp/easytier_extract"
}

# ----------------------------------------------------------------
# 交互：分配 IP
# ----------------------------------------------------------------
prompt_ipv4() {
    local default="10.144.144.100"
    while true; do
        printf "\n请输入本机的虚拟网络 IPv4 地址 (例如: ${CYAN}10.144.144.X${RESET}): " >&2
        read -r val </dev/tty
        val="${val:-$default}"
        if [[ ! "$val" =~ ^10\.144\.144\.[0-9]{1,3}$ ]]; then
            warn "输入的 IP 不符合网段 10.144.144.x，请重新输入。"
            continue
        fi
        echo "$val"
        return
    done
}

# ----------------------------------------------------------------
# 生成与加载 plist 服务
# ----------------------------------------------------------------
apply_launchd_service() {
    local ipv4="$1"

    title "配置 macOS 服务 (launchd)"
    
    # 卸载旧服务并清理进程
    launchctl unload -w "$PLIST_FILE" 2>/dev/null || true
    killall easytier-core 2>/dev/null || true

    # 写入 plist 文件
    cat <<EOF > "$PLIST_FILE"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/easytier-core</string>
        <string>--network-name</string>
        # 修改组网名称
        <string>组网名称</string>
        <string>--network-secret</string>
        # 修改组网密码
        <string>组网密码</string>
        <string>--ipv4</string>
        <string>${ipv4}</string>
        <string>--enable-exit-node</string>
        <string>--peers</string>
        # 修改广播服务器地址及端口
        <string>tcp://地址:11010</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${LOG_ERR}</string>
    <key>StandardOutPath</key>
    <string>${LOG_OUT}</string>
</dict>
</plist>
EOF

    # 赋予正确权限
    chown root:wheel "$PLIST_FILE"
    chmod 644 "$PLIST_FILE"

    # 加载服务
    info "正在加载并启动服务..."
    launchctl load -w "$PLIST_FILE"
    
    sleep 2
    if pgrep -x "easytier-core" > /dev/null; then
        success "服务启动成功！"
        info "分配的 IP: ${CYAN}${ipv4}${RESET}"
        info "运行日志: ${LOG_OUT}"
        info "错误日志: ${LOG_ERR}"
    else
        error "服务启动失败，请检查 ${LOG_ERR}"
    fi
}

# ================================================================
# 主菜单
# ================================================================
main_menu() {
    while true; do
        clear
        echo -e "${BOLD}${BLUE}"
        echo "  ╔══════════════════════════════════════╗"
        echo "  ║  EasyTier 专属安装脚本 (macOS 优化版) ║"
        echo "  ╚══════════════════════════════════════╝"
        echo -e "${RESET}"
        
        # 状态检查
        if pgrep -x "easytier-core" > /dev/null; then
            echo -e "  服务状态: ${GREEN}${BOLD}运行中 ✓${RESET}"
            local current_ip
            current_ip=$(grep -A1 "<string>--ipv4</string>" "$PLIST_FILE" 2>/dev/null | tail -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
            echo -e "  当前 IP:  ${CYAN}${current_ip}${RESET}\n"
        else
            echo -e "  服务状态: ${RED}${BOLD}已停止 / 未安装 ✗${RESET}\n"
        fi

        echo -e "${BOLD}请选择操作:${RESET}"
        echo -e "  ${BOLD}${GREEN}1)${RESET} 全新安装 / 更新程序 (针对 magicdan 组网)"
        echo -e "  ${BOLD}2)${RESET} 重启服务"
        echo -e "  ${BOLD}3)${RESET} 查看运行日志"
        echo -e "  ${BOLD}${RED}4)${RESET} 卸载 EasyTier"
        echo -e "  ${BOLD}0)${RESET} 退出\n"
        
        printf "请输入选项 [0-4]: "
        read -r choice </dev/tty

        case "$choice" in
            1)
                local version
                version=$(prompt_version)
                local dm
                dm=$(prompt_download_method)
                local my_ip
                my_ip=$(prompt_ipv4)
                download_and_extract "$(get_arch)" "$version" "$dm"
                apply_launchd_service "$my_ip"
                ;;
            2)
                title "重启 EasyTier 服务"
                launchctl unload -w "$PLIST_FILE" 2>/dev/null || true
                killall easytier-core 2>/dev/null || true
                launchctl load -w "$PLIST_FILE" 2>/dev/null || true
                success "服务已重启"
                ;;
            3)
                title "实时运行日志 (按 Ctrl+C 退出)"
                tail -f "$LOG_OUT" "$LOG_ERR"
                ;;
            4)
                title "卸载 EasyTier"
                printf "${YELLOW}确认要卸载 EasyTier 吗？[y/N]: ${RESET}"
                read -r ans </dev/tty
                if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
                    launchctl unload -w "$PLIST_FILE" 2>/dev/null || true
                    killall easytier-core 2>/dev/null || true
                    rm -f "$PLIST_FILE"
                    rm -f "${INSTALL_DIR}/easytier-core"
                    success "已完全卸载。"
                else
                    info "取消卸载。"
                fi
                ;;
            0)
                echo -e "\n${GREEN}再见！${RESET}"
                exit 0
                ;;
            *)
                warn "无效选项，请输入 0~4。"
                sleep 1
                ;;
        esac
        echo
        printf "${YELLOW}按 Enter 键返回主菜单...${RESET}"
        read -r </dev/tty
    done
}

check_macos
check_root
main_menu
