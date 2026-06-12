#!/usr/bin/env bash
set -euo pipefail

MODE="dual"
AUTO="false"
CLIENT_NAME="client"
UDP_PORT="62230"
TCP_PORT="62231"
VPN_NET_UDP="10.8.0.0"
VPN_MASK_UDP="255.255.255.0"
VPN_NET_TCP="10.9.0.0"
VPN_MASK_TCP="255.255.255.0"
OUT_PATH="/root/client.ovpn"
EASYRSA_DIR="/etc/openvpn/server/easy-rsa"
PKI_DIR="$EASYRSA_DIR/pki"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --auto)
      AUTO="true"
      shift
      ;;
    --client)
      CLIENT_NAME="${2:-client}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  tcp|udp|dual) ;;
  *)
    echo "Invalid mode: $MODE. Use tcp, udp, or dual." >&2
    exit 2
    ;;
esac

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log() {
  echo "[antnest-openvpn] $*"
}

apt_retry() {
  local description="$1"
  shift
  log "$description"
  if "$@"; then
    return 0
  fi

  log "$description failed, cleaning apt cache and retrying"
  apt-get clean
  apt-get update -y -o Acquire::Retries=3 --fix-missing
  "$@"
}

public_ip() {
  local ip
  ip="$(curl -4fsS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(wget -T 5 -qO- https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  echo "$ip"
}

install_packages() {
  log "Installing OpenVPN dependencies"
  apt_retry "Updating apt package index" apt-get update -y -o Acquire::Retries=3 --fix-missing
  apt_retry "Installing OpenVPN dependencies" apt-get install -y -o Acquire::Retries=3 --fix-missing openvpn easy-rsa iptables curl ca-certificates
}

ensure_pki() {
  mkdir -p /etc/openvpn/server "$EASYRSA_DIR"
  if [[ ! -x "$EASYRSA_DIR/easyrsa" ]]; then
    cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/"
  fi

  cd "$EASYRSA_DIR"
  if [[ ! -d "$PKI_DIR" ]]; then
    ./easyrsa --batch init-pki
    EASYRSA_REQ_CN="antnest-ca" ./easyrsa --batch build-ca nopass
    ./easyrsa --batch gen-dh
    openvpn --genkey secret "$PKI_DIR/tc.key"
    EASYRSA_CERT_EXPIRE=3650 ./easyrsa --batch build-server-full server nopass
    EASYRSA_CERT_EXPIRE=3650 ./easyrsa --batch build-client-full "$CLIENT_NAME" nopass
    EASYRSA_CRL_DAYS=3650 ./easyrsa --batch gen-crl
  else
    if [[ ! -f "$PKI_DIR/issued/$CLIENT_NAME.crt" || ! -f "$PKI_DIR/private/$CLIENT_NAME.key" ]]; then
      EASYRSA_CERT_EXPIRE=3650 ./easyrsa --batch build-client-full "$CLIENT_NAME" nopass
    fi
    EASYRSA_CRL_DAYS=3650 ./easyrsa --batch gen-crl
  fi

  cp "$PKI_DIR/ca.crt" /etc/openvpn/server/ca.crt
  cp "$PKI_DIR/issued/server.crt" /etc/openvpn/server/server.crt
  cp "$PKI_DIR/private/server.key" /etc/openvpn/server/server.key
  cp "$PKI_DIR/dh.pem" /etc/openvpn/server/dh.pem
  cp "$PKI_DIR/crl.pem" /etc/openvpn/server/crl.pem
  cp "$PKI_DIR/tc.key" /etc/openvpn/server/tc.key
  chmod 644 /etc/openvpn/server/crl.pem
}

write_server_conf() {
  local name="$1"
  local proto="$2"
  local port="$3"
  local network="$4"
  local mask="$5"
  local notify=""
  if [[ "$proto" == "udp" ]]; then
    notify="explicit-exit-notify 1"
  fi

  cat > "/etc/openvpn/server/$name.conf" <<EOF
port $port
proto $proto
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
topology subnet
server $network $mask
ifconfig-pool-persist ipp-$name.txt
keepalive 10 120
cipher AES-256-GCM
auth SHA512
tls-crypt tc.key
persist-key
persist-tun
user nobody
group nogroup
status /var/log/openvpn-$name-status.log
verb 3
crl-verify crl.pem
script-security 2
client-connect /etc/openvpn/server/antnest-client-connect.sh
push "block-outside-dns"
$notify
EOF
}

enable_forwarding() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
}

