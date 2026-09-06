#!/usr/bin/env bash
set -u

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

NODE_CLIENT="client"
PORT_START="31400"
PORT_END="31409"
REFRESH_SH="/etc/openvpn/server/antnest-rinetd-refresh.sh"
PORTS_SH="/etc/openvpn/server/antnest-rinetd-ports.sh"
STATE_CONF="/etc/antnest-rinetd-state.conf"
RINETD_CONF="/etc/rinetd.conf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client)
      NODE_CLIENT="${2:-client}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! "$NODE_CLIENT" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid client name: $NODE_CLIENT" >&2
  exit 2
fi

log() {
  echo "[antnest-node-fwd] $*"
}

install_deps() {
  if ! command -v rinetd >/dev/null 2>&1; then
    log "安装 rinetd"
    apt-get install -y rinetd || {
      apt-get update -y || return 1
      apt-get install -y rinetd || return 1
    }
  fi
  if ! command -v iptables >/dev/null 2>&1; then
    log "安装 iptables"
    apt-get install -y iptables || return 1
  fi
  command -v flock >/dev/null 2>&1 || {
    log "flock 命令不存在，无法安全刷新配置"
    return 1
  }
  return 0
}

retire_hook() {
  local conf name
  for conf in /etc/openvpn/server/antnest-udp.conf /etc/openvpn/server/antnest-tcp.conf; do
    [[ -f "$conf" ]] || continue
    if grep -q '^client-connect ' "$conf"; then
      sed -i '/^client-connect /d' "$conf"
      name="$(basename "$conf" .conf)"
      systemctl restart "openvpn-server@$name" 2>/dev/null || true
      log "已移除 $conf 中的 client-connect 钩子并重启 openvpn-server@$name"
    fi
  done
}

remove_old_dnat() {
  local tool chain_found
  for tool in iptables iptables-legacy; do
    command -v "$tool" >/dev/null 2>&1 || continue
    chain_found="$("$tool" -t nat -S ANTNEST_NODE 2>/dev/null | grep -c . || true)"
    if [[ "${chain_found:-0}" -gt 0 ]]; then
      "$tool" -t nat -F ANTNEST_NODE 2>/dev/null || true
      "$tool" -t nat -X ANTNEST_NODE 2>/dev/null || true
      while "$tool" -t nat -D PREROUTING -p udp --dport 31400:31409 -j ANTNEST_NODE 2>/dev/null; do :; done
      while "$tool" -t nat -D PREROUTING -p tcp --dport 31400:31409 -j ANTNEST_NODE 2>/dev/null; do :; done
      log "已清理 $tool 中的 DNAT 遗留规则"
    fi
  done
  return 0
}

# ---------- 目标选择: 按证书名在 OpenVPN 状态日志里查虚拟 IP ----------
pick_target() {
  local status_file candidate
  for status_file in /var/log/openvpn-antnest-udp-status.log /var/log/openvpn-antnest-tcp-status.log; do
    [[ -f "$status_file" ]] || continue
    candidate="$(awk -F, -v cn="$NODE_CLIENT" '$1==cn && $2 ~ /^10\.(8|9)\.0\.[0-9]+$/ {print $2; exit}' "$status_file" 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  for status_file in /var/log/openvpn-antnest-tcp-status.log /var/log/openvpn-antnest-udp-status.log; do
    if [[ -f "$status_file" ]]; then
      candidate="$(grep -oE '10\.(8|9)\.0\.2' "$status_file" 2>/dev/null | head -n1 || true)"
      case "$candidate" in
        10.8.0.2|10.9.0.2)
          echo "$candidate"
          return 0
          ;;
      esac
    fi
  done
  echo "10.8.0.2"
}

# ---------- rinetd 管理 ----------
write_rinetd_conf() {
  local target="$1" tmp port
  tmp="/tmp/rinetd.conf.$$"
  echo "# AntNest Pi Node port forwarding (auto-generated)" > "$tmp"
  for port in $(seq "$PORT_START" "$PORT_END"); do
    echo "0.0.0.0 $port $target $port" >> "$tmp"
  done
  mv -f "$tmp" "$RINETD_CONF"
}

