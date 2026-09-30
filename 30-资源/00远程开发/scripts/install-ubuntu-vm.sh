#!/usr/bin/env bash
# =============================================================================
# install-ubuntu-vm.sh
#
# 在 A 电脑的 Ubuntu 22.04 虚拟机内运行（普通用户，脚本内部按需 sudo）。
# 作用：安装并启用 OpenSSH server + VS Code + Tailscale，为 B 侧的
#       VS Code Remote-SSH 跨局域网连接做好准备。
#
# 幂等：可以重复运行。
#
# 用法:
#   ./install-ubuntu-vm.sh                     # sshd + VS Code + Tailscale
#   ./install-ubuntu-vm.sh --fix-ufw           # 额外放行 ufw 的 tailscale0 / OpenSSH
#   ./install-ubuntu-vm.sh --disable-suspend   # 额外屏蔽 VM 内休眠挂起
#   ./install-ubuntu-vm.sh --fix-ufw --disable-suspend
#
# 注意：脚本不会自动执行 `tailscale up`（需要你交互式登录账号），
#       完成后会明确提示你手动执行。
# =============================================================================

# 本脚本使用 bash 专有语法（[[ ]]、EUID、pipefail），必须用 bash 运行
if [ -z "${BASH_VERSION:-}" ]; then
  echo "本脚本需要 bash，请这样运行： bash $0" >&2
  exit 1
fi

set -euo pipefail

DO_UFW=0
DO_NOSUSPEND=0

for arg in "$@"; do
  case "$arg" in
    --fix-ufw)         DO_UFW=1 ;;
    --disable-suspend) DO_NOSUSPEND=1 ;;
    -h|--help)
      cat <<'USAGE'
用法: ./install-ubuntu-vm.sh [选项]

  (无选项)            安装并启用 OpenSSH server + VS Code + Tailscale
  --fix-ufw           若 ufw 处于 active，追加 tailscale0 与 OpenSSH 放行规则
  --disable-suspend   屏蔽 VM 内休眠/挂起（避免远程会话半夜断）
  -h, --help          显示本帮助

完成后仍需手动执行 `sudo tailscale up` 并浏览器登录。
USAGE
      exit 0
      ;;
    *)
      echo "未知参数: $arg （用 -h 看用法）" >&2
      exit 2
      ;;
  esac
done

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m[警告]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then
  die "请不要用 root 或 sudo 直接运行本脚本；脚本内部会按需调用 sudo。（否则 HOME 会变成 /root）"
fi

log "环境信息"
lsb_release -a 2>/dev/null || true
echo "    内核: $(uname -r)"
echo "    架构: $(dpkg --print-architecture)"

# ---------------------------------------------------------------------------
log "Step 1/5  更新 apt 索引"
sudo apt-get update -y

# ---------------------------------------------------------------------------
log "Step 2/5  安装并启用 OpenSSH server"
sudo apt-get install -y openssh-server
sudo systemctl enable --now ssh
if systemctl is-active --quiet ssh; then
  ok "sshd 正在运行"
else
  die "sshd 未能启动，请执行 journalctl -u ssh -n 50 查看原因"
fi
if ss -tlnp 2>/dev/null | grep -q ':22 '; then
  ok "22 端口正在监听"
else
  warn "未检测到 22 端口监听，请检查 /etc/ssh/sshd_config 的 Port 设置"
fi

# ---------------------------------------------------------------------------
log "Step 3/5  安装 VS Code"
if command -v code >/dev/null 2>&1; then
  ok "已安装: $(code --version 2>/dev/null | head -n1)"
