# new-vps-harden - VPS SSH Hardening Script

[![Release](https://img.shields.io/github/v/release/superchaospc/new-vps-harden?sort=semver)](https://github.com/superchaospc/new-vps-harden/releases)
[![ShellCheck](https://img.shields.io/badge/shellcheck-passing-brightgreen)](https://www.shellcheck.net/)
[![License](https://img.shields.io/github/license/superchaospc/new-vps-harden)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-blue)](#requirements)

一个面向新买 Debian/Ubuntu VPS 的 SSH 快速加固脚本。

`new-vps-harden` is a small Bash script for hardening SSH on fresh Debian and Ubuntu VPS servers. It is designed for public cloud VPS instances where SSH is exposed to the internet and the default port `22` is constantly scanned.

它适合公网 SSH 暴露、默认 22 端口会被持续扫描的新 VPS。脚本会关闭密码登录、限制 root 密码登录、调整 SSH 未认证连接上限、安装并启用 fail2ban。不传端口时，脚本会先检测当前 SSH 端口：如果仍在使用 `22`，会新增默认高位端口 `52222`；如果已经是非 22 端口，则沿用当前端口，只做其它加固。

## Keywords

`vps hardening`, `ssh hardening`, `linux server security`, `debian vps`, `ubuntu vps`, `fail2ban`, `disable ssh password login`, `change ssh port`, `server bootstrap`, `vps security`

## When To Use

适合使用这个脚本的 VPS：

- 新买的 Debian/Ubuntu VPS
- 公网 IP 直接暴露 SSH
- SSH 仍在默认 `22` 端口
- VPS 默认允许密码登录
- 机器来自小厂、低价海外机房，公网扫描流量较多
- 你打算长期保留这台机器，而不是用完就删

不一定需要使用这个脚本的 VPS：

- 云厂商安全组已经只允许你的固定 IP 访问 SSH
- SSH 只在内网、VPN、Tailscale 或 WireGuard 后面开放
- 机器是临时测试机，短时间内会销毁
- 你已经有 Ansible、Terraform、cloud-init 等安全基线
- 镜像不是 Debian/Ubuntu，或者不是 systemd 系统
- 镜像默认已经禁用密码登录，并且你只使用非 root 用户登录

## Features

- Harden SSH on fresh Debian/Ubuntu VPS servers
- Disable SSH password authentication
- Restrict root password login
- Auto-detect the current SSH port before changing it
- Change the SSH port while keeping the current port as a temporary fallback
- Install and enable fail2ban for SSH brute-force protection
- Use fail2ban's systemd backend for modern Debian/Ubuntu images
- Open the new SSH port in UFW when UFW is active
- Roll back the SSH drop-in if validation or restart fails
- 当前 SSH 仍使用 `22` 时,默认新增 SSH 端口 `52222`
- 当前 SSH 已经是非 `22` 端口时,默认沿用当前端口
- 改端口时保留旧端口,方便回退
- 禁用 SSH 密码登录
- 禁止 root 使用密码登录
- 调整 `MaxStartups` 和 `LoginGraceTime`
- 安装并重启 `fail2ban`
- fail2ban 使用 `backend = systemd`
- 如果 UFW 已启用,自动放行新 SSH 端口
- 如果 `sshd -t` 或 SSH 重启失败,自动恢复旧 drop-in 配置
- 使用 `sshd -T` 和 `ss` 验证实际生效配置
- 兼容 `ssh.service` / `sshd.service`

## Requirements

- Debian 或 Ubuntu 默认镜像
- root 权限
- systemd
- `apt-get`
- 已提前把本机 SSH 公钥放进 `/root/.ssh/authorized_keys`
- 已确认可以用密钥登录 VPS

## Quick Start

先把本机公钥推到新 VPS：

```bash
ssh-copy-id root@<ip>
ssh root@<ip>
```

确认密钥登录可用后，在 VPS 上直接从 GitHub Release 下载并执行：

```bash
curl -fsSL -o /root/new-vps-harden.sh \
  https://github.com/superchaospc/new-vps-harden/releases/latest/download/new-vps-harden.sh

bash /root/new-vps-harden.sh
```

也可以从本机一条命令远程执行：

```bash
ssh root@<ip> '
  curl -fsSL -o /root/new-vps-harden.sh https://github.com/superchaospc/new-vps-harden/releases/latest/download/new-vps-harden.sh &&
  bash /root/new-vps-harden.sh
'
```

默认行为：

- 如果当前 SSH 仍在 `22` 端口，脚本会新增 `52222`，并暂时保留 `22`。
- 如果当前 SSH 已经不是 `22` 端口，脚本会沿用当前端口，只做其它加固。

你也可以显式指定端口：

```bash
bash /root/new-vps-harden.sh 12345
```

如果只想保留 22 端口，不换端口：

```bash
bash /root/new-vps-harden.sh 22
```

## After Running

如果脚本新增了端口，跑完后会同时监听旧端口和新端口。请按这个顺序收尾：

1. 确认云厂商安全组或面板防火墙已经放行新端口。
2. 从一个新终端窗口验证新端口能登录。

```bash
ssh -p 52222 root@<ip>
```

3. 验证成功后，在 VPS 上编辑 drop-in 配置，删除不再需要的旧端口 `Port` 行，并重启 SSH。

```bash
nano /etc/ssh/sshd_config.d/99-hardening.conf
systemctl restart ssh || systemctl restart sshd
```

4. 更新本机 `~/.ssh/config`。

```sshconfig
Host my-vps
    HostName <ip>
    User root
    Port 52222
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

## Notes

- 端口只接受 `22` 或 `1024-65535`，避免误占用 `80`、`443`、`53` 等常见服务端口。
- 脚本针对刚买的新 VPS 默认镜像设计，不追求覆盖复杂自定义镜像。
- 如果 VPS 已经在安全组白名单、VPN、Tailscale 或 WireGuard 后面，这个脚本不一定必要。
- 如果 `apt-get` 源临时失败，SSH 加固可能已经完成，但 fail2ban 安装会中断。
- 如果本机 UFW 已启用，脚本会在新增 SSH 端口时自动执行 `ufw allow <port>/tcp`。

## License

MIT