rinetd_restart() {
  pkill -x rinetd 2>/dev/null || true
  sleep 0.3
  if command -v systemctl >/dev/null 2>&1 && systemctl restart rinetd 2>/dev/null; then
    systemctl enable rinetd >/dev/null 2>&1 || true
  else
    nohup rinetd -c "$RINETD_CONF" >/var/log/antnest-rinetd.log 2>&1 &
  fi
  sleep 1
  pgrep -x rinetd >/dev/null 2>&1
}

rinetd_ok() {
  local target="$1" port
  pgrep -x rinetd >/dev/null 2>&1 || return 1
  grep -q " $target " "$RINETD_CONF" 2>/dev/null || return 1
  for port in $(seq "$PORT_START" "$PORT_END"); do
    ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port" || return 1
  done
  return 0
}

# ---------- 开机恢复 ----------
write_ports_boot() {
  mkdir -p /etc/openvpn/server
  cat > "$PORTS_SH" <<'BOOTEOF'
#!/usr/bin/env bash
set -u
STATE=/etc/antnest-rinetd-state.conf
CONF=/etc/rinetd.conf

for port in $(seq 31400 31409); do
  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
done

target="$(sed -n 's/^target=//p' "$STATE" 2>/dev/null | head -n1)"
[[ -z "$target" ]] && target="10.8.0.2"

tmp="/tmp/rinetd.boot.$$"
echo "# AntNest Pi Node port forwarding (auto-generated)" > "$tmp"
for port in $(seq 31400 31409); do
  echo "0.0.0.0 $port $target $port" >> "$tmp"
done
mv -f "$tmp" "$CONF"
pkill -x rinetd 2>/dev/null || true
sleep 0.3
if command -v systemctl >/dev/null 2>&1 && systemctl restart rinetd 2>/dev/null; then
  :
else
  nohup rinetd -c "$CONF" >/var/log/antnest-rinetd.log 2>&1 &
fi
BOOTEOF
  chmod +x "$PORTS_SH"
  "$PORTS_SH" || true

  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/antnest-rinetd-ports.service <<'UNITEOF'
[Unit]
Description=AntNest node rinetd forwarding ports (31400-31409)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/openvpn/server/antnest-rinetd-ports.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now antnest-rinetd-ports.service 2>/dev/null || true
  fi
}

# ---------- watch: 每 5 秒跟随目标 ----------
install_watch() {
  mkdir -p /etc/openvpn/server
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop antnest-rinetd-watch.service 2>/dev/null || true
    systemctl disable antnest-rinetd-watch.service 2>/dev/null || true
  fi
  pkill -f 'antnest-rinetd-refresh.sh.*sleep 5' 2>/dev/null || true

  if [[ -f "$STATE_CONF" ]] && grep -q '^client=' "$STATE_CONF"; then
    sed -i "s/^client=.*/client=$NODE_CLIENT/" "$STATE_CONF"
  else
    echo "client=$NODE_CLIENT" >> "$STATE_CONF"
  fi

  cat > "$REFRESH_SH" <<'EOF'
#!/usr/bin/env bash
# 每 5 秒: 目标变化 / rinetd 掉线 / 配置过期 -> 自动重建
set -u
if [[ "$(id -u)" -ne 0 ]]; then
  exit 0
fi
exec 9>/run/antnest-node-refresh.lock
if ! flock -n 9; then
  exit 0
fi

STATE="/etc/antnest-rinetd-state.conf"
CONF="/etc/rinetd.conf"

rinetd_ok() {
  local target="$1" port
  pgrep -x rinetd >/dev/null 2>&1 || return 1
  grep -q " $target " "$CONF" 2>/dev/null || return 1
  for port in $(seq 31400 31409); do
    ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port" || return 1
  done
  return 0
}

pick_target() {
  local status_file candidate
  for status_file in /var/log/openvpn-antnest-udp-status.log /var/log/openvpn-antnest-tcp-status.log; do
    [[ -f "$status_file" ]] || continue
    candidate="$(awk -F, -v cn="$node_client" '$1==cn && $2 ~ /^10\.(8|9)\.0\.[0-9]+$/ {print $2; exit}' "$status_file" 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  for status_file in /var/log/openvpn-antnest-tcp-status.log /var/log/openvpn-antnest-udp-status.log; do
    if [[ -f "$status_file" ]]; then
      candidate="$(grep -oE '10\.(8|9)\.0\.2' "$status_file" 2>/dev/null | head -n1 || true)"
      case "$candidate" in
        10.8.0.2|10.9.0.2)
          echo "$candidate"
          return 0
          ;;
      esac
    fi
  done
  echo "10.8.0.2"
}

