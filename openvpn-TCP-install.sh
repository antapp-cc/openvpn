#!/bin/bash
#
# OpenVPN Installation Script - Smart Proxy Edition
# 只让VPN服务器IP走VPN，其他所有流量走本地网络

# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
	echo 'This installer needs to be run with "bash", not "sh".'
	exit
fi

# Discard stdin
read -N 999999 -t 0.001

# Detect OS
if grep -qs "ubuntu" /etc/os-release; then
	os="ubuntu"
	os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
	group_name="nogroup"
elif [[ -e /etc/debian_version ]]; then
	os="debian"
	os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
	group_name="nogroup"
elif [[ -e /etc/almalinux-release || -e /etc/rocky-release || -e /etc/centos-release ]]; then
	os="centos"
	os_version=$(grep -shoE '[0-9]+' /etc/almalinux-release /etc/rocky-release /etc/centos-release | head -1)
	group_name="nobody"
elif [[ -e /etc/fedora-release ]]; then
	os="fedora"
	os_version=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
	group_name="nobody"
else
	echo "This installer seems to be running on an unsupported distribution."
	exit
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 2204 ]]; then
	echo "Ubuntu 22.04 or higher is required."
	exit
fi

if [[ "$os" == "debian" && "$os_version" -lt 11 ]]; then
	echo "Debian 11 or higher is required."
	exit
fi

if [[ "$os" == "centos" && "$os_version" -lt 9 ]]; then
	echo "CentOS 9 or higher is required."
	exit
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "This installer needs to be run with root privileges."
	exit
fi

if [[ ! -e /dev/net/tun ]]; then
	echo "TUN device is not available."
	exit
fi

