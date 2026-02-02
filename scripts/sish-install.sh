#!/usr/bin/env bash
#
# ============================================================================
#  sish 通用一键安装脚本 —— 自建 SSH 隧道内网穿透服务（类 ngrok / serveo）
#  基于 https://github.com/antoniomika/sish ，无需反向代理，开箱即用
# ============================================================================
#
# 前置条件:
#   1. 一台有公网 IP 的 Linux 服务器（systemd；Ubuntu/Debian/RHEL 系均可）
#   2. 一个域名，添加两条 A 记录指向本机:  @ 和 *
#      （*.example.com 覆盖 ssh.example.com 与所有隧道子域名）
#
# 快速开始（root 执行，替换成你的域名）:
#   curl -fsSL <本脚本URL> | sudo DOMAIN=example.com bash
#
#   完成后即可使用（默认 SSH 端口 2222，HTTP 直接监听 80）:
#     管理员添加用户:  sish-adduser alice "ssh-ed25519 AAAA... alice@laptop"
#     用户建立隧道:    ssh -p 2222 -R demo:80:localhost:3000 ssh.example.com
#     公网访问:        http://demo.example.com
#
# 推荐: 一条命令装好并接管 22 端口，用户从此免 -p:
#   curl -fsSL <本脚本URL> | sudo DOMAIN=example.com TAKEOVER_22=yes bash
#
#     sish 占用 22 端口，管理 sshd 自动迁到 22022（ADMIN_SSH_PORT 可改）。
#     内置「自动回滚」防锁死: 接管后若 10 分钟内未确认，自动恢复原状。
#     所以安装完请按提示做两件事:
#       1. 新开终端验证:  ssh -p 22022 你的用户@服务器IP
#       2. 成功后确认:    sudo sish-confirm      ← 不确认则自动回滚
#     确认前务必已在云安全组/防火墙放行 22022（脚本会自动配置 ufw/firewalld，
#     但云厂商的安全组必须你自己在控制台放行）。
#     确信端口已通、想跳过回滚保护: 用 TAKEOVER_22=force
#
# 可选: 隧道支持 HTTPS（域名托管在 Cloudflare 时自动签泛域名证书）:
#   curl -fsSL <URL> | sudo DOMAIN=example.com ACME_EMAIL=you@example.com CF_Token=xxx bash
#   （CF_Token 需 Zone:Read + DNS:Edit 权限；也可自备证书放入
#     /opt/sish/ssl/<任意名>.crt + 同名 .key，sish 会自动热加载，无需重启）
#
# 子命令（管道方式加 -s --，如 curl -fsSL <URL> | sudo bash -s -- status）:
#   install(默认) | takeover-22 | status | uninstall
#   安装后另有两个独立命令: sish-adduser（加用户）、sish-confirm（确认接管）
#
# 环境变量（均有默认值，DOMAIN 除外）:
#   DOMAIN            必填，隧道根域名
#   TAKEOVER_22       yes=安装同时接管 22 端口（带自动回滚保护）
#                     force=接管且不设回滚（确信管理端口已放行时用）
#   ROLLBACK_DELAY    自动回滚等待时长，默认 10min（systemd 时间格式，如 90s）
#   ADMIN_SSH_PORT    接管 22 后管理 sshd 的新端口，默认 22022
#   SISH_VERSION      sish 版本，默认 2.23.0
#   SISH_SSH_PORT     sish SSH 端口，默认 2222（接管后为 22）
#   SISH_HTTP_PORT    HTTP 端口，默认 80
#   SISH_HTTPS_PORT   HTTPS 端口，默认 443（存在证书时启用）
#   ACME_EMAIL        acme.sh 注册邮箱（配合 CF_Token）
#   CF_Token          Cloudflare API Token（可选，用于自动签泛域名证书）
#   BIND_RANDOM_SUBDOMAINS  默认 false（允许用户指定子域名）
#
# 说明:
#   - 鉴权为公钥白名单: 只有 /opt/sish/pubkeys/ 中的公钥能建隧道，
#     密码登录关闭；增删 .pub 文件即时热加载生效
#   - systemd 单元带沙箱加固（根文件系统只读、私有 /tmp、系统调用白名单）
#   - 脚本幂等，可重复执行；升级 sish 改 SISH_VERSION 重跑即可
#   - 不想动服务器 22 端口的话，让用户在自己的 ~/.ssh/config 里写 Port 2222
#     同样能免去命令行的 -p 参数（见安装完成后的提示）
#
set -euo pipefail

