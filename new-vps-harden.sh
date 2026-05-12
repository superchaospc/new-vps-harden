#!/usr/bin/env bash
# new-vps-harden.sh - 加固新 VPS 的 SSH
#
# 用法 (在新 VPS 上以 root 执行):
#   bash new-vps-harden.sh                # 自动检测:当前是 22 才新增 52222
#   bash new-vps-harden.sh 22             # 不换端口,只关密码 + 加 fail2ban
#   bash new-vps-harden.sh 12345          # 自定义端口
#
# 安全设计:
# - 不传端口时先检测当前 SSH 端口,已非 22 则沿用当前端口
# - 改端口时【同时保留当前端口】,验证新端口可用后再手动删除旧端口,避免锁出
# - 使用 00-hardening.conf 抢在云镜像自带的 00-* drop-in 前生效
# - 改完用 sshd -T 抓实际生效值,关键项不达标直接 abort
# - 兼容 ssh.service / sshd.service

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERR: 需要 bash 4 或更高版本。" >&2
  exit 1
fi

DEFAULT_PORT=52222
REQUESTED_PORT="${1:-}"
DROPIN=/etc/ssh/sshd_config.d/00-hardening.conf
LEGACY_DROPIN=/etc/ssh/sshd_config.d/99-hardening.conf

get_ports() {
  sshd -T 2>/dev/null | awk 'tolower($1)=="port" {print $2}' | sort -nu | tr '\n' ' '
}