# Store script directory
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ============================================================
# INSTALLATION START
# ============================================================
if [[ ! -e /etc/openvpn/server/server.conf ]]; then
	clear
	echo '========================================='
	echo '   OpenVPN Smart Proxy Installer'
	echo '========================================='
	echo
	
	# Check for wget/curl
	if ! hash wget 2>/dev/null && ! hash curl 2>/dev/null; then
		echo "Installing wget..."
		apt-get update && apt-get install -y wget
	fi
	
	# Select IPv4
	if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
	else
		number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
		echo "Select IPv4 address:"
		ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '
		read -p "IPv4 address [1]: " ip_number
		until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
			echo "$ip_number: invalid selection."
			read -p "IPv4 address [1]: " ip_number
		done
		[[ -z "$ip_number" ]] && ip_number="1"
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "$ip_number"p)
	fi
	
	# Check if behind NAT
	public_ip=""
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo
		echo "This server is behind NAT."
		get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		until [[ -n "$get_public_ip" || -n "$public_ip" ]]; do
			echo "Invalid input."
			read -p "Public IPv4 address / hostname: " public_ip
		done
		[[ -z "$public_ip" ]] && public_ip="$get_public_ip"
	fi
	
	# Use public IP for client configuration
	client_ip="$ip"
	[[ -n "$public_ip" ]] && client_ip="$public_ip"
	
	# Protocol selection
	echo
	echo "Select protocol:"
	echo "   1) UDP"
	echo "   2) TCP (recommended)"
	protocol="2"
	until [[ -z "$protocol" || "$protocol" =~ ^[12]$ ]]; do
		read -p "Protocol [2]: " protocol
	done
	case "$protocol" in
		1) protocol=udp ;;
		2|"") protocol=tcp ;;
	esac
	
	# Port selection
	echo
	echo "Select port:"
	read -p "Port [62231]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
		echo "$port: invalid port."
		read -p "Port [62231]: " port
	done
	[[ -z "$port" ]] && port="62231"
	
	# DNS selection
	echo
	echo "Select DNS server for clients:"
	echo "   1) System resolvers"
	echo "   2) Google"
	echo "   3) Cloudflare (1.1.1.1)"
	echo "   4) OpenDNS"
	echo "   5) Quad9"
	echo "   6) AdGuard"
	echo "   7) Custom"
	dns="3"
	until [[ -z "$dns" || "$dns" =~ ^[1-7]$ ]]; do
		read -p "DNS server [3]: " dns
	done
	
	# Custom DNS input
	custom_dns=""
	if [[ "$dns" = "7" ]]; then
		echo
		until [[ -n "$custom_dns" ]]; do
			echo "Enter DNS servers (one or more IPv4 addresses, separated by spaces):"
			read -p "DNS servers: " dns_input
			dns_input=$(echo "$dns_input" | tr ',' ' ')
			for dns_ip in $dns_input; do
				if [[ "$dns_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
					if [[ -z "$custom_dns" ]]; then
						custom_dns="$dns_ip"
					else
						custom_dns="$custom_dns $dns_ip"
					fi
				fi
			done
			[[ -z "$custom_dns" ]] && echo "Invalid input."
		done
	fi
	
	# Client name
	echo
	echo "Enter a name for the first client:"
	read -p "Name [client]: " unsanitized_client
	client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
	[[ -z "$client" ]] && client="client"
	
	# Determine firewall
	if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
		if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
			firewall="firewalld"
		elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
			firewall="iptables"
		fi
	fi
	
	echo
	echo "Press any key to continue..."
	read -n1 -r
	
	# Install OpenVPN
	echo "Installing OpenVPN..."
	if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
		apt-get update
		apt-get install -y --no-install-recommends openvpn openssl ca-certificates $firewall
	elif [[ "$os" = "centos" ]]; then
		dnf install -y epel-release
		dnf install -y openvpn openssl ca-certificates tar $firewall
	else
		dnf install -y openvpn openssl ca-certificates tar $firewall
	fi
	
	if [[ "$firewall" == "firewalld" ]]; then
		systemctl enable --now firewalld.service
	fi
	
	# Download EasyRSA
	echo "Setting up EasyRSA..."
	mkdir -p /etc/openvpn/server/easy-rsa/
	{ wget -qO- "https://github.com/OpenVPN/easy-rsa/releases/download/v3.2.6/EasyRSA-3.2.6.tgz" 2>/dev/null || curl -sL "https://github.com/OpenVPN/easy-rsa/releases/download/v3.2.6/EasyRSA-3.2.6.tgz"; } | tar xz -C /etc/openvpn/server/easy-rsa/ --strip-components 1
	chown -R root:root /etc/openvpn/server/easy-rsa/
	cd /etc/openvpn/server/easy-rsa/
	
	# Initialize PKI
	./easyrsa --batch init-pki
	./easyrsa --batch build-ca nopass
	./easyrsa gen-tls-crypt-key
	
	# DH Parameters
	echo '-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----' > /etc/openvpn/server/dh.pem
	ln -s /etc/openvpn/server/dh.pem pki/dh.pem
	
	# Build certificates
	./easyrsa --batch --days=3650 build-server-full server nopass
	./easyrsa --batch --days=3650 build-client-full "$client" nopass
	./easyrsa --batch --days=3650 gen-crl
	
	# Copy certificates
	cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server
	cp pki/private/easyrsa-tls.key /etc/openvpn/server/tc.key
	chown nobody:"$group_name" /etc/openvpn/server/crl.pem
	chmod o+x /etc/openvpn/server/
	
	# ============================================================
	# Generate server.conf - 简单配置，不使用 redirect-gateway
	# ============================================================
	echo "Generating server configuration..."
	
	cat > /etc/openvpn/server/server.conf << SERVERCONF
local $ip
port $port
proto $protocol
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA512
tls-crypt tc.key
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
SERVERCONF
	
	# Add DNS configuration
	case "$dns" in
		1|"")
			if grep -q '^nameserver' /etc/resolv.conf && ! grep -q '^nameserver.*127.0.0.53' /etc/resolv.conf; then
				grep '^nameserver' /etc/resolv.conf | grep -v '127.0.0.53' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | while read line; do
					echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server/server.conf
				done
			fi
		;;
		2)
			echo 'push "dhcp-option DNS 1.0.0.1"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server/server.conf
		;;
		3)
			echo 'push "dhcp-option DNS 1.1.1.1"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server/server.conf
		;;
		4)
			echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server/server.conf
		;;
		5)
			echo 'push "dhcp-option DNS 9.9.9.9"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 149.112.112.112"' >> /etc/openvpn/server/server.conf
		;;
		6)
			echo 'push "dhcp-option DNS 94.140.14.14"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 94.140.15.15"' >> /etc/openvpn/server/server.conf
		;;
		7)
			for dns_ip in $custom_dns; do
				echo "push \"dhcp-option DNS $dns_ip\"" >> /etc/openvpn/server/server.conf
			done
		;;
	esac
	
	# Block outside DNS and other settings
	echo 'push "block-outside-dns"' >> /etc/openvpn/server/server.conf
	cat >> /etc/openvpn/server/server.conf << SERVERCONF

