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
  apt-get update || return 1
  printf 'y\n' | apt-get install rinetd || return 1
  if ! command -v rinetd >/dev/null 2>&1; then
    log "rinetd 安装后仍未找到命令"
    return 1
  fi
}

pick_target() {
  local candidate
  for candidate in "${ifconfig_pool_remote_ip:-}" "${ifconfig_local:-}"; do
    case "$candidate" in
      10.8.0.2|10.9.0.2)
        if ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then
          echo "$candidate"
          return 0
        fi
        ;;
    esac
  done
  # No OpenVPN hook context: prefer TCP fallback when it is actually reachable.
  for candidate in 10.9.0.2 10.8.0.2; do
    if ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
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
      sleep 1
      pgrep -x rinetd >/dev/null 2>&1 && return 0
    }
  fi
  if ! command -v rinetd >/dev/null 2>&1; then
    log "rinetd 命令不存在，无法启动"
    return 1
  fi
  nohup rinetd -c /etc/rinetd.conf >/var/log/antnest-rinetd.log 2>&1 &
  sleep 1
  if ! pgrep -x rinetd >/dev/null 2>&1; then
    log "rinetd 启动失败"
    tail -n 80 /var/log/antnest-rinetd.log 2>/dev/null || true
    return 1
  fi
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

pick_target() {
  local candidate
  for candidate in "${ifconfig_pool_remote_ip:-}" "${ifconfig_local:-}"; do
    case "$candidate" in
      10.8.0.2|10.9.0.2)
        echo "$candidate"
        return 0
        ;;
    esac
  done
  # Periodic refresh has no OpenVPN hook variables. Prefer TCP when it is alive,
  # because it is the fallback path after UDP is blocked.
  for candidate in 10.9.0.2 10.8.0.2; do
    if ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  echo "10.8.0.2"
}

target="$(pick_target)"

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
  if command -v rinetd >/dev/null 2>&1; then
    nohup rinetd -c /etc/rinetd.conf >/var/log/antnest-rinetd.log 2>&1 &
  fi
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

  cat > /etc/systemd/system/antnest-rinetd-watch.service <<'EOF'
[Unit]
Description=AntNest rinetd target auto refresh
After=network-online.target rinetd.service openvpn-server@antnest-udp.service openvpn-server@antnest-tcp.service

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
  install_rinetd || exit 1
  command -v rinetd >/dev/null 2>&1 || {
    log "rinetd 未安装成功"
    exit 1
  }
  install_hook || exit 1
  target="$(pick_target)"
  log "当前转发目标: $target"
  write_conf "$target" || exit 1
  restart_rinetd || exit 1
  if verify_listen; then
    log "31400-31409 已监听"
  else
    log "rinetd 已启动，但端口监听校验未全部通过"
    ss -ltnp 2>/dev/null | grep rinetd || true
    exit 1
  fi
  log "配置文件: /etc/rinetd.conf"
}

main
