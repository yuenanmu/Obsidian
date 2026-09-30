---
tags:
  - 跨局域网远程连接
created: 2026-09-30
---


# VS Code 跨局域网远程连接手册

**场景**：B 轻薄本（已装 VS Code）在任意网络下 → A 重笔记本里的 Ubuntu 22.04 虚拟机。
**方案**：两端加入同一个 Tailscale tailnet，A 的 VM 内跑 OpenSSH，B 用 VS Code Remote-SSH 连 `100.x.y.z`。
**不需要**：公网 IP、路由器端口映射、DDNS；也**不向公网暴露任何端口**。

> **占位符提醒**：全文需要你替换的只有三处 —— `<vm用户名>`、`100.x.y.z`、`<commit>`。

---

## 0. 三句话速览

1. A 的 VMware VM **保持 NAT 模式**，在 **VM 内部**装 `openssh-server` + `tailscale`。
2. B 装 Tailscale 客户端（同一账号），配好 SSH 密钥和 `~/.ssh/config`。
3. VS Code 装 `Remote - SSH` 扩展，直接连 `ubuntu-vm`。

---

## 1. 最终架构

```
[B 轻薄本]  Tailscale 客户端 (Windows / macOS)
     |
     |  WireGuard 加密隧道，走 tailnet 100.x 网段
     |  (校园网封 UDP 时自动回落 DERP 中继，走 TCP/443)
     v
[A 重笔记本 · Windows 宿主]
     |
     +-- VMware Workstation  (NAT 模式，保持默认，别改桥接)
            |
            +-- Ubuntu 22.04 VM   <-- Tailscale 装在这一层
                   +-- tailscaled   -> 拿到稳定的 100.x.y.z
                   +-- sshd :22     <-- VS Code Remote-SSH 的落点
```

### 1.1 为什么 Tailscale 装在 VM 内部，而不是 Windows 宿主

| 做法 | 代价 |
|---|---|
| 装在 Windows 宿主 | 还要配 VMware NAT 端口转发（vmnet8 映射 22 → VM）、加 Windows 防火墙入站规则、VM 私网 IP 一变就得跟着改。链路多一跳，故障点从 1 个变 3 个。 |
| **装在 VM 内部（本方案）** | VM 在 NAT 下出站本来就正常，而 Tailscale 是**纯出站**连接，对 NAT 天生友好。VM 拿到自己的 `100.x`，VMware DHCP 把 VM 分到什么地址都与你无关。 |

### 1.2 为什么 VM 必须保持 NAT，不要改桥接

校园网/宿舍以太网普遍要求 Portal 网页认证（深澜、Dr.COM 之类）或做 MAC 绑定。
- **桥接模式**：VM 会拿到一个校园网 IP，需要**自己再过一次认证**，常见结局是压根上不了网 —— 这是最容易浪费一晚上的坑。
- **NAT 模式**：VM 复用宿主机已经认证好的链路，出站直接可用。

---

## 2. 前置检查（动手前先确认这 4 条）

在 A 的 Ubuntu VM 里执行：

```bash
lsb_release -a                      # 确认是 22.04
ip -4 addr                          # 确认 VM 有 ip（NAT 下通常是 192.168.x.x）
ping -c3 223.5.5.5                  # 确认基本出站通
ping -c3 packages.microsoft.com     # 确认域名解析 + HTTPS 可达
curl -sI https://login.tailscale.com | head -n1   # 确认 Tailscale 控制面可达
```

在 A 的 Windows 宿主里确认：**VMware 的 VM 网络设置为「NAT」**（虚拟机设置 → 网络适配器 → NAT）。

---

## 3. A 侧实施（Ubuntu 22.04 虚拟机）

### Step 0 · 把脚本送进 VM（可选，但推荐）

`远程开发/scripts/` 下有可直接用的脚本。传到 VM 的三种办法，任选：

1. **最简单**：先用密码 SSH 连上 VM（`ssh <vm用户名>@<VM的NAT地址>`），在 VS Code 里把脚本拖进远程窗口。
2. **纯终端**：在 VM 里 `nano ~/install-ubuntu-vm.sh`，把内容粘进去。
3. **共享文件夹**：VMware 共享目录挂载后 `cp`。

