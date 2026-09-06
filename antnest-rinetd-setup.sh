#!/usr/bin/env bash
set -u

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

NODE_CLIENT="client"
PORT_START="31400"
PORT_END="31409"
CHAIN="ANTNEST_NODE"
REFRESH_SH="/etc/openvpn/server/antnest-rinetd-refresh.sh"
PORTS_SH="/etc/openvpn/server/antnest-rinetd-ports.sh"
STATE_CONF="/etc/antnest-rinetd-state.conf"

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

port_range() {
  echo "${PORT_START}:${PORT_END}"
}

install_deps() {
  if ! command -v iptables >/dev/null 2>&1; then
    log "安装 iptables"
    apt-get update -y || return 1
    apt-get install -y iptables || return 1
  fi
  command -v flock >/dev/null 2>&1 || {
    log "flock 命令不存在，无法安全刷新规则"
    return 1
  }
  return 0
}

retire_rinetd() {
  # 用户态 rinetd 机制退役，避免和 DNAT 抢同一批端口
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop rinetd.service 2>/dev/null || true
    systemctl disable rinetd.service 2>/dev/null || true
  fi
  pkill -x rinetd 2>/dev/null || true
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

nat_ensure_jump() {
  iptables -t nat -N "$CHAIN" 2>/dev/null || true
  if ! iptables -t nat -C PREROUTING -p tcp --dport "$(port_range)" -j "$CHAIN" 2>/dev/null; then
    iptables -t nat -I PREROUTING -p tcp --dport "$(port_range)" -j "$CHAIN"
  fi
  if ! iptables -t nat -C PREROUTING -p udp --dport "$(port_range)" -j "$CHAIN" 2>/dev/null; then
    iptables -t nat -I PREROUTING -p udp --dport "$(port_range)" -j "$CHAIN"
  fi
}

nat_set_target() {
  local target="$1"
  iptables -t nat -F "$CHAIN"
  iptables -t nat -A "$CHAIN" -p tcp --dport "$(port_range)" -j DNAT --to-destination "$target"
  iptables -t nat -A "$CHAIN" -p udp --dport "$(port_range)" -j DNAT --to-destination "$target"
}

nat_target_ok() {
  local target="$1" rules
  iptables -t nat -C PREROUTING -p tcp --dport "$(port_range)" -j "$CHAIN" 2>/dev/null || return 1
  iptables -t nat -C PREROUTING -p udp --dport "$(port_range)" -j "$CHAIN" 2>/dev/null || return 1
  rules="$(iptables -t nat -S "$CHAIN" 2>/dev/null | grep -- '-j DNAT' || true)"
  [[ "$(printf '%s\n' "$rules" | grep -c -- "--to-destination ${target}\$")" -eq 2 ]] || return 1
  [[ "$(printf '%s\n' "$rules" | grep -c .)" -eq 2 ]] || return 1
  return 0
}

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

write_ports_boot() {
  mkdir -p /etc/openvpn/server
  cat > "$PORTS_SH" <<'BOOTEOF'
#!/usr/bin/env bash
set -u
CHAIN=ANTNEST_NODE
STATE=/etc/antnest-rinetd-state.conf

for port in $(seq 31400 31409); do
  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
done

target="$(sed -n 's/^target=//p' "$STATE" 2>/dev/null | head -n1)"
[[ -z "$target" ]] && target="10.8.0.2"

iptables -t nat -N "$CHAIN" 2>/dev/null || true
if ! iptables -t nat -C PREROUTING -p tcp --dport 31400:31409 -j "$CHAIN" 2>/dev/null; then
  iptables -t nat -I PREROUTING -p tcp --dport 31400:31409 -j "$CHAIN"
fi
if ! iptables -t nat -C PREROUTING -p udp --dport 31400:31409 -j "$CHAIN" 2>/dev/null; then
  iptables -t nat -I PREROUTING -p udp --dport 31400:31409 -j "$CHAIN"
fi
iptables -t nat -F "$CHAIN"
iptables -t nat -A "$CHAIN" -p tcp --dport 31400:31409 -j DNAT --to-destination "$target"
iptables -t nat -A "$CHAIN" -p udp --dport 31400:31409 -j DNAT --to-destination "$target"
BOOTEOF
  chmod +x "$PORTS_SH"
  "$PORTS_SH" || true

  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/antnest-rinetd-ports.service <<'UNITEOF'
[Unit]
Description=AntNest node DNAT ports (31400-31409)
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
set -u
if [[ "$(id -u)" -ne 0 ]]; then
  exit 0
fi
exec 9>/run/antnest-node-refresh.lock
if ! flock -n 9; then
  exit 0
fi

CHAIN="ANTNEST_NODE"
STATE="/etc/antnest-rinetd-state.conf"

port_range() { echo "31400:31409"; }

nat_ensure_jump() {
  iptables -t nat -N "$CHAIN" 2>/dev/null || true
  if ! iptables -t nat -C PREROUTING -p tcp --dport "$(port_range)" -j "$CHAIN" 2>/dev/null; then
    iptables -t nat -I PREROUTING -p tcp --dport "$(port_range)" -j "$CHAIN"
  fi
  if ! iptables -t nat -C PREROUTING -p udp --dport "$(port_range)" -j "$CHAIN" 2>/dev/null; then
    iptables -t nat -I PREROUTING -p udp --dport "$(port_range)" -j "$CHAIN"
  fi
}

nat_target_ok() {
  local target="$1" rules
  iptables -t nat -C PREROUTING -p tcp --dport "$(port_range)" -j "$CHAIN" 2>/dev/null || return 1
  iptables -t nat -C PREROUTING -p udp --dport "$(port_range)" -j "$CHAIN" 2>/dev/null || return 1
  rules="$(iptables -t nat -S "$CHAIN" 2>/dev/null | grep -- '-j DNAT' || true)"
  [[ "$(printf '%s\n' "$rules" | grep -c -- "--to-destination ${target}\$")" -eq 2 ]] || return 1
  [[ "$(printf '%s\n' "$rules" | grep -c .)" -eq 2 ]] || return 1
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

if [[ "$current" == "$target" ]] && nat_ensure_jump && nat_target_ok "$target"; then
  exit 0
fi

nat_ensure_jump
iptables -t nat -F "$CHAIN"
iptables -t nat -A "$CHAIN" -p tcp --dport "$(port_range)" -j DNAT --to-destination "$target"
iptables -t nat -A "$CHAIN" -p udp --dport "$(port_range)" -j DNAT --to-destination "$target"
cat > "$STATE" <<STATE
target=$target
client=$node_client
ports=31400-31409/tcp+udp
updated_at=$(date -Is)
STATE
logger -t antnest-node-fwd "DNAT target -> $target (client: $node_client)" 2>/dev/null || true
EOF
  chmod +x "$REFRESH_SH"

  cat > /etc/systemd/system/antnest-rinetd-watch.service <<'EOF'
[Unit]
Description=AntNest node DNAT target auto refresh
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
  retire_rinetd
  retire_hook
  write_ports_boot
  install_watch || exit 1

  target="$(pick_target)"
  nat_ensure_jump
  nat_set_target "$target"
  cat > "$STATE_CONF" <<EOF
target=$target
client=$NODE_CLIENT
ports=31400-31409/tcp+udp
updated_at=$(date -Is)
EOF

  if nat_target_ok "$target"; then
    log "DNAT 转发就绪: 31400-31409(tcp+udp) -> $target"
  else
    log "DNAT 规则校验未通过，请检查内核 iptables NAT 支持"
    exit 1
  fi
  log "跟随设备(证书名): $NODE_CLIENT"
  log "查看规则: iptables -t nat -S ANTNEST_NODE"
}

main