write_forwarding_helpers() {
  cat > /etc/openvpn/server/antnest-update-forward.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${1:-}"
if [[ -z "$target" ]]; then
  echo "missing target ip" >&2
  exit 1
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! command -v nft >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y nftables >/dev/null 2>&1 || true
fi
nft_ok=0
if command -v nft >/dev/null 2>&1; then
  if (
    nft delete table ip antnest_nat 2>/dev/null || true
    nft add table ip antnest_nat
    nft 'add chain ip antnest_nat prerouting { type nat hook prerouting priority dstnat; }'
    nft 'add chain ip antnest_nat postrouting { type nat hook postrouting priority srcnat; }'
    nft 'add chain ip antnest_nat forward { type filter hook forward priority filter; policy accept; }'
    nft add rule ip antnest_nat prerouting tcp dport 31400-31409 dnat to "$target"
    nft add rule ip antnest_nat postrouting ip daddr "$target" tcp dport 31400-31409 masquerade
    nft add rule ip antnest_nat forward ip daddr "$target" tcp dport 31400-31409 accept
  ); then
    mkdir -p /etc/nftables.d
    nft list table ip antnest_nat > /etc/nftables.d/antnest_nat.nft
    touch /etc/nftables.conf
    grep -q 'include "/etc/nftables.d/*.nft"' /etc/nftables.conf || echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
    systemctl enable --now nftables 2>/dev/null || true
    nft_ok=1
  fi
fi
if [[ "$nft_ok" != "1" ]]; then
  iptables -t nat -D PREROUTING -p tcp --dport 31400:31409 -j DNAT --to-destination "$target" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -d "$target" -p tcp --dport 31400:31409 -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p tcp -d "$target" --dport 31400:31409 -j ACCEPT 2>/dev/null || true
  iptables -t nat -A PREROUTING -p tcp --dport 31400:31409 -j DNAT --to-destination "$target"
  iptables -t nat -A POSTROUTING -d "$target" -p tcp --dport 31400:31409 -j MASQUERADE
  iptables -A FORWARD -p tcp -d "$target" --dport 31400:31409 -j ACCEPT
fi
cat > /etc/antnest-port-forward.conf <<STATE
target=$target
ports=31400-31409/tcp
STATE
EOF
  chmod +x /etc/openvpn/server/antnest-update-forward.sh

  cat > /etc/openvpn/server/antnest-client-connect.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${ifconfig_pool_remote_ip:-}"
if [[ -z "$target" ]]; then
  target="${trusted_ip:-}"
fi
if [[ -n "$target" ]]; then
  /etc/openvpn/server/antnest-update-forward.sh "$target" >/var/log/antnest-forward.log 2>&1 || true
fi
exit 0
EOF
  chmod +x /etc/openvpn/server/antnest-client-connect.sh
}

start_instance() {
  local name="$1"
  systemctl enable --now "openvpn-server@$name.service"
}

write_client_config() {
  local server_ip="$1"
  local include_udp="$2"
  local include_tcp="$3"

  cat > "$OUT_PATH" <<EOF
client
dev tun
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-GCM
ignore-unknown-option block-outside-dns
verb 3
connect-retry 3
connect-timeout 8
EOF

  if [[ "$include_udp" == "true" ]]; then
    cat >> "$OUT_PATH" <<EOF

<connection>
remote $server_ip $UDP_PORT
proto udp
</connection>
EOF
  fi

  if [[ "$include_tcp" == "true" ]]; then
    cat >> "$OUT_PATH" <<EOF

<connection>
remote $server_ip $TCP_PORT
proto tcp-client
</connection>
EOF
  fi

  cat >> "$OUT_PATH" <<EOF

<ca>
$(cat "$PKI_DIR/ca.crt")
</ca>
<cert>
$(awk '/BEGIN CERTIFICATE/{flag=1} flag{print} /END CERTIFICATE/{flag=0}' "$PKI_DIR/issued/$CLIENT_NAME.crt")
</cert>
<key>
$(cat "$PKI_DIR/private/$CLIENT_NAME.key")
</key>
<tls-crypt>
$(cat "$PKI_DIR/tc.key")
</tls-crypt>
EOF

  chmod 600 "$OUT_PATH"
  log "Client config available at $OUT_PATH"
}

main() {
  log "Mode: $MODE"
  install_packages
  ensure_pki
  enable_forwarding
  write_forwarding_helpers

  case "$MODE" in
    udp)
      write_server_conf "antnest-udp" "udp" "$UDP_PORT" "$VPN_NET_UDP" "$VPN_MASK_UDP"
      start_instance "antnest-udp"
      write_client_config "$(public_ip)" "true" "false"
      ;;
    tcp)
      write_server_conf "antnest-tcp" "tcp" "$TCP_PORT" "$VPN_NET_TCP" "$VPN_MASK_TCP"
      start_instance "antnest-tcp"
      write_client_config "$(public_ip)" "false" "true"
      ;;
    dual)
      write_server_conf "antnest-udp" "udp" "$UDP_PORT" "$VPN_NET_UDP" "$VPN_MASK_UDP"
      write_server_conf "antnest-tcp" "tcp" "$TCP_PORT" "$VPN_NET_TCP" "$VPN_MASK_TCP"
      start_instance "antnest-udp"
      start_instance "antnest-tcp"
      write_client_config "$(public_ip)" "true" "true"
      ;;
  esac

  /etc/openvpn/server/antnest-update-forward.sh "10.8.0.2" >/dev/null 2>&1 || true

  log "OpenVPN install complete"
}

main
