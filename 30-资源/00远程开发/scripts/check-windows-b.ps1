# =============================================================================
# check-windows-b.ps1
#
# 在 B 电脑（Windows）上运行。只读自检脚本，不修改任何系统配置。
# 用途：确认 B 侧是否已经具备通过 VS Code Remote-SSH 连接 A 的 Ubuntu VM 的条件。
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\check-windows-b.ps1
#   powershell -ExecutionPolicy Bypass -File .\check-windows-b.ps1 -HostAlias ubuntu-vm
#
# 退出码: 0 = 关键项全部通过; 1 = 存在关键项失败
# =============================================================================

[CmdletBinding()]
param(
    [string]$HostAlias = 'ubuntu-vm'
)

$ErrorActionPreference = 'Continue'
$script:Failed = 0

function Write-Hr      { param([string]$Text) Write-Host "`n--- $Text ---" -ForegroundColor Cyan }
function Write-Pass    { param([string]$Text) Write-Host "  [ OK ] $Text" -ForegroundColor Green }
function Write-Fail    { param([string]$Text) Write-Host "  [FAIL] $Text" -ForegroundColor Red; $script:Failed++ }
function Write-Info    { param([string]$Text) Write-Host "  [ -- ] $Text" -ForegroundColor Gray }
function Write-Warn2   { param([string]$Text) Write-Host "  [警告] $Text" -ForegroundColor Yellow }

Write-Host "B 侧（Windows）自检 —— 连接 A 的 Ubuntu VM 前置条件" -ForegroundColor White
Write-Info "目标 SSH 别名: $HostAlias"

# ---------------------------------------------------------------------------
Write-Hr "1. Tailscale 客户端"

