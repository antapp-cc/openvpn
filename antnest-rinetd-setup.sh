#!/usr/bin/env bash
set -u

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log() {
  echo "[antnest-rinetd] $*"
}

install_rinetd() {
  if command -v rinetd >/dev/null 2>&1; then
    log "rinetd 已安装"
    return 0
  fi
  log "安装 rinetd"
  apt-get update -y -o Acquire::Retries=3 --fix-missing
  apt-get install -y rinetd
}

pick_target() {
  local candidate
  for candidate in "${ifconfig_pool_remote_ip:-}" "${ifconfig_local:-}" 10.8.0.2 10.9.0.2; do
    case "$candidate" in
      10.8.0.2|10.9.0.2)
        if ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then
          echo "$candidate"
          return 0
        fi
        ;;
    esac
  done
  echo "10.8.0.2"
}

write_conf() {
  local target="$1"
  cat > /etc/rinetd.conf <<EOF
# AntNest Pi Node port forwarding
# Auto-generated. 31400-31409 -> current OpenVPN client.
EOF
  local port
  for port in $(seq 31400 31409); do
    echo "0.0.0.0 $port $target $port" >> /etc/rinetd.conf
  done
  cat > /etc/antnest-rinetd-state.conf <<EOF
target=$target
ports=31400-31409/tcp
updated_at=$(date -Is)
EOF
}

restart_rinetd() {
  pkill -x rinetd 2>/dev/null || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart rinetd 2>/dev/null && {
      systemctl enable rinetd >/dev/null 2>&1 || true
      return 0
    }
  fi
  nohup rinetd -c /etc/rinetd.conf >/var/log/antnest-rinetd.log 2>&1 &
}

verify_listen() {
  local missing=""
  local port
  for port in $(seq 31400 31409); do
    if ! ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port"; then
      missing="$missing $port"
    fi
  done
  if [[ -n "$missing" ]]; then
    log "未监听端口:$missing"
    return 1
  fi
  return 0
}

install_hook() {
  mkdir -p /etc/openvpn/server
  cat > /etc/openvpn/server/antnest-rinetd-refresh.sh <<'EOF'
#!/usr/bin/env bash
set -u
target="${ifconfig_pool_remote_ip:-}"
case "$target" in
  10.8.0.2|10.9.0.2) ;;
  *)
    if ping -c 1 -W 1 10.8.0.2 >/dev/null 2>&1; then
      target="10.8.0.2"
    elif ping -c 1 -W 1 10.9.0.2 >/dev/null 2>&1; then
      target="10.9.0.2"
    else
      target="10.8.0.2"
    fi
    ;;
esac

current=""
if [[ -f /etc/antnest-rinetd-state.conf ]]; then
  current="$(sed -n 's/^target=//p' /etc/antnest-rinetd-state.conf | head -n1)"
fi
if [[ "$current" == "$target" ]] && pgrep -x rinetd >/dev/null 2>&1; then
  exit 0
fi

cat > /etc/rinetd.conf <<CONF
# AntNest Pi Node port forwarding
# Auto-generated. 31400-31409 -> current OpenVPN client.
CONF
for port in $(seq 31400 31409); do
  echo "0.0.0.0 $port $target $port" >> /etc/rinetd.conf
done
cat > /etc/antnest-rinetd-state.conf <<STATE
target=$target
ports=31400-31409/tcp
updated_at=$(date -Is)
STATE
pkill -x rinetd 2>/dev/null || true
if command -v systemctl >/dev/null 2>&1 && systemctl restart rinetd 2>/dev/null; then
  systemctl enable rinetd >/dev/null 2>&1 || true
else
  nohup rinetd -c /etc/rinetd.conf >/var/log/antnest-rinetd.log 2>&1 &
fi
EOF
  chmod +x /etc/openvpn/server/antnest-rinetd-refresh.sh

  for conf in /etc/openvpn/server/antnest-udp.conf /etc/openvpn/server/antnest-tcp.conf; do
    [[ -f "$conf" ]] || continue
    sed -i '/^client-connect /d' "$conf"
    grep -q '^script-security ' "$conf" || echo 'script-security 2' >> "$conf"
    echo 'client-connect /etc/openvpn/server/antnest-rinetd-refresh.sh' >> "$conf"
  done

  systemctl restart openvpn-server@antnest-udp 2>/dev/null || true
  systemctl restart openvpn-server@antnest-tcp 2>/dev/null || true
}

main() {
  install_rinetd || exit 1
  install_hook || exit 1
  target="$(pick_target)"
  log "当前转发目标: $target"
  write_conf "$target" || exit 1
  restart_rinetd || exit 1
  if verify_listen; then
    log "31400-31409 已监听"
  else
    log "rinetd 已启动，但端口监听校验未全部通过"
  fi
  log "配置文件: /etc/rinetd.conf"
}

main