node_client="$(sed -n 's/^client=//p' "$STATE" 2>/dev/null | head -n1)"
[[ -z "$node_client" ]] && node_client="client"

target="$(pick_target)"
current="$(sed -n 's/^target=//p' "$STATE" 2>/dev/null | head -n1)"

if [[ "$current" == "$target" ]] && rinetd_ok "$target"; then
  exit 0
fi

tmp="/tmp/rinetd.refresh.$$"
echo "# AntNest Pi Node port forwarding (auto-generated)" > "$tmp"
for port in $(seq 31400 31409); do
  echo "0.0.0.0 $port $target $port" >> "$tmp"
done
mv -f "$tmp" "$CONF"
pkill -x rinetd 2>/dev/null || true
sleep 0.3
if command -v systemctl >/dev/null 2>&1 && systemctl restart rinetd 2>/dev/null; then
  systemctl enable rinetd >/dev/null 2>&1 || true
else
  nohup rinetd -c "$CONF" >/var/log/antnest-rinetd.log 2>&1 &
fi

cat > "$STATE" <<STATE
target=$target
client=$node_client
ports=31400-31409/tcp
updated_at=$(date -Is)
STATE
logger -t antnest-node-fwd "rinetd target -> $target (client: $node_client)" 2>/dev/null || true
EOF
  chmod +x "$REFRESH_SH"

  cat > /etc/systemd/system/antnest-rinetd-watch.service <<'EOF'
[Unit]
Description=AntNest node rinetd target auto refresh
After=network-online.target openvpn-server@antnest-udp.service openvpn-server@antnest-tcp.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do /etc/openvpn/server/antnest-rinetd-refresh.sh >/var/log/antnest-rinetd-refresh.log 2>&1 || true; sleep 5; done'
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now antnest-rinetd-watch.service 2>/dev/null || true
  else
    pkill -f 'antnest-rinetd-refresh.sh.*sleep 5' 2>/dev/null || true
    nohup bash -c 'while true; do /etc/openvpn/server/antnest-rinetd-refresh.sh >/var/log/antnest-rinetd-refresh.log 2>&1 || true; sleep 5; done' >/dev/null 2>&1 &
  fi
}

main() {
  install_deps || exit 1
  retire_hook
  remove_old_dnat
  write_ports_boot
  install_watch || exit 1

  target="$(pick_target)"
  write_rinetd_conf "$target"
  rinetd_restart || {
    log "rinetd 启动失败"
    exit 1
  }
  cat > "$STATE_CONF" <<EOF
target=$target
client=$NODE_CLIENT
ports=31400-31409/tcp
updated_at=$(date -Is)
EOF

  if rinetd_ok "$target"; then
    log "端口转发就绪: 31400-31409/tcp (rinetd) -> $target"
    log "注意: rinetd 不转发 UDP"
  else
    log "转发校验未通过，请检查 rinetd 状态"
    exit 1
  fi
  log "跟随设备(证书名): $NODE_CLIENT"
}

main