$tsExe = $null
$candidates = New-Object System.Collections.ArrayList
if ($env:ProgramFiles)          { [void]$candidates.Add((Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe')) }
if (${env:ProgramFiles(x86)})   { [void]$candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')) }
foreach ($c in $candidates) {
    if (Test-Path $c) { $tsExe = $c; break }
}
if (-not $tsExe) {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { $tsExe = $cmd.Source }
}

if ($tsExe) {
    Write-Pass "已安装: $tsExe"
    try {
        $ver = (& $tsExe version 2>&1 | Select-Object -First 1)
        Write-Info "版本: $ver"
    } catch { }

    $svc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Pass "Tailscale 服务 Running"
    } else {
        Write-Fail "Tailscale 服务未运行 —— 从开始菜单启动 Tailscale 并登录"
    }

    Write-Host "  --- tailscale status (前 15 行) ---"
    try {
        & $tsExe status 2>&1 | Select-Object -First 15 | ForEach-Object { Write-Host "        $_" }
    } catch {
        Write-Fail "无法获取 tailscale status —— 可能未登录（用与 A 相同的账号登录）"
    }

    Write-Host "  --- 检查是否能看到对端 ---"
    try {
        $st = (& $tsExe status 2>&1) -join "`n"
        if ($st -match 'offline') {
            Write-Warn2 "状态里出现 offline 字样，确认 A 的 VM 是否已开机且 tailscaled 在跑"
        } else {
            Write-Info "若上面列表里能看到 A 的 VM 名称，说明已在同一 tailnet"
        }
    } catch { }
} else {
    Write-Fail "未找到 tailscale.exe —— 请安装 Tailscale 客户端并用与 A 相同的账号登录"
}

# ---------------------------------------------------------------------------
Write-Hr "2. SSH 密钥"

$sshDir  = Join-Path $env:USERPROFILE '.ssh'
$privKey = Join-Path $sshDir 'id_ed25519'
$pubKey  = "$privKey.pub"

if (Test-Path $sshDir) { Write-Pass "$sshDir 存在" } else { Write-Fail "$sshDir 不存在 —— 运行 ssh-keygen -t ed25519 -C `"b-laptop`"" }

if (Test-Path $privKey) {
    Write-Pass "私钥存在: $privKey"
    if (Test-Path $pubKey) {
        Write-Pass "公钥存在: $pubKey"
        $fp = ((Get-Content $pubKey -Raw).Trim() -split '\s+')[0..1] -join ' '
        Write-Info "指纹: $fp"
    } else {
        Write-Fail "公钥 $pubKey 不存在 —— ssh-keygen -y -f `"$privKey`" > `"$pubKey`""
    }
} else {
    Write-Fail "私钥不存在 —— 运行 ssh-keygen -t ed25519 -C `"b-laptop`""
}

$authKeysHint = 'type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <vm用户名>@<100.x.y.z> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"'
Write-Info "推送公钥到 VM 的命令（手册 4.3）："
Write-Host "        $authKeysHint"

# ---------------------------------------------------------------------------
Write-Hr "3. SSH config 配置块"

$cfgPath = Join-Path $sshDir 'config'
$targetHost = $null
$targetUser = $null
$targetIp   = $null

if (Test-Path $cfgPath) {
    Write-Pass "config 存在: $cfgPath"
    $lines = Get-Content $cfgPath
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*Host\s+(.+)$') {
            $inBlock = ($Matches[1].Trim() -split '\s+') -contains $HostAlias
            continue
        }
        if ($inBlock) {
            if ($line -match '^\s*HostName\s+(\S+)') { $targetIp   = $Matches[1] }
            if ($line -match '^\s*User\s+(\S+)')     { $targetUser = $Matches[1] }
        }
    }
    if ($targetIp) {
        Write-Pass "找到 Host 块 [$HostAlias]"
        Write-Info "HostName = $targetIp"
        Write-Info "User     = $(if ($targetUser) { $targetUser } else { '<未设置>' })"

        if ($targetIp -match '^100\.') {
            Write-Pass "HostName 是 tailnet 地址 (100.x)，正确"
        } elseif ($targetIp -match '^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.') {
            Write-Fail "HostName 是私有局域网地址 —— 跨局域网不可用，必须填 Tailscale 的 100.x.y.z"
        } elseif ($targetIp -match '\.local$') {
            Write-Fail "HostName 是 mDNS 的 .local 名称 —— Windows 默认不带 mDNS 解析器，本机都解析不了（必然 'Could not resolve hostname'），跨局域网更不可能。必须改成 Tailscale 的 100.x.y.z"
        } else {
            Write-Warn2 "HostName 既不是 100.x 也不是常见私网地址，请确认填写正确"
        }

        $hasKeepAlive = ($lines | Select-String -Pattern 'ServerAliveInterval' -Quiet)
        if ($hasKeepAlive) { Write-Pass "已配置 ServerAliveInterval 保活" }
        else { Write-Warn2 "建议在 Host 块内加 ServerAliveInterval 30 / ServerAliveCountMax 6，防中继下空闲断连" }

        $hasIdentitiesOnly = ($lines | Select-String -Pattern 'IdentitiesOnly' -Quiet)
        if ($hasIdentitiesOnly) { Write-Pass "已配置 IdentitiesOnly" }
        else { Write-Warn2 "建议加 IdentitiesOnly yes，避免 Too many authentication failures" }
    } else {
        Write-Fail "config 里没有找到 Host 块 [$HostAlias] —— 请按手册 4.4 添加"
    }
} else {
    Write-Fail "$cfgPath 不存在 —— 请按手册 4.4 创建"
}

# ---------------------------------------------------------------------------
Write-Hr "4. 到 VM 的网络连通"

if ($targetIp) {
    # 必须写成 ${targetIp}：PowerShell 会把 "$targetIp:22" 当成作用域限定变量名而展开为空
    Write-Info "测试 TCP ${targetIp}:22 ..."
    try {
        $tcp = Test-NetConnection -ComputerName $targetIp -Port 22 -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) {
            Write-Pass "TCP ${targetIp}:22 可连接"
        } else {
            Write-Fail "TCP ${targetIp}:22 不通 —— 检查：A 的 VM 是否开机 / sshd 是否运行 / ufw 是否放行 tailscale0 / 宿主是否休眠"
        }
    } catch {
        Write-Warn2 "Test-NetConnection 执行失败: $($_.Exception.Message)"
    }
} else {
    Write-Info "跳过（没有解析到 HostName）"
}

try {
    if ($tsExe) {
        Write-Host "  --- tailscale ping $HostAlias ---"
        & $tsExe ping -c 3 $HostAlias 2>&1 | Select-Object -First 5 | ForEach-Object { Write-Host "        $_" }
        Write-Info "输出里的 'via DERP' 表示走了中继（延迟偏高但可用），direct 表示直连"
    }
} catch {
    Write-Warn2 "tailscale ping 失败 —— 确认别名与 tailnet 内的设备名一致，或直接用 100.x 地址"
}

# ---------------------------------------------------------------------------
Write-Hr "5. 端到端 SSH（免密）"

$sshExe = (Get-Command ssh.exe -ErrorAction SilentlyContinue).Source
if (-not $sshExe) {
    Write-Fail "系统未找到 ssh.exe —— 设置 → 应用 → 可选功能 → 添加「OpenSSH 客户端」"
} else {
    Write-Info "ssh: $sshExe"
    Write-Info "执行: ssh -o BatchMode=yes -o ConnectTimeout=10 $HostAlias hostname"
    $out = & $sshExe -o BatchMode=yes -o ConnectTimeout=10 $HostAlias 'hostname; uname -a' 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "SSH 免密登录成功，远端输出："
        $out | ForEach-Object { Write-Host "        $_" }
    } else {
        Write-Fail "SSH 失败（退出码 $LASTEXITCODE）："
        $out | Select-Object -First 10 | ForEach-Object { Write-Host "        $_" }
        Write-Info "常见原因见手册第 7 节排错速查表"
    }
}

# ---------------------------------------------------------------------------
Write-Hr "6. VS Code"

$codeExe = (Get-Command code.exe -ErrorAction SilentlyContinue).Source
$codeCmd = (Get-Command code.cmd -ErrorAction SilentlyContinue).Source
if (-not $codeExe) {
    $guessExe = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'
    if (Test-Path $guessExe) { $codeExe = $guessExe }
}
if (-not $codeCmd) {
    $guessCmd = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'
    if (Test-Path $guessCmd) { $codeCmd = $guessCmd }
}
# CLI 查询必须用 code.cmd：Code.exe 是 GUI 子系统程序，直接调用拿不到 stdout
$codeCli = if ($codeCmd) { $codeCmd } else { $codeExe }

if ($codeCli) {
    Write-Pass "VS Code: $(if ($codeExe) { $codeExe } else { $codeCli })"
    if ($codeCmd) { Write-Info "CLI: $codeCmd" }
    try {
        # VS Code --version 正常输出三行：版本 / 40位commit / 架构。
        # 按模式提取，避免把 stderr 上的杂音（日志、crashpad 报错）当成版本号。
        $cv = @(& $codeCli --version 2>&1 | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })
        $verLine    = ($cv | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Select-Object -First 1)
        $commitLine = ($cv | Where-Object { $_ -match '^[0-9a-f]{40}$' } | Select-Object -First 1)
        if (-not $verLine) { $verLine = $cv | Select-Object -First 1 }
        Write-Info "版本: $verLine"
        if ($commitLine) {
            Write-Info "commit: $commitLine   <-- 手册 4.7 离线预置 vscode-server 要用这个"
        } else {
            Write-Warn2 "未能从 --version 输出解析出 commit（可能被日志干扰），可在 VS Code「帮助 -> 关于」里手抄"
        }
    } catch {
        Write-Warn2 "无法获取 VS Code 版本: $($_.Exception.Message)"
    }
} else {
    Write-Warn2 "未在常见路径找到 VS Code（若已装可忽略；用 code --version 自行确认）"
}

if ($codeCli) {
    Write-Info "检查 Remote-SSH 扩展 ..."
    try {
        $exts = @(& $codeCli --list-extensions 2>&1)
        if ($exts -match 'ms-vscode-remote\.remote-ssh') {
            Write-Pass "已安装 Remote - SSH (ms-vscode-remote.remote-ssh)"
        } else {
            Write-Fail "未安装 Remote - SSH —— 扩展面板搜 'Remote - SSH' 安装"
        }
        if ($exts -match 'ms-vscode\.remote-server') {
            Write-Info "也装了 Remote - Tunnels（手册第 9 节备份方案可用）"
        }
    } catch {
        Write-Warn2 "无法枚举扩展: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
Write-Hr "7. 宿主机休眠（仅提醒）"
Write-Info "本脚本无法检查 A 的 Windows 宿主。请确认 A 的电源计划里「睡眠」= 从不，"
Write-Info "且 VMware 里的 Ubuntu 已 mask sleep.target，否则无人值守场景会失联。"

# ---------------------------------------------------------------------------
Write-Host "`n================ 自检结束 ================" -ForegroundColor White
if ($script:Failed -eq 0) {
    Write-Host "关键项全部通过。接下来：VS Code -> F1 -> Remote-SSH: Connect to Host... -> $HostAlias" -ForegroundColor Green
    exit 0
} else {
    Write-Host "有 $script:Failed 项未通过。逐条修复后重跑本脚本。" -ForegroundColor Red
    exit 1
}
