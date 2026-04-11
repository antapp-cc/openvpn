#!/bin/bash
#
# OpenVPN-install - Smart Proxy Edition
# 修正版：国内IP使用 net_gateway 走本地网络

# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
	echo 'This installer needs to be run with "bash", not "sh".'
	exit
fi

# Discard stdin. Needed when running from a one-liner which includes a newline
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
	echo "This installer needs to be run with superuser privileges."
	exit
fi

if [[ ! -e /dev/net/tun ]] || ! ( exec 7<>/dev/net/tun ) 2>/dev/null; then
	echo "The system does not have the TUN device available."
	exit
fi

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ ! -e /etc/openvpn/server/server.conf ]]; then
	# Detect some Debian minimal setups
	if ! hash wget 2>/dev/null && ! hash curl 2>/dev/null; then
		echo "Wget is required."
		read -n1 -r -p "Press any key to install Wget and continue..."
		apt-get update
		apt-get install -y wget
	fi
	clear
	echo 'Welcome to OpenVPN Smart Proxy Installer!'
	
	# Select IP
	if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
	else
		number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
		echo
		echo "Which IPv4 address should be used?"
		ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '
		read -p "IPv4 address [1]: " ip_number
		until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
			echo "$ip_number: invalid selection."
			read -p "IPv4 address [1]: " ip_number
		done
		[[ -z "$ip_number" ]] && ip_number="1"
		ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "$ip_number"p)
	fi
	
	# If $ip is a private IP, ask for public IP
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo
		echo "This server is behind NAT. What is the public IPv4 address or hostname?"
		get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		until [[ -n "$get_public_ip" || -n "$public_ip" ]]; do
			echo "Invalid input."
			read -p "Public IPv4 address / hostname: " public_ip
		done
		[[ -z "$public_ip" ]] && public_ip="$get_public_ip"
	fi
	
	# Select Protocol
	echo
	echo "Which protocol should OpenVPN use?"
	echo "   1) UDP"
	echo "   2) TCP (recommended)"
	protocol="2"
	until [[ -z "$protocol" || "$protocol" =~ ^[12]$ ]]; do
		echo "$protocol: invalid selection."
		read -p "Protocol [2]: " protocol
	done
	case "$protocol" in
		1) protocol=udp ;;
		2|"") protocol=tcp ;;
	esac
	
	# Select Port
	echo
	echo "What port should OpenVPN listen on?"
	read -p "Port [62231]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
		echo "$port: invalid port."
		read -p "Port [62231]: " port
	done
	[[ -z "$port" ]] && port="62231"
	
	# ========== 新增：选择代理模式 ==========
	echo
	echo "Select proxy mode:"
	echo "   1) Global proxy (all traffic through VPN)"
	echo "   2) Smart proxy (Domestic direct, Overseas via VPN) [Recommended]"
	proxy_mode="2"
	until [[ -z "$proxy_mode" || "$proxy_mode" =~ ^[12]$ ]]; do
		echo "$proxy_mode: invalid selection."
		read -p "Proxy mode [2]: " proxy_mode
	done
	[[ -z "$proxy_mode" ]] && proxy_mode="2"
	# ==========================================
	
	# Select DNS
	echo
	echo "Select a DNS server for the clients:"
	echo "   1) Default system resolvers"
	echo "   2) Google"
	echo "   3) 1.1.1.1"
	echo "   4) OpenDNS"
	echo "   5) Quad9"
	echo "   6) Gcore"
	echo "   7) AdGuard"
	echo "   8) Specify custom resolvers"
	dns="3"
	until [[ -z "$dns" || "$dns" =~ ^[1-8]$ ]]; do
		echo "$dns: invalid selection."
		read -p "DNS server [3]: " dns
	done
	
	if [[ "$dns" = "8" ]]; then
		echo
		until [[ -n "$custom_dns" ]]; do
			echo "Enter DNS servers (one or more IPv4 addresses, separated by commas or spaces):"
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
			if [ -z "$custom_dns" ]; then
				echo "Invalid input."
			fi
		done
	fi
	
	# Client name
	echo
	echo "Enter a name for the first client:"
	read -p "Name [client]: " unsanitized_client
	client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
	[[ -z "$client" ]] && client="client"
	
	echo
	echo "OpenVPN installation is ready to begin."
	
	# Install firewall
	if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
		if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
			firewall="firewalld"
		elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
			firewall="iptables"
		fi
	fi
	
	read -n1 -r -p "Press any key to continue..."
	
	# Install OpenVPN
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
	
	# Get easy-rsa
	easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.2.6/EasyRSA-3.2.6.tgz'
	mkdir -p /etc/openvpn/server/easy-rsa/
	{ wget -qO- "$easy_rsa_url" 2>/dev/null || curl -sL "$easy_rsa_url" ; } | tar xz -C /etc/openvpn/server/easy-rsa/ --strip-components 1
	chown -R root:root /etc/openvpn/server/easy-rsa/
	cd /etc/openvpn/server/easy-rsa/
	
	# Create PKI
	./easyrsa --batch init-pki
	./easyrsa --batch build-ca nopass
	./easyrsa gen-tls-crypt-key
	
	# DH params
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
	
	# Move certificates
	cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server
	cp pki/private/easyrsa-tls.key /etc/openvpn/server/tc.key
	chown nobody:"$group_name" /etc/openvpn/server/crl.pem
	chmod o+x /etc/openvpn/server/
	
	# Generate server.conf
	echo "local $ip
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
server 10.8.0.0 255.255.255.0" > /etc/openvpn/server/server.conf

	# ========== 代理模式配置 ==========
	if [[ "$proxy_mode" == "2" ]]; then
		# 智能代理模式：所有流量先走VPN，国内IP段走本地
		echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server/server.conf
		
		# 国内主要IP段 - 使用 net_gateway 走本地网络
		# 保留地址
		echo 'push "route 10.0.0.0 255.0.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 127.0.0.0 255.0.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 172.16.0.0 255.240.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 192.168.0.0 255.255.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		
		# 基础运营商
		echo 'push "route 27.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 58.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 60.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		
		# 电信/联通/移动/铁通
		echo 'push "route 101.0.0.0 255.224.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 103.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 106.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 110.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 111.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 112.0.0.0 255.240.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 114.0.0.0 255.224.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 115.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 116.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 117.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 118.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 119.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 120.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 121.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 122.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 123.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 124.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 125.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 175.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 180.64.0.0 255.192.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 182.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 202.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 210.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 218.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 219.128.0.0 255.224.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 220.160.0.0 255.224.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 221.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 222.0.0.0 255.248.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
		echo 'push "route 223.0.0.0 255.224.0.0 net_gateway"' >> /etc/openvpn/server/server.conf
	else
		# 全局代理模式
		echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	fi
	# ================================

	echo 'ifconfig-pool-persist ipp.txt' >> /etc/openvpn/server/server.conf
	
	# DNS
	case "$dns" in
		1|"")
			if grep '^nameserver' "/etc/resolv.conf" | grep -qv '127.0.0.53' ; then
				resolv_conf="/etc/resolv.conf"
			else
				resolv_conf="/run/systemd/resolve/resolv.conf"
			fi
			grep -v '^#\|^;' "$resolv_conf" | grep '^nameserver' | grep -v '127.0.0.53' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | while read line; do
				echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server/server.conf
			done
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
			echo 'push "dhcp-option DNS 95.85.95.85"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 2.56.220.2"' >> /etc/openvpn/server/server.conf
		;;
		7)
			echo 'push "dhcp-option DNS 94.140.14.14"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 94.140.15.15"' >> /etc/openvpn/server/server.conf
		;;
		8)
		for dns_ip in $custom_dns; do
			echo "push \"dhcp-option DNS $dns_ip\"" >> /etc/openvpn/server/server.conf
		done
		;;
	esac
	
	echo 'push "block-outside-dns"' >> /etc/openvpn/server/server.conf
	echo "keepalive 10 120