> **换行符警告**：脚本在 Windows 上生成，经共享文件夹复制到 Linux 后可能带 CRLF，报
> `bash: $'\r': command not found`。修复：
> ```bash
> sed -i 's/\r$//' install-ubuntu-vm.sh
> # 若开头有 BOM（罕见），一并去掉：
> sed -i '1s/^\xEF\xBB\xBF//' install-ubuntu-vm.sh
> head -n1 install-ubuntu-vm.sh   # 必须精确是 #!/usr/bin/env bash
> ```

一键安装（幂等，可重复运行）：

```bash
chmod +x install-ubuntu-vm.sh
./install-ubuntu-vm.sh                      # 装 sshd + VS Code + Tailscale
./install-ubuntu-vm.sh --fix-ufw            # 额外放行 ufw 的 tailscale0 / OpenSSH
./install-ubuntu-vm.sh --disable-suspend    # 额外屏蔽 VM 内休眠
```

下面 Step 1–6 是它做的事的手工版本，便于你理解或分步排错。

### Step 1 · 装 OpenSSH server（Remote-SSH 的真正前提）

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
systemctl status ssh --no-pager
ss -tlnp | grep :22
```

### Step 2 · 装 VS Code（Microsoft 官方 apt 源，架构自适应）

```bash
sudo apt-get install -y wget gpg apt-transport-https ca-certificates
ARCH=$(dpkg --print-architecture)

wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor > /tmp/packages.microsoft.gpg
sudo install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg \
  /etc/apt/keyrings/packages.microsoft.gpg
rm -f /tmp/packages.microsoft.gpg

echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
  | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null

sudo apt-get update
sudo apt-get install -y code
code --version
```

**源慢/被墙时的直连 .deb 兜底：**

```bash
wget -O /tmp/code.deb "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64"
sudo apt-get install -y /tmp/code.deb
```

> VS Code 装在 VM 里，主要用途是让你**在 A 本机的图形界面里用**，以及提供 `code` CLI（第 9 节的 `code tunnel` 备份方案需要它）。
> **Remote-SSH 的服务端并不需要它** —— 只要有 `sshd` 就够了。

### Step 3 · 装 Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled

sudo tailscale up        # 会打印一个 URL，浏览器打开并用账号登录
tailscale ip -4          # <<< 记下这个 100.x.y.z
tailscale status
```

![image-20260930144613176](image-20260930144613176.png)

![image-20260930144802275](image-20260930144802275.png)

> **暂不要加 `--ssh` 参数。** Tailscale SSH 会接管 tailnet 内到 22 端口的流量，并把认证方式换成 tailnet 身份，会干扰 VS Code Remote-SSH 的密钥流程。先用标准 OpenSSH 跑通，之后想切换再单独试。

### Step 4 · UFW 放行 tailscale0（只在 ufw 已启用时才需要，但属于高频坑）

```bash
sudo ufw status verbose

# 如果 Status: active，则必须加这两条：
sudo ufw allow in on tailscale0
sudo ufw allow OpenSSH
```

原因：ufw 默认拒绝入站，会把 tailnet 流量一起挡掉，症状是「`tailscale ping` 通、`ssh` 不通」。

### Step 5 · 禁止休眠

**VM 内：**

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
# 图形界面路径：设置 → 电源 → 自动挂起 → 关闭；黑屏 → 从不
```

**Windows 宿主机（同样重要，别漏）：**
控制面板 → 电源选项 → 更改计划设置 → 使计算机进入睡眠状态 → **从不**。

> 宿主一睡，VM 和 Tailscale 一起掉。这是「跨局域网随时可用」的真正前提。

### Step 6 · 收 SSH 公钥

等 B 侧生成公钥后推过来（见 4.3），然后**回 A 侧关掉密码登录**。

编辑 `/etc/ssh/sshd_config.d/99-remote.conf`（没有就新建）：

```
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
```

```bash
sudo systemctl restart ssh
```

> **顺序很重要**：先确认密钥能免密登录，**再**关密码。反了会把自己锁在 VM 外面，届时只能通过 VMware 控制台进去补救。

### Step 7 · 自检

![image-20260930143446443](image-20260930143446443-17907500889102.png)

![image-20260930143523248](image-20260930143523248-17907501264203.png)

```bash
chmod +x check-ubuntu-vm.sh && ./check-ubuntu-vm.sh
```

---

## 4. B 侧实施（Windows 轻薄本，VS Code 已装）

### 4.1 装 Tailscale 客户端

下载安装后，**用与 A 完全相同的账号**登录（同一 tailnet）。确认列表里能看到 A 的 VM：

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" status
```

### 4.2 生成 ED25519 密钥

```powershell
ssh-keygen -t ed25519 -C "b-laptop"
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
```