keepalive 10 120
user nobody
group $group_name
persist-key
persist-tun
verb 3
crl-verify crl.pem
SERVERCONF

	# UDP specific
	[[ "$protocol" = "udp" ]] && echo "explicit-exit-notify" >> /etc/openvpn/server/server.conf
	
	# Enable IP forwarding
	echo 1 > /proc/sys/net/ipv4/ip_forward
	echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn-forward.conf
	
	# Firewall configuration
	if systemctl is-active --quiet firewalld.service; then
		firewall-cmd --add-port="$port"/"$protocol"
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --add-port="$port"/"$protocol"
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
		firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
	else
		iptables_path=$(command -v iptables)
		cat > /etc/systemd/system/openvpn-iptables.service << IPTABLES
[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$iptables_path -t nat -A POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ip
ExecStart=$iptables_path -I INPUT -p $protocol --dport $port -j ACCEPT
ExecStart=$iptables_path -I FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStart=$iptables_path -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$iptables_path -t nat -D POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ip
ExecStop=$iptables_path -D INPUT -p $protocol --dport $port -j ACCEPT
ExecStop=$iptables_path -D FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStop=$iptables_path -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
IPTABLES
		systemctl enable --now openvpn-iptables.service
	fi
	
	# Use public IP if behind NAT
	[[ -n "$public_ip" ]] && ip="$public_ip"
	
	# ============================================================
	# Generate client config - 关键：添加VPN服务器IP路由
	# ============================================================
	cat > /etc/openvpn/server/client-common.txt << CLIENTCONF
client
dev tun
proto $protocol
remote $client_ip $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
ignore-unknown-option block-outside-dns
verb 3

# ============================================================
# Smart Proxy Configuration
# 只让VPN服务器IP走VPN隧道
# 其他所有流量（国内+海外）都走本地网络
# Only VPN server IP goes through VPN tunnel
# All other traffic goes through local network
# ============================================================
route $client_ip 255.255.255.255 vpn_gateway
CLIENTCONF

	# Enable and start OpenVPN
	echo "Starting OpenVPN service..."
	systemctl enable --now openvpn-server@server.service
	
	# Generate client .ovpn file
	grep -vh '^#' /etc/openvpn/server/client-common.txt /etc/openvpn/server/easy-rsa/pki/inline/private/"$client".inline > "$script_dir"/"$client.ovpn"
	
	# ============================================================
	# Installation complete
	# ============================================================
	clear
	echo
	echo "========================================="
	echo "     OpenVPN Installation Complete"
	echo "========================================="
	echo
	echo "Client configuration file:"
	echo "  $script_dir/$client.ovpn"
	echo
	echo "Server IP: $client_ip"
	echo "Port: $port"
	echo "Protocol: $protocol"
	echo
	echo "Smart Proxy: Enabled"
	echo "  - VPN server IP ($client_ip) -> VPN tunnel"
	echo "  - All other traffic -> Local network"
	echo
	echo "========================================="
	
# ============================================================
# EXISTING INSTALLATION MENU
# ============================================================
else
	clear
	echo "OpenVPN is already installed."
	echo
	echo "Select an option:"
	echo "   1) Add a new client"
	echo "   2) Revoke an existing client"
	echo "   3) Remove OpenVPN"
	echo "   4) Exit"
	read -p "Option: " option
	until [[ "$option" =~ ^[1-4]$ ]]; do
		echo "$option: invalid selection."
		read -p "Option: " option
	done
	
	case "$option" in
		1)
			echo
			echo "Enter client name:"
			read -p "Name: " unsanitized_client
			client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			while [[ -z "$client" || -e /etc/openvpn/server/easy-rsa/pki/issued/"$client".crt ]]; do
				echo "$client: invalid or already exists."
				read -p "Name: " unsanitized_client
				client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			done
			
			# Get server IP from existing config
			server_ip=$(grep "^remote " /etc/openvpn/server/client-common.txt | head -1 | awk '{print $2}')
			server_port=$(grep "^remote " /etc/openvpn/server/client-common.txt | head -1 | awk '{print $3}')
			protocol=$(grep "^proto " /etc/openvpn/server/client-common.txt | awk '{print $2}')
			
			cd /etc/openvpn/server/easy-rsa/
			./easyrsa --batch --days=3650 build-client-full "$client" nopass
			
			# Generate client config with smart proxy
			cat > /etc/openvpn/server/client-common.txt << CLIENTCONF
