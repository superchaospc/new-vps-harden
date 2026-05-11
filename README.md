# new-vps-harden

[![Release](https://img.shields.io/github/v/release/superchaospc/new-vps-harden?sort=semver)](https://github.com/superchaospc/new-vps-harden/releases)
[![ShellCheck](https://img.shields.io/badge/shellcheck-passing-brightgreen)](https://www.shellcheck.net/)
[![License](https://img.shields.io/github/license/superchaospc/new-vps-harden)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-blue)](#requirements)

一个面向新买 Debian/Ubuntu VPS 的 SSH 快速加固脚本。

它适合公网 SSH 暴露、默认 22 端口会被持续扫描的 VPS。脚本会关闭密码登录、限制 root 密码登录、调整 SSH 未认证连接上限、安装并启用 fail2ban。默认会新增高位 SSH 端口，同时保留 22 端口，避免你在验证新端口前把自己锁在外面。

## Features

- 默认新增 SSH 端口 `52222`
- 改端口时保留 `22`，方便回退
- 禁用 SSH 密码登录
- 禁止 root 使用密码登录
- 调整 `MaxStartups` 和 `LoginGraceTime`
- 安装并重启 `fail2ban`
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

确认密钥登录可用后，把脚本传上去并执行：

```bash
scp new-vps-harden.sh root@<ip>:/root/
ssh root@<ip> 'bash /root/new-vps-harden.sh'
```

默认会新增 `52222` 端口。你也可以指定端口：

```bash
ssh root@<ip> 'bash /root/new-vps-harden.sh 12345'
```

如果只想保留 22 端口，不换端口：

```bash
ssh root@<ip> 'bash /root/new-vps-harden.sh 22'
```

## After Running

如果你使用了新端口，脚本跑完后会同时监听 `22` 和新端口。请按这个顺序收尾：

1. 确认云厂商安全组或面板防火墙已经放行新端口。
2. 从一个新终端窗口验证新端口能登录。

```bash
ssh -p 52222 root@<ip>
```

3. 验证成功后，在 VPS 上删除 `Port 22` 并重启 SSH。

```bash
sed -i '/^Port 22$/d' /etc/ssh/sshd_config.d/99-hardening.conf
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

## License

MIT