user nobody
group $group_name
persist-key
persist-tun
verb 3
crl-verify crl.pem" >> /etc/openvpn/server/server.conf
	
	if [[ "$protocol" = "udp" ]]; then
		echo "explicit-exit-notify" >> /etc/openvpn/server/server.conf
	fi
	
	# Enable IP forwarding
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
	echo 1 > /proc/sys/net/ipv4/ip_forward
	
	# Firewall
	if systemctl is-active --quiet firewalld.service; then
		firewall-cmd --add-port="$port"/"$protocol"
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --add-port="$port"/"$protocol"
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
		firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
	else
		iptables_path=$(command -v iptables)
		echo "[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$iptables_path -w 5 -t nat -A POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ip
ExecStart=$iptables_path -w 5 -I INPUT -p $protocol --dport $port -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$iptables_path -w 5 -t nat -D POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ip
ExecStop=$iptables_path -w 5 -D INPUT -p $protocol --dport $port -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" > /etc/systemd/system/openvpn-iptables.service
		systemctl enable --now openvpn-iptables.service
	fi
	
	# Use public IP if behind NAT
	[[ -n "$public_ip" ]] && ip="$public_ip"
	
	# Create client-common.txt
	if [[ "$proxy_mode" == "2" ]]; then
		# 智能代理模式：客户端模板
		echo "client