client
dev tun
proto $protocol
remote $server_ip $server_port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
ignore-unknown-option block-outside-dns
verb 3

# Smart Proxy: Only VPN server IP goes through VPN
route $server_ip 255.255.255.255 vpn_gateway
CLIENTCONF

			grep -vh '^#' /etc/openvpn/server/client-common.txt /etc/openvpn/server/easy-rsa/pki/inline/private/"$client".inline > "$script_dir"/"$client.ovpn"
			echo
			echo "$client added. Configuration: $script_dir/$client.ovpn"
			exit
		;;
		
		2)
			number_of_clients=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$number_of_clients" -eq 0 ]]; then
				echo "No existing clients."
				exit
			fi
			echo
			echo "Select client to revoke:"
			tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			read -p "Client: " client_number
			until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
				read -p "Client: " client_number
			done
			client=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$client_number"p)
			echo
			read -p "Confirm revocation of $client? [y/N]: " revoke
			until [[ "$revoke" =~ ^[yYnN]*$ ]]; do
				read -p "Confirm [y/N]: " revoke
			done
			if [[ "$revoke" =~ ^[yY]$ ]]; then
				cd /etc/openvpn/server/easy-rsa/
				./easyrsa --batch revoke "$client"
				./easyrsa --batch --days=3650 gen-crl
				rm -f /etc/openvpn/server/crl.pem
				cp /etc/openvpn/server/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem
				chown nobody:"$group_name" /etc/openvpn/server/crl.pem
				echo "$client revoked."
			fi
			exit
		;;
		
		3)
			read -p "Confirm removal? [y/N]: " remove
			if [[ "$remove" =~ ^[yY]$ ]]; then
				port=$(grep '^port ' /etc/openvpn/server/server.conf | cut -d ' ' -f 2)
				protocol=$(grep '^proto ' /etc/openvpn/server/server.conf | cut -d ' ' -f 2)
				if systemctl is-active --quiet firewalld.service; then
					firewall-cmd --remove-port="$port"/"$protocol"
					firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --permanent --remove-port="$port"/"$protocol"
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
				else
					systemctl disable --now openvpn-iptables.service
					rm -f /etc/systemd/system/openvpn-iptables.service
				fi
				systemctl disable --now openvpn-server@server.service
				rm -rf /etc/openvpn/server
				if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
					apt-get remove --purge -y openvpn
				else
					dnf remove -y openvpn
				fi
				echo "OpenVPN removed."
			fi
			exit
		;;
		
		4)
			exit
		;;
	esac
fi