DOMAIN="${DOMAIN:-}"
SISH_VERSION="${SISH_VERSION:-2.23.0}"
SISH_SSH_PORT_EXPLICIT="${SISH_SSH_PORT:+yes}"   # 记录用户是否显式指定
SISH_SSH_PORT="${SISH_SSH_PORT:-2222}"
SISH_HTTP_PORT="${SISH_HTTP_PORT:-80}"
SISH_HTTPS_PORT="${SISH_HTTPS_PORT:-443}"
ADMIN_SSH_PORT="${ADMIN_SSH_PORT:-22022}"
TAKEOVER_22="${TAKEOVER_22:-}"
ROLLBACK_DELAY="${ROLLBACK_DELAY:-10min}"
ACME_EMAIL="${ACME_EMAIL:-}"
CF_Token="${CF_Token:-}"
BIND_RANDOM_SUBDOMAINS="${BIND_RANDOM_SUBDOMAINS:-false}"

SISH_DIR="/opt/sish"
ACME="/root/.acme.sh/acme.sh"
SSHD_DROPIN="/etc/ssh/sshd_config.d/50-sish-takeover.conf"

log()  { echo -e "\033[1;32m[sish]\033[0m $*"; }
warn() { echo -e "\033[1;33m[sish]\033[0m $*"; }
die()  { echo -e "\033[1;31m[sish]\033[0m $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请以 root 运行（sudo bash sish-install.sh ...）"

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  armv6l|armv7l) ARCH=armv6 ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac

# ---------------------------------------------------------------- helpers

pkg_install() { # 尽力而为地跨发行版装包
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null; then dnf install -y -q "$@" >/dev/null 2>&1 || true
  elif command -v yum >/dev/null; then yum install -y -q "$@" >/dev/null 2>&1 || true
  fi
}

ssh_service_name() {
  if systemctl cat sshd.service >/dev/null 2>&1; then echo sshd; else echo ssh; fi
}

# 必须确认是 sshd 进程在监听（takeover 之后 22 端口由 sish 占用，不能误判）
sshd_listening_on() { ss -tlnp 2>/dev/null | grep ":$1 " | grep -q '"sshd"'; }