dev tun
proto $protocol
remote $ip $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
ignore-unknown-option block-outside-dns
verb 3" > /etc/openvpn/server/client-common.txt
	else
		echo "client
dev tun
proto $protocol
remote $ip $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
ignore-unknown-option block-outside-dns
verb 3" > /etc/openvpn/server/client-common.txt
	fi
	
	# Enable and start OpenVPN
	systemctl enable --now openvpn-server@server.service
	
	# Build client config
	grep -vh '^#' /etc/openvpn/server/client-common.txt /etc/openvpn/server/easy-rsa/pki/inline/private/"$client".inline > "$script_dir"/"$client".ovpn
	
	echo
	echo "========================================="
	echo "          OpenVPN Installation"
	echo "========================================="
	echo
	echo "The client configuration is available in:" "$script_dir"/"$client.ovpn"
	echo
	echo "Proxy mode: $([[ "$proxy_mode" == "2" ]] && echo "Smart proxy (Domestic direct, Overseas via VPN)" || echo "Global proxy (all traffic through VPN)")"
	echo
	echo "New clients can be added by running this script again."
else
	# OpenVPN already installed
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
			echo "Provide a name for the client:"
			read -p "Name: " unsanitized_client
			client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			while [[ -z "$client" || -e /etc/openvpn/server/easy-rsa/pki/issued/"$client".crt ]]; do
				echo "$client: invalid name."
				read -p "Name: " unsanitized_client
				client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			done
			cd /etc/openvpn/server/easy-rsa/
			./easyrsa --batch --days=3650 build-client-full "$client" nopass
			grep -vh '^#' /etc/openvpn/server/client-common.txt /etc/openvpn/server/easy-rsa/pki/inline/private/"$client".inline > "$script_dir"/"$client".ovpn
			echo
			echo "$client added. Configuration available in:" "$script_dir"/"$client.ovpn"
			exit
		;;
		2)
			number_of_clients=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$number_of_clients" = 0 ]]; then
				echo
				echo "There are no existing clients!"
				exit
			fi
			echo
			echo "Select the client to revoke:"
			tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			read -p "Client: " client_number
			until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
				echo "$client_number: invalid selection."
				read -p "Client: " client_number
			done
			client=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$client_number"p)
			echo
			read -p "Confirm $client revocation? [y/N]: " revoke
			until [[ "$revoke" =~ ^[yYnN]*$ ]]; do
				echo "$revoke: invalid selection."
				read -p "Confirm $client revocation? [y/N]: " revoke
			done
			if [[ "$revoke" =~ ^[yY]$ ]]; then
				cd /etc/openvpn/server/easy-rsa/
				./easyrsa --batch revoke "$client"
				./easyrsa --batch --days=3650 gen-crl
				rm -f /etc/openvpn/server/crl.pem
				cp /etc/openvpn/server/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem
				chown nobody:"$group_name" /etc/openvpn/server/crl.pem
				echo
				echo "$client revoked!"
			else
				echo
				echo "$client revocation aborted!"
			fi
			exit
		;;
		3)
			echo
			read -p "Confirm OpenVPN removal? [y/N]: " remove
			until [[ "$remove" =~ ^[yYnN]*$ ]]; do
				echo "$remove: invalid selection."
				read -p "Confirm OpenVPN removal? [y/N]: " remove
			done
			if [[ "$remove" =~ ^[yY]$ ]]; then
				port=$(grep '^port ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
				protocol=$(grep '^proto ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
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
				rm -f /etc/sysctl.d/99-openvpn-forward.conf
				if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
					rm -rf /etc/openvpn/server
					apt-get remove --purge -y openvpn
				else
					dnf remove -y openvpn
					rm -rf /etc/openvpn/server
				fi
				echo
				echo "OpenVPN removed!"
			else
				echo
				echo "OpenVPN removal aborted!"
			fi
			exit
		;;
		4)
			exit
		;;
	esac
fi