### 4.3 推送公钥到 VM（先用密码登录一次）

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <vm用户名>@100.x.y.z "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

推完立刻验证免密：

```powershell
ssh -o BatchMode=yes -o ConnectTimeout=10 <vm用户名>@100.x.y.z "hostname"
```

![image-20260930143133549](image-20260930143133549.png)

**上一条成功之后**，再回 A 侧执行 3.Step 6 关闭密码登录。

### 4.4 写 `C:\Users\<你>\.ssh\config`

```
Host ubuntu-vm
    HostName 100.x.y.z                  # 或 MagicDNS 名 vm-name.tailxxxx.ts.net #unbuntu输入指令hostname查询
    User <vm用户名>						#输入whoami查询
    IdentityFile ~/.ssh/id_ed25519		# B电脑私钥
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 6
    TCPKeepAlive yes
    IPQoS none
```

- `ServerAliveInterval 30` + `ServerAliveCountMax 6`：走 DERP 中继时防空闲断连，**强烈建议保留**。
- `IPQoS none`：规避部分网络下 SSH 交互卡顿。
- `IdentitiesOnly yes`：避免密钥太多时被服务端拒绝（`Too many authentication failures`）。

> **绝对不要用 `.local` 名字。** `ubuntu-virtual-machine.local` 这类 mDNS 名称在 Windows 上**默认解析不了**（Windows 不带 mDNS 解析器），报错就是 `Could not resolve hostname`。它只在「同一局域网 + 装了 Bonjour」时才可能可用，跨局域网必然失败。
> **`HostName` 必须写 Tailscale 的 `100.x.y.z`**（或 Tailscale MagicDNS 名）。如果你已经有一条 `HostName xxx.local` 的配置块，把它改成 100.x 地址即可，其余行不用动。

### 4.5 命令行验证

```powershell
& "C:\Program Files\Tailscale\tailscale.exe" ping ubuntu-vm
ssh ubuntu-vm "hostname; uname -a; ip -4 addr show tailscale0"
```

`tailscale ping` 输出里会标明走的是 `via DERP(...)` 还是直连 —— 这是判断链路质量的关键信息。

### 4.6 VS Code 连接

1. 扩展面板搜 `ms-vscode-remote.remote-ssh`（**Remote - SSH**）并安装。
2. `F1`（或 `Ctrl+Shift+P`）→ `Remote-SSH: Connect to Host...` → 选 `ubuntu-vm`。
3. 首次连接会在远端装 `vscode-server`，等它跑完。

建议写入 B 的 `settings.json`：

```json
{
  "remote.SSH.useLocalServer": true,
  "remote.SSH.connectTimeout": 60,
  "remote.SSH.showLoginTerminal": true
}
```

> **卡在 "Setting up SSH Host…" 时的第一招**：把 `remote.SSH.useLocalServer` 改成 `false` 再重连。

### 4.7 vscode-server 首次下载失败的离线预置（国内校园网高频问题）

**症状**：VS Code 反复卡在 "Setting up SSH Host" / "Downloading VS Code Server"，日志里是 `update.code.visualstudio.com` 超时。

**步骤：**

1. 在 **B 的 VS Code** → 帮助 → 关于，抄下那串 40 位 **Commit**（服务端必须与客户端 commit 严格一致）。
2. 在 A 的 VM 上：

```bash
C=<粘贴commit>
mkdir -p ~/.vscode-server/bin/$C
wget -O /tmp/vs.tgz "https://update.code.visualstudio.com/commit:${C}/server-linux-x64/stable"
tar -xzf /tmp/vs.tgz -C ~/.vscode-server/bin/$C --strip-components=1
touch ~/.vscode-server/bin/$C/0     # 标记文件，缺了会被当成未安装而重新下载
ls ~/.vscode-server/bin/$C/bin/code-server
```

3. 回 B 重连。

若 A 的 VM 也下不动这个 URL：在 B 上下载后 `scp` 过去，或改用第 9 节的 `code tunnel` 方案。

### 4.8 自检

```powershell
powershell -ExecutionPolicy Bypass -File .\check-windows-b.ps1
```

### 4.9 macOS 变体（若 B 是 Mac）

