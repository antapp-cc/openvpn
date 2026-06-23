#!/usr/bin/env bash
set -euo pipefail

MODE="dual"
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

  is_public_ipv4() {
    local value="$1"
    local a b c d

    [[ "$value" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    a="${BASH_REMATCH[1]}"
    b="${BASH_REMATCH[2]}"
    c="${BASH_REMATCH[3]}"
    d="${BASH_REMATCH[4]}"

    (( a >= 0 && a <= 255 && b >= 0 && b <= 255 && c >= 0 && c <= 255 && d >= 0 && d <= 255 )) || return 1
    (( a == 0 )) && return 1
    (( a == 10 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 192 && b == 0 && c == 2 )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a >= 224 )) && return 1

    return 0
  }

  use_public_ip() {
    ip="$1"
    if is_public_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
    return 1
  }

  ip="$(curl -4fsS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)"
  use_public_ip "$ip" && return 0

  ip="$(wget -T 5 -qO- https://api.ipify.org 2>/dev/null || true)"
  use_public_ip "$ip" && return 0

  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  use_public_ip "$ip" && return 0

  ip="$(curl -4fsS --connect-timeout 10 http://ip1.dynupdate.no-ip.com/ 2>/dev/null | grep -m 1 -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)"
  use_public_ip "$ip" && return 0

  ip="$(wget -T 10 -qO- http://ip1.dynupdate.no-ip.com/ 2>/dev/null | grep -m 1 -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)"
  use_public_ip "$ip" && return 0

  echo ""
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
mssfix 1360
tun-mtu 1500
tls-crypt tc.key
persist-tun
user nobody
group nogroup
status /var/log/openvpn-$name-status.log
verb 3
crl-verify crl.pem
script-security 2
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
$notify
EOF
}

enable_forwarding() {
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
}

configure_vpn_nat() {
  cat > /etc/openvpn/server/antnest-vpn-nat.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

wan_iface="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
if [[ -z "$wan_iface" ]]; then
  echo "missing default network interface" >&2
  exit 1
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null
for net in 10.8.0.0/24 10.9.0.0/24; do
  iptables -t nat -C POSTROUTING -s "$net" -o "$wan_iface" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$net" -o "$wan_iface" -j MASQUERADE
  iptables -C FORWARD -s "$net" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -s "$net" -j ACCEPT
  iptables -C FORWARD -d "$net" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -d "$net" -j ACCEPT
done
EOF
  chmod +x /etc/openvpn/server/antnest-vpn-nat.sh
  /etc/openvpn/server/antnest-vpn-nat.sh

  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/antnest-vpn-nat.service <<'EOF'
[Unit]
Description=AntNest OpenVPN internet NAT
After=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/openvpn/server/antnest-vpn-nat.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now antnest-vpn-nat.service 2>/dev/null || true
  fi
}

start_instance() {
  local name="$1"
  systemctl enable "openvpn-server@$name.service"
  systemctl restart "openvpn-server@$name.service"
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
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-GCM
verb 3
connect-retry 3 10
connect-timeout 8
server-poll-timeout 10
ping 5
ping-restart 30
ignore-unknown-option block-outside-dns register-dns
block-outside-dns
register-dns
mssfix 1360
tun-mtu 1500
auth-nocache
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

  chmod 600 "$OUT_PATH"
  log "Client config available at $OUT_PATH"
}

main() {
  local server_ip

  log "Mode: $MODE"
  install_packages
  ensure_pki
  enable_forwarding
  configure_vpn_nat

  server_ip="$(public_ip)"
  if [[ -z "$server_ip" ]]; then
    echo "Failed to detect public IPv4 address; refusing to generate client config with empty remote." >&2
    exit 1
  fi

  case "$MODE" in
    udp)
      write_server_conf "antnest-udp" "udp" "$UDP_PORT" "$VPN_NET_UDP" "$VPN_MASK_UDP"
      start_instance "antnest-udp"
      write_client_config "$server_ip" "true" "false"
      ;;
    tcp)
      write_server_conf "antnest-tcp" "tcp" "$TCP_PORT" "$VPN_NET_TCP" "$VPN_MASK_TCP"
      start_instance "antnest-tcp"
      write_client_config "$server_ip" "false" "true"
      ;;
    dual)
      write_server_conf "antnest-udp" "udp" "$UDP_PORT" "$VPN_NET_UDP" "$VPN_MASK_UDP"
      write_server_conf "antnest-tcp" "tcp" "$TCP_PORT" "$VPN_NET_TCP" "$VPN_MASK_TCP"
      start_instance "antnest-udp"
      start_instance "antnest-tcp"
      write_client_config "$server_ip" "true" "true"
      ;;
  esac

  log "OpenVPN install complete"
}

main