get_external_config_ports() {
  local file
  local files=()
  [[ -e /etc/ssh/sshd_config ]] && files+=(/etc/ssh/sshd_config)
  for file in /etc/ssh/sshd_config.d/*.conf; do
    [[ -e "$file" && "$file" != "$DROPIN" && "$file" != "$LEGACY_DROPIN" ]] && files+=("$file")
  done
  ((${#files[@]} == 0)) && return 0
  awk 'tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2}' "${files[@]}" 2>/dev/null | sort -nu | tr '\n' ' '
}

get_listening_ports() {
  ss -H -tlnp 2>/dev/null | awk '/users:\(\("sshd"/ {n=split($4,a,":"); print a[n]}' | sort -nu | tr '\n' ' '
}

has_port() {
  local ports=" $1 "
  local port="$2"
  [[ "$ports" == *" $port "* ]]
}

restore_dropin() {
  if [[ "${DROPIN_EXISTED:-0}" == "1" ]]; then
    mv -f "$DROPIN_BACKUP" "$DROPIN"
  else
    rm -f "$DROPIN"
  fi
}

# --- 0. 前置检查 -------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "ERR: 需要 root"; exit 1; }
[[ -s /root/.ssh/authorized_keys ]] || {
  echo "ERR: /root/.ssh/authorized_keys 为空或不存在。" >&2
  echo "     先用 ssh-copy-id 推公钥并验证密钥能登,再跑此脚本。" >&2
  exit 1
}

CURRENT_PORTS=$(get_ports)
if [[ -z "$CURRENT_PORTS" ]]; then
  echo "ERR: 无法读取当前 sshd 端口,请检查 sshd 配置。" >&2
  exit 1
fi
EXTERNAL_CONFIG_PORTS=$(get_external_config_ports)

if [[ -z "$REQUESTED_PORT" ]]; then
  if has_port "$CURRENT_PORTS" 22; then
    PORT=$DEFAULT_PORT
    AUTO_PORT_CHANGED=1
  else
    PORT=${CURRENT_PORTS%% *}
    AUTO_PORT_CHANGED=0
  fi
else
  PORT=$REQUESTED_PORT
  AUTO_PORT_CHANGED=0
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || { (( 10#$PORT != 22 )) && (( 10#$PORT < 1024 || 10#$PORT > 65535 )); }; then
  echo "ERR: 非法端口: $PORT (允许 22 或 1024-65535,避免占用常见低位系统端口)" >&2
  exit 1
fi
PORT=$((10#$PORT))   # 归一化,去掉前导零

CHANGE_PORT=0
if ! has_port "$CURRENT_PORTS" "$PORT"; then
  CHANGE_PORT=1
fi

echo "----- preflight -----"
printf "  Current SSH ports = %s\n" "$CURRENT_PORTS"
printf "  External config ports = %s\n" "${EXTERNAL_CONFIG_PORTS:-none}"
printf "  Target SSH port   = %s\n" "$PORT"
if [[ "$AUTO_PORT_CHANGED" == "1" ]]; then
  echo "  Mode              = auto: current port includes 22, adding default high port"
elif [[ -z "$REQUESTED_PORT" ]]; then
  echo "  Mode              = auto: current port is already non-22, keeping it"
else
  echo "  Mode              = explicit target port"
fi
echo "---------------------"

# --- 1. 准备 sshd 服务 --------------------------------------------------------
SVC=ssh
systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service' \
  && ! systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service' \
  && SVC=sshd

# --- 2. 写 sshd drop-in ------------------------------------------------------
mkdir -p /etc/ssh/sshd_config.d
DROPIN_BACKUP="${DROPIN}.bak.$(date +%Y%m%d%H%M%S)"
DROPIN_EXISTED=0
if [[ -e "$DROPIN" ]]; then
  cp -a "$DROPIN" "$DROPIN_BACKUP"
  DROPIN_EXISTED=1
fi
if [[ -e "$LEGACY_DROPIN" ]]; then
  cp -a "$LEGACY_DROPIN" "${LEGACY_DROPIN}.bak.$(date +%Y%m%d%H%M%S)"
  rm -f "$LEGACY_DROPIN"
fi

{
  if [[ "$CHANGE_PORT" == "1" ]]; then
    # 同时保留旧端口,但避免重复写入主配置/其它 drop-in 已声明的 Port。
    for current_port in $CURRENT_PORTS; do
      has_port "$EXTERNAL_CONFIG_PORTS" "$current_port" || echo "Port ${current_port}"
    done
  fi
  # 不论是否换端口,都要保证目标端口至少有一处声明。
  # 这可以避免重复运行时把本 drop-in 独有的非 22 端口擦掉。
  has_port "$EXTERNAL_CONFIG_PORTS" "$PORT" || echo "Port ${PORT}"
  cat <<EOF
PasswordAuthentication no
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
MaxStartups 30:60:100
LoginGraceTime 20
EOF
} > "$DROPIN"

# --- 3. 重启 sshd ------------------------------------------------------------
if ! sshd -t; then
  echo "ABORT: 新 sshd 配置语法检查失败,正在恢复旧配置。" >&2
  restore_dropin
  exit 1
fi

systemctl disable --now ssh.socket 2>/dev/null || true
if ! systemctl restart "$SVC"; then
  echo "ABORT: sshd 重启失败,正在恢复旧配置并尝试恢复 SSH 服务。" >&2
  restore_dropin
  if sshd -t && systemctl restart "$SVC"; then
    echo "已恢复旧配置并重启 SSH 服务。" >&2
  else
    echo "CRITICAL: 旧配置恢复后 SSH 服务仍无法启动,请使用云厂商控制台排查。" >&2
  fi
  exit 1
fi

# --- 4. 用 sshd -T 验证【实际生效值】 ---------------------------------------
get() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==tolower(k) {print $2; exit}'; }
PW=$(get passwordauthentication)
ROOT=$(get permitrootlogin)
LISTEN=""
for _ in 1 2 3 4 5; do
  LISTEN=$(get_listening_ports)
  [[ -n "$LISTEN" ]] && break
  sleep 1
done

echo "----- effective config -----"
printf "  PasswordAuth = %s  (want: no)\n" "$PW"
printf "  PermitRoot   = %s  (want: prohibit-password)\n" "$ROOT"
printf "  Listening    = %s\n" "$LISTEN"
echo "----------------------------"

[[ "$PW"   == "no" ]]                  || { echo "ABORT: PasswordAuthentication 未关闭(可能被主配置覆盖,检查 /etc/ssh/sshd_config)"; exit 1; }
[[ "$ROOT" == "prohibit-password" ]]   || { echo "ABORT: PermitRootLogin 未限制"; exit 1; }
echo " $LISTEN " | grep -q " $PORT "   || { echo "ABORT: 端口 $PORT 未真正监听"; exit 1; }

if [[ "$CHANGE_PORT" == "1" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  echo "UFW active: allowing ${PORT}/tcp"
  ufw allow "${PORT}/tcp"
fi

# --- 5. fail2ban -------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq fail2ban

JAIL_PORTS=$(printf "%s\n" "$LISTEN" | awk '{$1=$1; gsub(/ /, ","); print}')
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
port     = ${JAIL_PORTS}
backend  = systemd
maxretry = 4
findtime = 10m
bantime  = 1h
EOF
systemctl enable fail2ban
systemctl restart fail2ban
sleep 1
fail2ban-client status sshd || true

# --- 6. 汇报 + 下一步 --------------------------------------------------------
echo
echo "============================================================"
echo "  SSH 加固完成"
echo "============================================================"
if [[ "$CHANGE_PORT" == "1" ]]; then
  cat <<EOF

⚠️  当前【旧端口和 ${PORT} 同时监听】(防止锁出去)。请按以下顺序收尾:

  1. 确认云厂商安全组 / 面板防火墙已放行 ${PORT} 端口
  2. 从【新窗口】验证新端口能登:
        ssh -p ${PORT} root@<ip>
  3. 验证通过后,在 VPS 上编辑 ${DROPIN},删除不再需要的旧端口 Port 行,然后重启 SSH:
        systemctl restart ${SVC}
  4. 本地 ~/.ssh/config 给这台机器加:  Port ${PORT}

如果新端口连不上:不要慌,旧端口仍开着,可继续通过旧端口进来排查。
EOF
else
  cat <<EOF

当前 SSH 已经不需要新增端口,脚本已沿用现有端口 ${PORT} 完成加固。
EOF
fi
