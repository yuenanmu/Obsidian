#!/usr/bin/env bash
# =============================================================================
# check-ubuntu-vm.sh
#
# 在 A 电脑的 Ubuntu 22.04 虚拟机内运行。只读自检脚本，不修改任何系统配置。
# 用途：一键确认「这台 VM 是否已经具备被 B 侧 VS Code Remote-SSH 连接的条件」。
#
# 用法:
#   chmod +x check-ubuntu-vm.sh && ./check-ubuntu-vm.sh
#
# 退出码: 0 = 关键项全部通过; 1 = 存在关键项失败
# =============================================================================

# 本脚本使用 bash 专有语法（[[ ]]、数组、EUID），必须用 bash 运行
if [ -z "${BASH_VERSION:-}" ]; then
  echo "本脚本需要 bash，请这样运行： bash $0" >&2
  exit 1
fi

set -uo pipefail   # 刻意不用 -e：自检要跑完全部项目

FAILED=0

hr()   { printf '\n\033[1;34m--- %s ---\033[0m\n' "$*"; }
pass() { printf '  \033[1;32m[ OK ]\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; FAILED=$((FAILED+1)); }
info() { printf '  \033[1;37m[ -- ]\033[0m %s\n' "$*"; }

printf '\033[1mUbuntu VM 侧自检 —— VS Code 跨局域网远程连接前置条件\033[0m\n'

# 部分检查（ufw / sshd -T / systemctl）需要 root，先尝试缓存 sudo 凭据
if [[ "${EUID}" -ne 0 ]]; then
  printf '  本脚本部分检查需要 sudo，可能会提示输入密码。\n'
  sudo -v 2>/dev/null || printf '  \033[1;33m[提示]\033[0m 未取得 sudo 凭据，需要 root 的检查可能显示为失败。\n'
fi

# ---------------------------------------------------------------------------
hr "1. 系统与网络出口"
if command -v lsb_release >/dev/null 2>&1; then
  info "$(lsb_release -ds 2>/dev/null) / 内核 $(uname -r) / $(dpkg --print-architecture)"
else
  info "内核 $(uname -r) / $(dpkg --print-architecture)"
fi

if ping -c2 -W3 223.5.5.5 >/dev/null 2>&1; then
  pass "基本出站连通 (223.5.5.5)"
else
  fail "出站不通 —— 先解决 VM 上网问题，其余检查都没有意义"
fi

if ping -c2 -W3 packages.microsoft.com >/dev/null 2>&1; then
  pass "packages.microsoft.com 可达"
else
  fail "packages.microsoft.com 不可达 —— VS Code 源安装会失败，改用 .deb 直连兜底"
fi

if command -v curl >/dev/null 2>&1; then
  if curl -sI --max-time 10 https://login.tailscale.com >/dev/null 2>&1; then
    pass "Tailscale 控制面可达 (curl)"
  else
    fail "login.tailscale.com 不可达 —— Tailscale 无法登录，请走手册第 9 节的备份方案阶梯"
  fi
elif command -v wget >/dev/null 2>&1; then
  if wget -q --spider --timeout=10 https://login.tailscale.com >/dev/null 2>&1; then
    pass "Tailscale 控制面可达 (wget)"
  else
    fail "login.tailscale.com 不可达 —— Tailscale 无法登录，请走手册第 9 节的备份方案阶梯"
  fi
else
  info "curl 与 wget 均未安装，跳过 Tailscale 控制面检查"
fi

# ---------------------------------------------------------------------------
hr "2. sshd"
if systemctl is-active --quiet ssh 2>/dev/null; then
  pass "ssh 服务 active"
else
  fail "ssh 服务未运行 —— sudo systemctl enable --now ssh"
fi

if systemctl is-enabled --quiet ssh 2>/dev/null; then
  pass "ssh 已设置开机自启"
else
  fail "ssh 未开机自启 —— sudo systemctl enable ssh（否则 VM 重启后远程连不上）"
fi

if ss -tlnp 2>/dev/null | grep -q ':22 '; then
  pass "22 端口正在监听"
  ss -tlnp 2>/dev/null | grep ':22 ' | sed 's/^/         /'
else
  fail "22 端口未监听 —— 检查 /etc/ssh/sshd_config 的 Port"
fi

if [[ -s "${HOME}/.ssh/authorized_keys" ]]; then
  pass "authorized_keys 存在，含 $(grep -c . "${HOME}/.ssh/authorized_keys" 2>/dev/null || echo '?') 个公钥"
  perms="$(stat -c '%a' "${HOME}/.ssh/authorized_keys" 2>/dev/null)"
  if [[ "$perms" == "600" || "$perms" == "644" ]]; then
    pass "authorized_keys 权限 ${perms}"
  else
    fail "authorized_keys 权限为 ${perms}，应为 600 —— chmod 600 ~/.ssh/authorized_keys"
  fi
else
  info "authorized_keys 尚不存在或为空（还没推公钥，属正常中间状态）"
fi

if [[ -d "${HOME}/.ssh" ]]; then
  perms="$(stat -c '%a' "${HOME}/.ssh" 2>/dev/null)"
  if [[ "$perms" == "700" ]]; then
    pass "~/.ssh 权限 700"
  else
    fail "~/.ssh 权限为 ${perms}，应为 700 —— chmod 700 ~/.ssh"
  fi
fi

pwauth="$(sudo sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
if [[ -n "${pwauth}" ]]; then
  if [[ "${pwauth}" == "no" ]]; then
    pass "密码登录已关闭 (PasswordAuthentication no)"
  else
    info "密码登录仍开启 (PasswordAuthentication ${pwauth}) —— 确认密钥可用后建议关闭"
  fi
fi

# ---------------------------------------------------------------------------
hr "3. 防火墙"
if command -v ufw >/dev/null 2>&1; then
  ufw_status="$(sudo ufw status 2>/dev/null | head -n1 || echo 'unknown')"
  if echo "${ufw_status}" | grep -q "Status: active"; then
    info "ufw: active"
    if sudo ufw status 2>/dev/null | grep -qi 'tailscale0'; then
      pass "ufw 已放行 tailscale0"
    else
      fail "ufw active 但未放行 tailscale0 —— sudo ufw allow in on tailscale0 （典型症状：tailscale ping 通但 ssh 不通）"
    fi
  else
    pass "ufw 未启用，不会拦截 tailnet 流量"
  fi
else
  info "未安装 ufw"
fi

# ---------------------------------------------------------------------------
hr "4. Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  fail "tailscale 未安装 —— curl -fsSL https://tailscale.com/install.sh | sh"
else
  info "$(tailscale version 2>/dev/null | head -n1)"

  if systemctl is-active --quiet tailscaled 2>/dev/null; then
    pass "tailscaled 服务 active"
  else
    fail "tailscaled 未运行 —— sudo systemctl enable --now tailscaled"
  fi

  if systemctl is-enabled --quiet tailscaled 2>/dev/null; then
    pass "tailscaled 已设置开机自启"
  else
    fail "tailscaled 未开机自启 —— sudo systemctl enable tailscaled（否则 VM 重启后无人值守场景会失联）"
  fi

  TSIP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  if [[ -n "${TSIP}" ]]; then
    pass "tailnet IP: ${TSIP}"
    echo
    echo "        >>> 把这个地址填到 B 侧 ~/.ssh/config 的 HostName <<<"
    echo
    if ip -4 addr show tailscale0 >/dev/null 2>&1; then
      mtu="$(cat /sys/class/net/tailscale0/mtu 2>/dev/null || echo '?')"
      info "tailscale0 MTU = ${mtu}（若 SSH 交互卡死可尝试降到 1280）"
    fi
  else
    fail "未加入 tailnet 或未登录 —— sudo tailscale up"
  fi

  echo "  --- tailscale status ---"
  tailscale status 2>/dev/null | head -n 20 | sed 's/^/        /' || info "无法获取 status"
fi

# ---------------------------------------------------------------------------
hr "5. VS Code 与 vscode-server"
if command -v code >/dev/null 2>&1; then
  pass "code CLI 已安装: $(code --version 2>/dev/null | head -n1)"
  info "commit: $(code --version 2>/dev/null | sed -n '2p')"
else
  info "code 未安装（不影响 Remote-SSH，仅影响在 A 本机 GUI 使用；手册 3.Step 2）"
fi

if [[ -d "${HOME}/.vscode-server" ]]; then
  pass "~/.vscode-server 已存在（说明之前连过）"
  if [[ -d "${HOME}/.vscode-server/bin" ]]; then
    info "已安装的 server commit:"
    ls -1 "${HOME}/.vscode-server/bin" 2>/dev/null | sed 's/^/          /'
  fi
  shopt -s nullglob
  cli_logs=("${HOME}/.vscode-server"/.cli.*.log)
  shopt -u nullglob
  if [[ ${#cli_logs[@]} -gt 0 ]]; then
    info "发现 server 日志，卡住时查看："
    echo "          tail -n 50 ${cli_logs[0]}"
  fi
else
  info "~/.vscode-server 不存在（首次连接时 B 侧会自动下发，慢/失败见手册 4.7）"
fi

# ---------------------------------------------------------------------------
hr "6. 休眠设置"
if systemctl is-enabled --quiet sleep.target 2>/dev/null; then
  info "sleep.target 仍启用的可能性较高 —— 长期远程建议执行："
  echo "          sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
else
  pass "sleep.target 已被 mask（不会自动休眠）"
fi
if command -v gsettings >/dev/null 2>&1; then
  ac="$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || echo 'n/a')"
  info "GNOME 交流电自动挂起设置 = ${ac}（'nothing' 为正确）"
fi
info "别忘了 Windows 宿主机：电源计划里的「睡眠」必须设为「从不」。宿主一睡，VM 全掉。"

# ---------------------------------------------------------------------------
printf '\n\033[1m================ 自检结束 ================\033[0m\n'
if [[ "${FAILED}" -eq 0 ]]; then
  printf '\033[1;32m关键项全部通过。\033[0m请在 B 侧运行 check-windows-b.ps1 完成端到端确认。\n\n'
  exit 0
else
  printf '\033[1;31m有 %d 项未通过。\033[0m逐条修复后重跑本脚本。\n\n' "${FAILED}"
  exit 1
fi
