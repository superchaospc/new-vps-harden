#!/usr/bin/env bash
# new-vps-harden.sh - 加固新 VPS 的 SSH
#
# 用法 (在新 VPS 上以 root 执行):
#   bash new-vps-harden.sh                # 默认改为 52222 端口
#   bash new-vps-harden.sh 22             # 不换端口,只关密码 + 加 fail2ban
#   bash new-vps-harden.sh 12345          # 自定义端口
#
# 安全设计:
# - 改端口时【同时保留 22】,验证新端口可用后再手动删 22,避免锁出
# - 改完用 sshd -T 抓实际生效值,关键项不达标直接 abort
# - 兼容 ssh.service / sshd.service

set -euo pipefail

PORT="${1:-52222}"

# --- 0. 前置检查 -------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "ERR: 需要 root"; exit 1; }
[[ -s /root/.ssh/authorized_keys ]] || {
  echo "ERR: /root/.ssh/authorized_keys 为空或不存在。" >&2
  echo "     先用 ssh-copy-id 推公钥并验证密钥能登,再跑此脚本。" >&2
  exit 1
}
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || { (( 10#$PORT != 22 )) && (( 10#$PORT < 1024 || 10#$PORT > 65535 )); }; then
  echo "ERR: 非法端口: $PORT (允许 22 或 1024-65535,避免占用 80/443/53 等常见服务端口)"
  exit 1
fi
PORT=$((10#$PORT))   # 归一化,去掉前导零

# --- 1. 写 sshd drop-in ------------------------------------------------------
mkdir -p /etc/ssh/sshd_config.d
DROPIN=/etc/ssh/sshd_config.d/99-hardening.conf

{
  if [[ "$PORT" != "22" ]]; then
    # 同时监听,防锁出去;确认新端口通后再手动删 "Port 22"
    echo "Port 22"
    echo "Port ${PORT}"
  fi
  cat <<EOF
PasswordAuthentication no
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
MaxStartups 30:60:100
LoginGraceTime 20
EOF
} > "$DROPIN"

# --- 2. 重启 sshd ------------------------------------------------------------
sshd -t
SVC=ssh
systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service' \
  && ! systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service' \
  && SVC=sshd
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl restart "$SVC"
sleep 1

# --- 3. 用 sshd -T 验证【实际生效值】 ---------------------------------------
get() { sshd -T 2>/dev/null | awk -v k="${1,,}" 'tolower($1)==k {print $2; exit}'; }
PW=$(get passwordauthentication)
ROOT=$(get permitrootlogin)
LISTEN=$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -u | tr '\n' ' ')

echo "----- effective config -----"
printf "  PasswordAuth = %s  (want: no)\n" "$PW"
printf "  PermitRoot   = %s  (want: prohibit-password)\n" "$ROOT"
printf "  Listening    = %s\n" "$LISTEN"
echo "----------------------------"

[[ "$PW"   == "no" ]]                  || { echo "ABORT: PasswordAuthentication 未关闭(可能被主配置覆盖,检查 /etc/ssh/sshd_config)"; exit 1; }
[[ "$ROOT" == "prohibit-password" ]]   || { echo "ABORT: PermitRootLogin 未限制"; exit 1; }
echo " $LISTEN " | grep -q " $PORT "   || { echo "ABORT: 端口 $PORT 未真正监听"; exit 1; }

# --- 4. fail2ban -------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq fail2ban

JAIL_PORTS=$([[ "$PORT" == "22" ]] && echo 22 || echo "22,${PORT}")
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
port     = ${JAIL_PORTS}
maxretry = 4
findtime = 10m
bantime  = 1h
EOF
systemctl enable fail2ban
systemctl restart fail2ban
sleep 1
fail2ban-client status sshd || true

# --- 5. 汇报 + 下一步 --------------------------------------------------------
echo
echo "============================================================"
echo "  SSH 加固完成"
echo "============================================================"
if [[ "$PORT" != "22" ]]; then
  cat <<EOF

⚠️  当前【22 和 ${PORT} 同时监听】(防止锁出去)。请按以下顺序收尾:

  1. 确认云厂商安全组 / 面板防火墙已放行 ${PORT} 端口
  2. 从【新窗口】验证新端口能登:
        ssh -p ${PORT} root@<ip>
  3. 验证通过后,在 VPS 上关掉 22:
        sed -i '/^Port 22\$/d' ${DROPIN} && systemctl restart ${SVC}
  4. 本地 ~/.ssh/config 给这台机器加:  Port ${PORT}

如果新端口连不上:不要慌,22 端口仍开着,可继续 ssh root@<ip> 进来排查。
EOF
fi