else
  ARCH="$(dpkg --print-architecture)"
  KEYRING="/etc/apt/keyrings/packages.microsoft.gpg"
  LISTFILE="/etc/apt/sources.list.d/vscode.list"

  sudo apt-get install -y wget gpg apt-transport-https ca-certificates

  if [[ ! -f "${KEYRING}" ]]; then
    TMPKEY="$(mktemp)"
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "${TMPKEY}"
    sudo install -D -o root -g root -m 644 "${TMPKEY}" "${KEYRING}"
    rm -f "${TMPKEY}"
    ok "已导入 Microsoft 签名密钥"
  else
    ok "Microsoft 签名密钥已存在，跳过"
  fi

  echo "deb [arch=${ARCH} signed-by=${KEYRING}] https://packages.microsoft.com/repos/code stable main" \
    | sudo tee "${LISTFILE}" >/dev/null

  if sudo apt-get update -y && sudo apt-get install -y code; then
    ok "官方源安装成功: $(code --version 2>/dev/null | head -n1)"
  else
    warn "官方源安装失败，改用官方 .deb 直连兜底"
    case "${ARCH}" in
      amd64) DEB_OS="linux-deb-x64" ;;
      arm64) DEB_OS="linux-deb-arm64" ;;
      armhf) DEB_OS="linux-deb-armhf" ;;
      *)     DEB_OS="linux-deb-x64" ;;
    esac
    wget -O /tmp/code.deb "https://code.visualstudio.com/sha/download?build=stable&os=${DEB_OS}"
    sudo apt-get install -y /tmp/code.deb
    rm -f /tmp/code.deb
    ok "deb 兜底安装成功: $(code --version 2>/dev/null | head -n1)"
  fi
fi

# ---------------------------------------------------------------------------
log "Step 4/5  安装 Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  ok "已安装: $(tailscale version 2>/dev/null | head -n1)"
else
  command -v curl >/dev/null 2>&1 || sudo apt-get install -y curl
  curl -fsSL https://tailscale.com/install.sh | sh
  ok "安装完成: $(tailscale version 2>/dev/null | head -n1)"
fi
sudo systemctl enable --now tailscaled
if systemctl is-active --quiet tailscaled; then
  ok "tailscaled 正在运行"
else
  die "tailscaled 未能启动，请执行 journalctl -u tailscaled -n 50 查看原因"
fi

# ---------------------------------------------------------------------------
log "Step 5/5  可选加固"

if [[ "${DO_UFW}" -eq 1 ]]; then
  if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    sudo ufw allow in on tailscale0
    sudo ufw allow OpenSSH
    ok "已放行 ufw 的 tailscale0 与 OpenSSH"
  else
    ok "ufw 未启用，无需处理"
  fi
else
  warn "未处理 ufw。若防火墙是 active，必须手动执行（否则 tailscale ping 通但 ssh 不通）："
  echo "        sudo ufw allow in on tailscale0"
  echo "        sudo ufw allow OpenSSH"
fi

if [[ "${DO_NOSUSPEND}" -eq 1 ]]; then
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target \
    || warn "部分休眠 target 屏蔽失败，请手动检查： systemctl status sleep.target"
  ok "已屏蔽 VM 内休眠/挂起"
  if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null \
      && ok "已关闭 GNOME 交流电下自动挂起" \
      || warn "gsettings 设置失败（可能不在图形会话中），请手动去 设置 → 电源 关闭自动挂起"
  fi
else
  warn "未处理休眠。长期远程使用建议执行（或加 --disable-suspend）："
  echo "        sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
  echo "      并记得在 Windows 宿主机电源计划里把「睡眠」设为「从不」——宿主一睡，VM 全掉。"
fi

# ---------------------------------------------------------------------------
log "结果"
if tailscale ip -4 >/dev/null 2>&1; then
  ok "tailnet IP: $(tailscale ip -4 | head -n1)"
  echo
  echo "    下一步（在 B 的 VS Code 里连）："
  echo "      ssh $(whoami)@$(tailscale ip -4 | head -n1)"
else
  warn "尚未加入 tailnet。请手动执行并完成浏览器登录："
  echo
  echo "        sudo tailscale up"
  echo
  echo "    完成后运行 tailscale ip -4 获取 100.x.y.z 地址。"
  echo "    该地址就是 B 侧 ~/.ssh/config 里 HostName 要填的值。"
fi

echo
echo "    自检： ./check-ubuntu-vm.sh"
echo "    重要： 请到 Tailscale admin console 给本机 Disable key expiry，"
echo "           否则 180 天后远程访问会静默失效。"
echo