```bash
brew install --cask tailscale          # 客户端
ssh-keygen -t ed25519 -C "b-laptop"    # 密钥，路径同为 ~/.ssh/
cat ~/.ssh/id_ed25519.pub | ssh <vm用户名>@100.x.y.z "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

`~/.ssh/config` 写法与 Windows 完全一致。VS Code 侧步骤相同。

---

## 5. 重点注意事项（按踩坑概率排序）

1. **180 天密钥过期** —— 「某天突然全部连不上」的头号原因。
   登录 Tailscale admin console → Machines → 找到 A 的 VM → **Disable key expiry**。
   （或者给设备打 tag + 用 auth key 自动续期，适合长期无人值守。）

2. **UFW 拦 tailscale0** —— 默认拒绝入站会把 tailnet 流量一起挡掉。表现为 `tailscale ping` 通但 `ssh` 不通。
   `sudo ufw allow in on tailscale0`。

3. **宿主休眠 = 全链路断** —— VM 内 `systemctl mask` 和 Windows 电源计划，两边都要设。

4. **UDP 被封时 Tailscale 回落 DERP 中继** —— 仍然可用，但延迟会明显升高（几十到几百 ms），VS Code 会有钝感。
   用 `tailscale ping` / `tailscale netcheck` 判断是直连还是中继。
   若出现 SSH 交互卡死，把 tailnet 接口 MTU 降下来：
   ```bash
   sudo ip link set dev tailscale0 mtu 1280
   ```

5. **别改桥接** —— 校园网 Portal 认证会让桥接的 VM 上不了网。

6. **先验密钥、再关密码** —— 顺序反了会被锁在 VM 外。

7. **`tailscaled` 开机自启兜底**：`sudo systemctl enable --now tailscaled`（apt 安装通常已自动启用）。

8. **不要为这件事开放任何公网端口** —— tailnet 内已加密且只有你自己的设备可达，攻击面为零；反而去开公网 22 是把安全责任全揽过来。

9. **中继下长时间编译易断** —— 远端跑 `tmux`（或 `mosh`）比什么都管用。

10. **校园网 Portal 掉线会连带 VM 断网** —— 这是链路固有属性，不是配置错误。宿舍夜间断网同理。

11. **VMware 的 NAT DHCP 会变 IP，但不影响你** —— 因为你连的是 Tailscale 的 `100.x`，不是 `192.168.x`。这正是选它的原因之一。

---

## 6. 验收清单

| # | 检查项 | 命令 / 操作 | 期望 |
|---|---|---|---|
| 1 | A 的 VM 拿到 tailnet IP | A: `tailscale ip -4` | 输出 `100.x.y.z` |
| 2 | B 能看到对端且连通 | B: `tailscale ping ubuntu-vm` | 有 `pong`，并注明了 direct 或 DERP |
| 3 | SSH 免密 | B: `ssh -o BatchMode=yes ubuntu-vm true` | 退出码 0，无密码提示 |
| 4 | VS Code 端到端 | 连接 `ubuntu-vm` | 左下角显示 `SSH: ubuntu-vm`；能开文件树和集成终端 |
| 5 | 远程扩展可用 | 在远程窗口装一个扩展（如 Python） | 安装成功并显示在「已安装到 SSH: ubuntu-vm」 |
| 6 | **重启韧性** | 重启 A 的 VM，不做任何人工登录，等 2 分钟 | B 直接 `ssh ubuntu-vm` 仍成功 |
| 7 | **跨网络韧性** | B 从校园网切到手机热点 | `ssh ubuntu-vm` 仍成功 |
| 8 | 空闲保活 | 放置 2–4 小时后再连 | 仍能连上（第 4 条保活生效） |

第 6 条最重要 —— 它验证了「无人值守可用」，否则每次 A 重启你都得跑回宿舍登一次。

---

## 7. 排错速查表

| 症状 | 最可能原因 | 动作 |
|---|---|---|
| `tailscale status` 看不到对端 | 两端账号不同 / 设备未授权 | 检查登录账号；admin console 看设备列表 |
| tailscale ping 通，ssh 不通 | sshd 未启 / ufw 拦 tailscale0 / 端口不同 | `systemctl status ssh`；`sudo ufw allow in on tailscale0` |
| `Permission denied (publickey)` | 公钥没写进 / 权限过宽 / 密钥太多 | `chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys`；config 加 `IdentitiesOnly yes` |
| `Connection refused` | 22 没在监听 | `ss -tlnp \| grep :22`；`systemctl restart ssh` |
| `Connection timed out` | tailnet 没通 / 对端离线 | `tailscale status` 看对端是否 offline；查宿主是否休眠 |
| VS Code 卡在 "Setting up SSH Host" | vscode-server 下载失败 | 看 `~/.vscode-server/` 下日志；走 4.7 离线预置；先试 `useLocalServer: false` |
| 连接慢、频繁掉线 | 走了 DERP 中继 | `tailscale netcheck`；降 MTU 到 1280；考虑第 9 节 frp 方案 |
| 早上来就断了 | 宿主或 VM 休眠 | 查两侧电源设置（3.Step 5） |
| 某天突然全部失效 | key expiry 到期（180 天） | admin console 关闭密钥过期 |
| `tailscale up` 打不开登录页 | 控制面被墙/不可达 | 走第 9 节阶梯 |

---

## 8. 日常运维

**A 侧 VM 重启后**：正常情况下你什么都不用做 —— `tailscaled` 和 `ssh` 都已 `enable`。若连不上：

```bash
sudo systemctl status tailscaled ssh
sudo tailscale up
tailscale ip -4
```

**改变端口 / 加固（可选）**：tailnet 已经是私有的，改 SSH 端口收益不大。若仍想改，编辑 `/etc/ssh/sshd_config` 的 `Port`，并同步 B 的 `~/.ssh/config` 里的 `Port`。

**撤销/回滚**：

```bash
# A 侧 VM
sudo tailscale down && sudo tailscale logout
sudo apt-get remove --purge -y tailscale code
sudo systemctl disable --now ssh
sudo ufw delete allow in on tailscale0
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
# admin console 里删除该设备
```

B 侧卸载 Tailscale 客户端、删掉 `~/.ssh/config` 里的 `ubuntu-vm` 段即可。

---

## 9. 备份方案阶梯（当前不实施）

| 顺位 | 方案 | 适用条件 | 代价 |
|---|---|---|---|
| 1 | **Tailscale（本方案）** | 默认 | 需第三方账号；控制面偶尔在校园网不可达 |
| 2 | **ZeroTier**（自建 Moon） | Tailscale 控制面连不上 | 国内中继质量参差，配置略繁琐 |
| 3 | **VPS + frp 反向代理** | 你有一台云服务器 | 完全自控、不受第三方影响；需自己维护隧道和安全组 |
| 4 | **VS Code Tunnel** | 什么都没有，只想最快跑通 | 走微软中继，依赖其可用性；但只需 HTTPS 出站，穿透力最强 |

**方案 4 的最小用法**（A 的 VM 上，利用你刚装好的 VS Code）：

```bash
code tunnel --accept-server-license-terms
# 按提示用 GitHub/Microsoft 账号登录，记下分配的隧道名
```

B 侧装 `ms-vscode.remote-server`（Remote - Tunnels）扩展，或直接浏览器打开 `vscode.dev`，选择该隧道即可。**注意这条路径不经过 SSH**，与上面的排错表不通用。

---

## 10. 附：本目录文件

| 文件 | 用途 | 运行位置 |
|---|---|---|
| `VSCode跨局域网远程连接手册.md` | 本文档 | — |
| `scripts/install-ubuntu-vm.sh` | 一键安装 sshd + VS Code + Tailscale（幂等） | A 的 Ubuntu VM |
| `scripts/check-ubuntu-vm.sh` | 只读自检 | A 的 Ubuntu VM |
| `scripts/check-windows-b.ps1` | 只读自检 | B（Windows） |

**文件编码约定（别改错，改了会坏）：**

- `scripts/*.sh` → **UTF-8 无 BOM + LF 换行**。传到 Linux 上若变成 CRLF，会报 `bash: $'\r': command not found`，修复见 3.Step 0。
- `scripts/check-windows-b.ps1` → **UTF-8 带 BOM（刻意如此）**。Windows PowerShell 5.1 读取「无 BOM 的 UTF-8」文件时按系统 ANSI 解码，中文字符串的字节会把后面的引号吞掉，整份脚本直接语法崩坏。用 VS Code 编辑时请保留 BOM。

---

## 11. 显式假设

- A 的 Windows 宿主已装好 VMware Workstation + Ubuntu 22.04 桌面版 VM，且 VM 当前能正常上网。
- B 为 Windows 笔记本，已装 VS Code；第 4.9 节给出了 macOS 变体。
- 两端均能访问 `login.tailscale.com`。若不能，请走第 9 节阶梯。
- 文中命令按 Ubuntu 22.04 LTS 与 Tailscale 现行 CLI 编写；`packages.microsoft.com` 与 `update.code.visualstudio.com` 的可用性受网络环境影响。