have_certs() { ls "${SISH_DIR}"/ssl/*.crt >/dev/null 2>&1; }

# 是否为可路由的公网 IPv4（排除私有网段、回环、链路本地、CGNAT）
is_public_ip() {
  local ip="${1:-}"
  case "$ip" in
    ""|*[!0-9.]*) return 1 ;;
    10.*|127.*|169.254.*|192.168.*|0.*) return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
    *.*.*.*) return 0 ;;
    *) return 1 ;;
  esac
}

# 探测公网 IP：云主机多为 NAT，hostname -I 只会给出内网地址
# 注意: 结果经 resolve_public_ip 缓存进全局 PUBLIC_IP，避免 $(...) 子 shell 重复探测
PUBLIC_IP=""
resolve_public_ip() { [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(detect_public_ip)"; }
detect_public_ip() {
  local ip="" u a
  # 1) 云厂商元数据服务（腾讯云/阿里云/AWS/GCP）
  for u in "http://metadata.tencentyun.com/latest/meta-data/public-ipv4" \
           "http://100.100.100.200/latest/meta-data/eipv4" \
           "http://169.254.169.254/latest/meta-data/public-ipv4"; do
    ip=$(curl -fsS -m 2 "$u" 2>/dev/null | head -1) || ip=""
    is_public_ip "$ip" && { echo "$ip"; return 0; }
  done
  ip=$(curl -fsS -m 2 -H "Metadata-Flavor: Google" \
       "http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" 2>/dev/null | head -1) || ip=""
  is_public_ip "$ip" && { echo "$ip"; return 0; }
  # 2) 解析 DOMAIN —— 脚本本就要求它已指向本机
  if [ -n "$DOMAIN" ]; then
    ip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}') || ip=""
    is_public_ip "$ip" && { echo "$ip"; return 0; }
  fi
  # 3) 外部回显服务
  for u in "https://api.ipify.org" "https://ifconfig.me/ip"; do
    ip=$(curl -fsS -m 3 "$u" 2>/dev/null | head -1) || ip=""
    is_public_ip "$ip" && { echo "$ip"; return 0; }
  done
  # 4) 本机网卡里挑一个公网地址（无 NAT 的裸机场景）
  for a in $(hostname -I 2>/dev/null); do
    is_public_ip "$a" && { echo "$a"; return 0; }
  done
  echo "服务器IP"
}

# 尽力放行主机防火墙（云厂商安全组仍需用户自行在控制台放行）
open_firewall_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 && log "  ufw 已放行 ${port}/tcp"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 \
      && firewall-cmd --reload >/dev/null 2>&1 && log "  firewalld 已放行 ${port}/tcp"
  fi
}

# 管理端口当前是否已有外部建立的 SSH 连接 —— 有则证明该端口确实可达
admin_port_proven_reachable() {
  ss -tn state established "( sport = :${ADMIN_SSH_PORT} )" 2>/dev/null | tail -n +2 | grep -q .
}

# 让 sshd 同时监听 22 与管理端口（过渡态，此时两个端口都能登录）
sshd_dual_listen() {
  grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config 2>/dev/null \
    || die "此系统 sshd_config 不支持 Include 目录，请手动迁移 sshd 端口后重试"
  mkdir -p /etc/ssh/sshd_config.d
  printf "Port 22\nPort %s\n" "$ADMIN_SSH_PORT" > "$SSHD_DROPIN"
  # 部分系统 (Ubuntu 22.10+) 用 socket 激活，Port 配置会被忽略，需禁用
  systemctl is-enabled ssh.socket >/dev/null 2>&1 && systemctl disable --now ssh.socket
  mkdir -p /run/sshd   # 缺失会导致 sshd -t 失败
  sshd -t && systemctl restart "$(ssh_service_name)"
  sleep 1
  sshd_listening_on "$ADMIN_SSH_PORT" || die "sshd 未能监听 ${ADMIN_SSH_PORT}，已保留 22 端口，请排查"
}

# sshd 让出 22，sish 接管（顺序: sshd 先释放，sish 再绑定）
sshd_release_22() {
  printf "Port %s\n" "$ADMIN_SSH_PORT" > "$SSHD_DROPIN"
  mkdir -p /run/sshd
  sshd -t && systemctl restart "$(ssh_service_name)"
  # 等待 22 端口释放，否则 sish 会因端口占用启动失败
  local i
  for i in $(seq 1 10); do
    ss -tln 2>/dev/null | grep -q ":22 " || break
    sleep 1
  done
  write_sish_unit 22
  systemctl restart sish
  sleep 1
  systemctl is-active --quiet sish || die "sish 启动失败: journalctl -u sish -n 50"
}

# 武装「死人开关」: 到期未确认则自动恢复 sshd 到 22、sish 退回 2222
arm_rollback() {
  command -v systemd-run >/dev/null 2>&1 || return 1

  cat > /usr/local/sbin/sish-rollback <<'ROLLBACK'
#!/usr/bin/env bash
# sish 接管 22 端口后的自动回滚（管理员未在期限内确认时由 systemd 定时器触发）
# 顺序至关重要: 必须先让 sish 交出 22 端口，sshd 才能重新绑定
exec >>/var/log/sish-rollback.log 2>&1
echo "=== $(date -Is 2>/dev/null) 开始自动回滚 ==="

svc=ssh; systemctl cat sshd.service >/dev/null 2>&1 && svc=sshd

# 1) sish 退回 2222，释放 22 端口
sed -i -E 's/(--ssh-address=:)[0-9]+/\12222/' /etc/systemd/system/sish.service 2>/dev/null
systemctl daemon-reload
systemctl restart sish 2>/dev/null || systemctl stop sish 2>/dev/null

# 2) 等待 22 端口真正释放（最多 15 秒）
for _ in $(seq 1 15); do
  ss -tln 2>/dev/null | grep -q ":22 " || break
  sleep 1
done

# 3) 恢复 sshd 监听 22（/run/sshd 缺失会让 sshd -t 失败，先补上）
rm -f /etc/ssh/sshd_config.d/50-sish-takeover.conf
mkdir -p /run/sshd
sshd -t && systemctl restart "$svc"

# 4) 校验 sshd 确实在 22 端口，失败则重试
ok=""
for _ in 1 2 3 4 5; do
  if ss -tlnp 2>/dev/null | grep ":22 " | grep -q '"sshd"'; then ok=yes; break; fi
  sleep 2
  mkdir -p /run/sshd
  systemctl restart "$svc" 2>/dev/null
done

rm -f /usr/local/bin/sish-confirm /usr/local/sbin/sish-rollback
if [ -n "$ok" ]; then
  echo "回滚成功: sshd 已恢复 22 端口, sish 退回 2222"
  logger -t sish "自动回滚完成: sshd 已恢复 22 端口, sish 退回 2222"
else
  echo "回滚异常: sshd 未能在 22 端口启动，请检查 systemctl status $svc"
  logger -t sish "自动回滚异常: sshd 未能绑定 22 端口"
fi
ROLLBACK
  chmod 755 /usr/local/sbin/sish-rollback

  cat > /usr/local/bin/sish-confirm <<'CONFIRM'
#!/usr/bin/env bash
# 确认 22 端口接管成功，取消自动回滚
[ "$(id -u)" = "0" ] || { echo "请用 sudo 运行: sudo sish-confirm"; exit 1; }
systemctl stop sish-rollback.timer 2>/dev/null || true
systemctl reset-failed sish-rollback.timer sish-rollback.service 2>/dev/null || true
rm -f /usr/local/sbin/sish-rollback /usr/local/bin/sish-confirm
echo "已确认：自动回滚已取消，sish 继续占用 22 端口。"
CONFIRM
  chmod 755 /usr/local/bin/sish-confirm

  systemctl stop sish-rollback.timer 2>/dev/null || true
  systemctl reset-failed sish-rollback.timer sish-rollback.service 2>/dev/null || true
  systemd-run --unit=sish-rollback --on-active="$ROLLBACK_DELAY" \
    --description="sish takeover auto-rollback" /usr/local/sbin/sish-rollback >/dev/null 2>&1
}

write_sish_unit() { # $1 = sish SSH 监听端口
  local port="$1" flags
  flags="--ssh-address=:${port} \\
    --http-address=:${SISH_HTTP_PORT} \\
    --domain=${DOMAIN} \\
    --authentication=true \\
    --authentication-keys-directory=${SISH_DIR}/pubkeys \\
    --private-keys-directory=${SISH_DIR}/keys \\
    --bind-random-subdomains=${BIND_RANDOM_SUBDOMAINS} \\
    --log-to-client=true"
  if have_certs; then
    flags="${flags} \\
    --https=true \\
    --https-address=:${SISH_HTTPS_PORT} \\
    --https-certificate-directory=${SISH_DIR}/ssl"
  fi

  cat > /etc/systemd/system/sish.service <<EOF
[Unit]
Description=sish - SSH tunnel service (${DOMAIN})
After=network.target

[Service]
User=sish
Group=sish
WorkingDirectory=${SISH_DIR}
ExecStart=${SISH_DIR}/sish ${flags}
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

# --- 沙箱加固：接近容器级的文件系统/内核隔离 ---
# 根文件系统对 sish 只读（公钥/证书热加载只需读 + inotify）；
# sish 每条隧道在 /tmp 建 unix socket，PrivateTmp 提供独立命名空间
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectProc=invisible
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
SystemCallArchitectures=native
DevicePolicy=closed
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# ---------------------------------------------------------------- install

do_install() {
  [ -n "$DOMAIN" ] || die "缺少 DOMAIN 环境变量，如: sudo DOMAIN=example.com bash sish-install.sh"

  log "1/6 安装依赖 ..."
  command -v curl >/dev/null || pkg_install curl
  command -v ss   >/dev/null || pkg_install iproute2 iproute
  command -v curl >/dev/null || die "缺少 curl 且自动安装失败，请手动安装后重试"

  log "2/6 创建 sish 用户与目录 ..."
  id sish >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d "$SISH_DIR" sish 2>/dev/null \
    || useradd -r -s /sbin/nologin -d "$SISH_DIR" sish
  mkdir -p "$SISH_DIR/keys" "$SISH_DIR/pubkeys" "$SISH_DIR/ssl"

  log "3/6 下载 sish v${SISH_VERSION} (linux-${ARCH}) ..."
  if [ ! -x "$SISH_DIR/sish" ] || [ ! -d "$SISH_DIR/templates" ] \
     || [ "$(cat "$SISH_DIR/.version" 2>/dev/null)" != "$SISH_VERSION" ]; then
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/sish.tar.gz" \
      "https://github.com/antoniomika/sish/releases/download/v${SISH_VERSION}/sish-${SISH_VERSION}.linux-${ARCH}.tar.gz"
    tar -xzf "$tmp/sish.tar.gz" -C "$tmp"
    install -m 755 "$tmp/sish-${SISH_VERSION}.linux-${ARCH}/sish" "$SISH_DIR/sish"
    # sish 的 HTTP 模块按相对路径加载 gin 模板，缺失会 panic
    rm -rf "$SISH_DIR/templates"
    cp -r "$tmp/sish-${SISH_VERSION}.linux-${ARCH}/templates" "$SISH_DIR/templates"
    echo "$SISH_VERSION" > "$SISH_DIR/.version"
    rm -rf "$tmp"
  fi
  [ -f "$SISH_DIR/keys/ssh_key" ] || ssh-keygen -t ed25519 -f "$SISH_DIR/keys/ssh_key" -N "" -q
  # sish 会遍历该目录并尝试把每个文件当私钥解析，.pub 留着只会刷错误日志
  rm -f "$SISH_DIR/keys/ssh_key.pub"
  chown -R sish:sish "$SISH_DIR"

  log "4/6 HTTPS 证书 ..."
  if [ -n "$CF_Token" ] && ! have_certs; then
    [ -n "$ACME_EMAIL" ] || die "提供 CF_Token 时需同时提供 ACME_EMAIL"
    command -v crontab >/dev/null || pkg_install cron cronie
    [ -x "$ACME" ] || curl -fsSL https://get.acme.sh | sh -s "email=${ACME_EMAIL}" >/dev/null
    "$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    export CF_Token
    rc=0
    "$ACME" --issue --dns dns_cf -d "$DOMAIN" -d "*.${DOMAIN}" --keylength ec-256 || rc=$?
    { [ "$rc" = 0 ] || [ "$rc" = 2 ]; } || die "证书签发失败（退出码 $rc），检查 CF_Token 权限与 DNS"
    # 续期后仅需复制文件并修正属主，sish 会自动热加载证书目录
    "$ACME" --install-cert -d "$DOMAIN" --ecc \
      --fullchain-file "${SISH_DIR}/ssl/${DOMAIN}.crt" \
      --key-file       "${SISH_DIR}/ssl/${DOMAIN}.key" \
      --reloadcmd      "chown -R sish:sish ${SISH_DIR}/ssl" >/dev/null
    chown -R sish:sish "${SISH_DIR}/ssl"
    log "  已签发 ${DOMAIN} + *.${DOMAIN} 泛域名证书，隧道将同时支持 HTTPS"
  elif have_certs; then
    log "  检测到 ${SISH_DIR}/ssl 已有证书，将启用 HTTPS"
  else
    log "  未提供 CF_Token 也无自备证书，隧道仅 HTTP（可稍后补证书重跑本脚本）"
  fi

  log "5/6 配置并启动 systemd 服务 ..."
  local sish_port="$SISH_SSH_PORT"
  # 重跑（升级/补证书）时未显式指定端口则保持现有端口，避免把 takeover 后的 22 拽回默认值
  if [ -z "$SISH_SSH_PORT_EXPLICIT" ] && [ -f /etc/systemd/system/sish.service ]; then
    local cur
    cur=$(grep -oP '(?<=--ssh-address=:)\d+' /etc/systemd/system/sish.service | head -1 || true)
    [ -n "$cur" ] && sish_port="$cur"
  fi
  if [ "$sish_port" = "22" ] && sshd_listening_on 22 && [ -z "$TAKEOVER_22" ]; then
    warn "  22 端口被 sshd 占用，sish 暂用 2222；如需接管 22 请加 TAKEOVER_22=yes 重跑"
    sish_port=2222
  fi
  # 要接管 22 时，先让 sish 起在 2222，待 sshd 让位后再切换
  if [ "$sish_port" = "22" ] && sshd_listening_on 22; then sish_port=2222; fi
  write_sish_unit "$sish_port"
  systemctl enable sish >/dev/null 2>&1
  systemctl restart sish
  sleep 1
  systemctl is-active --quiet sish || die "sish 启动失败，查看: journalctl -u sish -n 50"

  if [ -n "$TAKEOVER_22" ] && [ "$sish_port" != "22" ]; then
    log "5.5/6 接管 22 端口（管理 sshd 迁至 ${ADMIN_SSH_PORT}）..."
    takeover_oneshot
    sish_port=22
  fi

  log "6/6 安装用户管理工具 ..."
  cat > /usr/local/bin/sish-adduser <<'EOF'
#!/usr/bin/env bash
# 用法: sish-adduser <名字> "<ssh-ed25519 AAAA... comment>"   （删除用户: 删除对应 .pub 文件）
set -euo pipefail
[ $# -ge 2 ] || { echo "用法: sish-adduser <名字> \"<公钥内容>\""; exit 1; }
name="$1"; shift
echo "$*" > "/opt/sish/pubkeys/${name}.pub"
chown sish:sish "/opt/sish/pubkeys/${name}.pub"
echo "已添加 /opt/sish/pubkeys/${name}.pub（热加载，即时生效）"
EOF
  chmod +x /usr/local/bin/sish-adduser

  local hint_p="" scheme="http"
  [ "$sish_port" != "22" ] && hint_p=" -p ${sish_port}"
  have_certs && scheme="http(s)"
  echo
  log "================ 安装完成 ================"
  resolve_public_ip
  log "确认 DNS:     ${DOMAIN} 与 *.${DOMAIN} 两条 A 记录指向本机公网 IP (${PUBLIC_IP})"
  log "放行端口:     TCP ${sish_port}(隧道SSH) / ${SISH_HTTP_PORT}(HTTP)$(have_certs && echo " / ${SISH_HTTPS_PORT}(HTTPS)")$([ "$sish_port" = "22" ] && echo " / ${ADMIN_SSH_PORT}(管理SSH)")"
  log "添加用户:     sish-adduser alice \"ssh-ed25519 AAAA... alice@laptop\""
  log "建立隧道:     ssh${hint_p} -R demo:80:localhost:3000 ssh.${DOMAIN}"
  log "公网访问:     ${scheme}://demo.${DOMAIN}"
  if [ "$sish_port" != "22" ]; then
    log "免 -p 直连:   重跑本脚本并加 TAKEOVER_22=yes（sish 接管 22，sshd 迁至 ${ADMIN_SSH_PORT}）"
    log "              或让用户在自己的 ~/.ssh/config 里写: Host ssh.${DOMAIN} / Port ${sish_port}"
  fi
  [ -n "$TAKEOVER_22" ] && print_takeover_notice
  true
}

# ---------------------------------------------------------------- takeover-22

# 供 install 内联调用的一次性接管（非交互，靠自动回滚兜底）
takeover_oneshot() {
  local armed=""
  if sshd_listening_on 22; then
    open_firewall_port "$ADMIN_SSH_PORT"
    sshd_dual_listen
  fi

  if [ "$TAKEOVER_22" = "force" ]; then
    warn "  TAKEOVER_22=force：跳过自动回滚保护"
  elif admin_port_proven_reachable; then
    log "  检测到 ${ADMIN_SSH_PORT} 端口已有活跃连接，可达性已确认，无需回滚保护"
  elif arm_rollback; then
    armed="yes"
    log "  已武装自动回滚：${ROLLBACK_DELAY} 内未确认将自动恢复"
  else
    die "系统无 systemd-run，无法武装自动回滚。请确认 ${ADMIN_SSH_PORT} 可达后用 TAKEOVER_22=force 重试"
  fi

  sshd_release_22
  ROLLBACK_ARMED="$armed"
}

do_takeover() {
  [ -f /etc/systemd/system/sish.service ] || die "未找到 sish 服务，请先执行 install"
  [ -n "$DOMAIN" ] || DOMAIN=$(grep -oP '(?<=--domain=)\S+' /etc/systemd/system/sish.service | head -1)
  [ -n "$DOMAIN" ] || die "无法确定 DOMAIN，请通过环境变量指定"

  if ! sshd_listening_on 22 && ! sshd_listening_on "$ADMIN_SSH_PORT"; then
    die "未发现 sshd 在 22 或 ${ADMIN_SSH_PORT} 监听，环境异常，中止"
  fi

  # 阶段一: sshd 双端口过渡（22 + 新管理端口）
  if ! sshd_listening_on "$ADMIN_SSH_PORT"; then
    open_firewall_port "$ADMIN_SSH_PORT"
    sshd_dual_listen
    warn "sshd 现已同时监听 22 和 ${ADMIN_SSH_PORT}。"
  fi

  # 交互式确认；非交互则退化为「自动回滚兜底」的一次性接管
  if [ -t 0 ]; then
    warn "确认清单（缺一不可，否则可能失去服务器访问权限！）："
    warn "  1. 云安全组/防火墙已放行 TCP ${ADMIN_SSH_PORT}"
    warn "  2. 已另开终端用  ssh -p ${ADMIN_SSH_PORT} 用户@服务器IP  登录成功"
    read -r -p "以上都已确认? 输入 yes 继续: " ans
    [ "$ans" = "yes" ] || { warn "已取消（sshd 保持双端口，确认后重新执行本命令）"; exit 0; }
    sshd_release_22
    ROLLBACK_ARMED=""
  else
    [ -n "$TAKEOVER_22" ] || TAKEOVER_22=yes
    takeover_oneshot
  fi

  log "完成。当前监听:"
  ss -tlnp | grep -E ':(22|'"$ADMIN_SSH_PORT"') ' || true
  print_takeover_notice
}

# 接管完成后的统一提示（install 与 takeover-22 共用）
print_takeover_notice() {
  echo
  if [ -n "${ROLLBACK_ARMED:-}" ]; then
    warn "======== 重要：${ROLLBACK_DELAY} 内需完成确认，否则自动回滚 ========"
    local who ip
    who=$(logname 2>/dev/null || echo "${SUDO_USER:-你的用户}")
    resolve_public_ip; ip="$PUBLIC_IP"
    warn "  1. 新开一个终端验证管理登录:"
    warn "       ssh -p ${ADMIN_SSH_PORT} ${who}@${ip}"
    warn "  2. 登录成功后执行确认（取消自动回滚）:"
    warn "       sudo sish-confirm"
    warn "  若登录不上，什么都别做：到期后自动恢复 sshd 到 22 端口，不会失联。"
    warn "  （多半是云安全组没放行 ${ADMIN_SSH_PORT}，放行后重跑本脚本即可）"
    echo
  fi
  resolve_public_ip
  log "管理登录: ssh -p ${ADMIN_SSH_PORT} $(logname 2>/dev/null || echo "${SUDO_USER:-用户}")@${PUBLIC_IP}"
  warn "注意: 之前连过本机 22 端口的机器会提示主机密钥变化（现在是 sish 的 key），属预期。"
}

# ---------------------------------------------------------------- status / uninstall

do_status() {
  echo "--- 服务 ---"
  systemctl is-active sish 2>/dev/null | sed 's/^/sish: /'
  echo "--- 监听 ---"
  ss -tlnp 2>/dev/null | grep -E '"(sish|sshd)"' || true
  echo "--- 待确认的接管 ---"
  if systemctl is-active --quiet sish-rollback.timer 2>/dev/null; then
    warn "自动回滚待触发！验证 ssh -p ${ADMIN_SSH_PORT} 能登录后执行: sudo sish-confirm"
    systemctl list-timers sish-rollback.timer --no-pager --no-legend 2>/dev/null | head -1
  else
    echo "(无)"
  fi
  echo "--- 证书 ---"
  ls -l "${SISH_DIR}/ssl/" 2>/dev/null | grep -v '^total' || echo "(无，隧道仅 HTTP)"
  echo "--- 已授权用户 ---"
  ls -1 "${SISH_DIR}/pubkeys" 2>/dev/null || echo "(空，先 sish-adduser)"
}

do_confirm() {
  [ -x /usr/local/bin/sish-confirm ] || die "没有待确认的接管（回滚定时器不存在或已确认）"
  /usr/local/bin/sish-confirm
}

do_uninstall() {
  warn "停止并移除 sish 服务（保留 ${SISH_DIR} 数据目录与 sshd 配置）"
  systemctl stop sish-rollback.timer 2>/dev/null || true
  systemctl reset-failed sish-rollback.timer sish-rollback.service 2>/dev/null || true
  systemctl disable --now sish 2>/dev/null || true
  rm -f /etc/systemd/system/sish.service /usr/local/bin/sish-adduser \
        /usr/local/bin/sish-confirm /usr/local/sbin/sish-rollback
  systemctl daemon-reload
  log "已卸载。数据目录 ${SISH_DIR}（密钥/白名单/证书）未删除，确认不需要后可手动 rm -rf"
  if [ -f "$SSHD_DROPIN" ]; then
    warn "sshd 当前按 ${SSHD_DROPIN} 监听 ${ADMIN_SSH_PORT}。恢复默认 22 端口:"
    warn "  rm -f ${SSHD_DROPIN} && sshd -t && systemctl restart $(ssh_service_name)"
  fi
}

case "${1:-install}" in
  install)     do_install ;;
  takeover-22) do_takeover ;;
  confirm)     do_confirm ;;
  status)      do_status ;;
  uninstall)   do_uninstall ;;
  *) die "未知子命令: $1（可用: install / takeover-22 / confirm / status / uninstall）" ;;
esac
