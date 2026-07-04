#!/bin/bash
#
# https://github.com/Nyr/openvpn-install
#
# Copyright (c) 2013 Nyr. Released under the MIT License.


# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
	echo 'This installer needs to be run with "bash", not "sh".'
	exit
fi

# Discard stdin. Needed when running from a one-liner which includes a newline
read -N 999999 -t 0.001

# Detect OS
# $os_version variables aren't always in use, but are kept here for convenience
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
	echo "This installer seems to be running on an unsupported distribution.
Supported distros are Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS and Fedora."
	exit
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 2204 ]]; then
	echo "Ubuntu 22.04 or higher is required to use this installer.
This version of Ubuntu is too old and unsupported."
	exit
fi

if [[ "$os" == "debian" ]]; then
	if grep -q '/sid' /etc/debian_version; then
		echo "Debian Testing and Debian Unstable are unsupported by this installer."
		exit
	fi
	if [[ "$os_version" -lt 11 ]]; then
		echo "Debian 11 or higher is required to use this installer.
This version of Debian is too old and unsupported."
		exit
	fi
fi

if [[ "$os" == "centos" && "$os_version" -lt 9 ]]; then
	os_name=$(sed 's/ release.*//' /etc/almalinux-release /etc/rocky-release /etc/centos-release 2>/dev/null | head -1)
	echo "$os_name 9 or higher is required to use this installer.
This version of $os_name is too old and unsupported."
	exit
fi

# Detect environments where $PATH does not include the sbin directories
if ! grep -q sbin <<< "$PATH"; then
	echo '$PATH does not include sbin. Try using "su -" instead of "su".'
	exit
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "This installer needs to be run with superuser privileges."
	exit
fi

if [[ ! -e /dev/net/tun ]] || ! ( exec 7<>/dev/net/tun ) 2>/dev/null; then
	echo "The system does not have the TUN device available.
TUN needs to be enabled before running this installer."
	exit
fi

# Store the absolute path of the directory where the script is located
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ ! -e /etc/openvpn/server/server.conf ]]; then
	# Detect some Debian minimal setups where neither wget nor curl are installed
	if ! hash wget 2>/dev/null && ! hash curl 2>/dev/null; then
		echo "Wget is required to use this installer."
		read -n1 -r -p "Press any key to install Wget and continue..."
		apt-get update
		apt-get install -y wget
	fi
	clear
	echo 'Welcome to this OpenVPN road warrior installer!'
	# If system has a single IPv4, it is selected automatically. Else, ask the user
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
	# If $ip is a private IP address, the server must be behind NAT
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo
		echo "This server is behind NAT. What is the public IPv4 address or hostname?"
		# Get public IP and sanitize with grep
		get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		# If the checkip service is unavailable and user didn't provide input, ask again
		until [[ -n "$get_public_ip" || -n "$public_ip" ]]; do
			echo "Invalid input."
			read -p "Public IPv4 address / hostname: " public_ip
		done
		[[ -z "$public_ip" ]] && public_ip="$get_public_ip"
	fi
	# If system has a single IPv6, it is selected automatically
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -eq 1 ]]; then
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}')
	fi
	# If system has multiple IPv6, ask the user to select one
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -gt 1 ]]; then
		number_of_ip6=$(ip -6 addr | grep -c 'inet6 [23]')
		echo
		echo "Which IPv6 address should be used?"
		ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | nl -s ') '
		read -p "IPv6 address [1]: " ip6_number
		until [[ -z "$ip6_number" || "$ip6_number" =~ ^[0-9]+$ && "$ip6_number" -le "$number_of_ip6" ]]; do
			echo "$ip6_number: invalid selection."
			read -p "IPv6 address [1]: " ip6_number
		done
		[[ -z "$ip6_number" ]] && ip6_number="1"
		ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | sed -n "$ip6_number"p)
	fi
	echo
	echo "Which protocol should OpenVPN use?"
	echo "   1) UDP (recommended)"
	echo "   2) TCP"
	read -p "Protocol [1]: " protocol
	until [[ -z "$protocol" || "$protocol" =~ ^[12]$ ]]; do
		echo "$protocol: invalid selection."
		read -p "Protocol [1]: " protocol
	done
	case "$protocol" in
		1|"") 
		protocol=udp
		;;
		2) 
		protocol=tcp
		;;
	esac
	echo
	echo "What port should OpenVPN listen on?"
	read -p "Port [1194]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
		echo "$port: invalid port."
		read -p "Port [1194]: " port
	done
	[[ -z "$port" ]] && port="1194"
	# Always deploy a TCP 443 fallback instance alongside the primary one
	# Restrictive networks often block UDP, but rarely block TCP on port 443
	# Skipped only when the primary instance is already TCP 443
	if [[ "$protocol" = "tcp" && "$port" = 443 ]]; then
		fallback=""
	else
		fallback="y"
	fi
	# Also deploy a UDP 443 fallback instance (looks like QUIC / HTTP-3 to DPI)
	# Many networks that block UDP 1194 still pass UDP 443, and it keeps UDP speed
	# Skipped only when the primary instance is already UDP 443
	if [[ "$protocol" = "udp" && "$port" = 443 ]]; then
		fallback_udp=""
	else
		fallback_udp="y"
	fi
	if [[ -n "$fallback" || -n "$fallback_udp" ]]; then
		echo
		echo "Extra fallback instances on port 443 will also be set up. Clients will use"
		echo "$protocol $port first and switch to UDP 443 or TCP 443 automatically on"
		echo "networks where the primary port is blocked."
	fi
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
	read -p "DNS server [1]: " dns
	until [[ -z "$dns" || "$dns" =~ ^[1-8]$ ]]; do
		echo "$dns: invalid selection."
		read -p "DNS server [1]: " dns
	done
	# If the user selected custom resolvers, we deal with that here
	if [[ "$dns" = "8" ]]; then
		echo
		until [[ -n "$custom_dns" ]]; do
			echo "Enter DNS servers (one or more IPv4 addresses, separated by commas or spaces):"
			read -p "DNS servers: " dns_input
			# Convert comma delimited to space delimited
			dns_input=$(echo "$dns_input" | tr ',' ' ')
			# Validate and build custom DNS IP list
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
	echo
	echo "Enter a name for the first client:"
	read -p "Name [client]: " unsanitized_client
	# Allow a limited set of characters to avoid conflicts
	client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
	[[ -z "$client" ]] && client="client"
	echo
	echo "OpenVPN installation is ready to begin."
	# Install a firewall if firewalld or iptables are not already available
	if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
		if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
			firewall="firewalld"
			# We don't want to silently enable firewalld, so we give a subtle warning
			# If the user continues, firewalld will be installed and enabled during setup
			echo "firewalld, which is required to manage routing tables, will also be installed."
		elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
			# iptables is way less invasive than firewalld so no warning is given
			firewall="iptables"
		fi
	fi
	read -n1 -r -p "Press any key to continue..."
	# A lightweight web server backs the TCP 443 port-share decoy
	# Active probes or browsers hitting 443 get a real site instead of silence
	[[ -n "$fallback" ]] && webserver="nginx"
	# If running inside a container, disable LimitNPROC to prevent conflicts
	if systemd-detect-virt -cq; then
		# Template-wide drop-in so it also covers the TCP fallback instance
		mkdir /etc/systemd/system/openvpn-server@.service.d/ 2>/dev/null
		echo "[Service]
LimitNPROC=infinity" > /etc/systemd/system/openvpn-server@.service.d/disable-limitnproc.conf
	fi
	if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
		apt-get update
		apt-get install -y --no-install-recommends openvpn openssl ca-certificates $firewall $webserver
	elif [[ "$os" = "centos" ]]; then
		dnf install -y epel-release
		dnf install -y openvpn openssl ca-certificates tar $firewall $webserver
	else
		# Else, OS must be Fedora
		dnf install -y openvpn openssl ca-certificates tar $firewall $webserver
	fi
	# If firewalld was just installed, enable it
	if [[ "$firewall" == "firewalld" ]]; then
		systemctl enable --now firewalld.service
	fi
	# Get easy-rsa
	easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.2.6/EasyRSA-3.2.6.tgz'
	# Official SHA256 of EasyRSA-3.2.6.tgz, used to protect against tampered downloads
	easy_rsa_sha256='c2572990ce91112eef8d1b8e4a3b58790da95b68501785c621f69121dfbd22d7'
	easy_rsa_tgz=$(mktemp)
	wget -qO "$easy_rsa_tgz" "$easy_rsa_url" 2>/dev/null || curl -sLo "$easy_rsa_tgz" "$easy_rsa_url"
	if ! echo "$easy_rsa_sha256  $easy_rsa_tgz" | sha256sum -c --status; then
		rm -f "$easy_rsa_tgz"
		echo "easy-rsa download failed the integrity check. Aborting installation."
		exit 1
	fi
	mkdir -p /etc/openvpn/server/easy-rsa/
	tar xzf "$easy_rsa_tgz" -C /etc/openvpn/server/easy-rsa/ --strip-components 1
	rm -f "$easy_rsa_tgz"
	chown -R root:root /etc/openvpn/server/easy-rsa/
	cd /etc/openvpn/server/easy-rsa/
	# Create the PKI and set up the CA
	./easyrsa --batch init-pki
	./easyrsa --batch build-ca nopass
	# Create the DH parameters file using the predefined ffdhe2048 group
	echo '-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----' > /etc/openvpn/server/dh.pem
	# Make easy-rsa aware of our external DH file (prevents a warning)
	ln -s /etc/openvpn/server/dh.pem pki/dh.pem
	# Create certificates and CRL
	# Server certificate is long-lived, client certificates expire after 3 years
	./easyrsa --batch --days=3650 build-server-full server nopass
	./easyrsa --batch --days=1095 build-client-full "$client" nopass
	./easyrsa --batch --days=3650 gen-crl
	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server
	# Create the tls-crypt-v2 server key and an individual key for the first client
	# Unlike tls-crypt v1, a leaked client config does not expose a key shared by everyone
	openvpn --genkey tls-crypt-v2-server /etc/openvpn/server/tc-v2.key
	openvpn --tls-crypt-v2 /etc/openvpn/server/tc-v2.key --genkey tls-crypt-v2-client pki/private/"$client".tc-v2.key
	# Ensure key material is only readable by root
	chmod 600 /etc/openvpn/server/ca.key /etc/openvpn/server/server.key /etc/openvpn/server/tc-v2.key
	# CRL is read with each client connection, while OpenVPN is dropped to nobody
	chown nobody:"$group_name" /etc/openvpn/server/crl.pem
	# Without +x in the directory, OpenVPN can't run a stat() on the CRL file
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
tls-crypt-v2 tc-v2.key
tls-version-min 1.3
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
mssfix 1420
topology subnet
server 10.8.0.0 255.255.255.0" > /etc/openvpn/server/server.conf
	# IPv6
	if [[ -z "$ip6" ]]; then
		echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	else
		echo 'server-ipv6 fddd:1194:1194:1194::/64' >> /etc/openvpn/server/server.conf
		echo 'push "redirect-gateway def1 ipv6 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	fi
	echo 'ifconfig-pool-persist ipp.txt' >> /etc/openvpn/server/server.conf
	# DNS
	case "$dns" in
		1|"")
			# Locate the proper resolv.conf
			# Needed for systems running systemd-resolved
			if grep '^nameserver' "/etc/resolv.conf" | grep -qv '127.0.0.53' ; then
				resolv_conf="/etc/resolv.conf"
			else
				resolv_conf="/run/systemd/resolve/resolv.conf"
			fi
			# Obtain the resolvers from resolv.conf and use them for OpenVPN
			grep -v '^#\|^;' "$resolv_conf" | grep '^nameserver' | grep -v '127.0.0.53' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | while read line; do
				echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server/server.conf
			done
		;;
		2)
			echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server/server.conf
		;;
		3)
			echo 'push "dhcp-option DNS 1.1.1.1"' >> /etc/openvpn/server/server.conf
			echo 'push "dhcp-option DNS 1.0.0.1"' >> /etc/openvpn/server/server.conf
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
status /run/openvpn-server/status-server.log
status-version 2
crl-verify crl.pem" >> /etc/openvpn/server/server.conf
	if [[ "$protocol" = "udp" ]]; then
		# UDP tuning: larger socket buffers and reduced syscall overhead
		echo 'explicit-exit-notify
fast-io
sndbuf 524288
rcvbuf 524288
push "sndbuf 524288"
push "rcvbuf 524288"' >> /etc/openvpn/server/server.conf
	fi
	# Create the TCP 443 fallback instance, reusing the same PKI, DNS and routing
	# options, but with its own subnet and without the UDP-only options
	if [[ -n "$fallback" ]]; then
		sed 's|^port .*|port 443|; s|^proto .*|proto tcp|; s|^server 10\.8\.0\.0 .*|server 10.8.1.0 255.255.255.0|; s|fddd:1194:1194:1194::|fddd:1195:1195:1195::|g; s|^ifconfig-pool-persist ipp\.txt|ifconfig-pool-persist ipp-tcp.txt|; s|status-server\.log|status-server-tcp.log|' /etc/openvpn/server/server.conf | grep -vE '^(explicit-exit-notify|fast-io|sndbuf|rcvbuf)|^push "(snd|rcv)buf' > /etc/openvpn/server/server-tcp.conf
		# Set up a decoy website on loopback. OpenVPN's port-share forwards any
		# connection on 443 that is not a valid OpenVPN handshake to this server,
		# so active probes and browsers see a real site instead of silence.
		# This only defeats active probing; it does not obfuscate the VPN stream.
		mkdir -p /var/www/openvpn-decoy
		echo '<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome</title>
<style>body{font-family:sans-serif;margin:3em auto;max-width:40em;padding:0 1em;color:#333}</style>
</head>
<body>
<h1>It works!</h1>
<p>This is the default landing page for this server. If you are the site administrator, replace this file to publish your own content.</p>
</body>
</html>' > /var/www/openvpn-decoy/index.html
		mkdir -p /etc/nginx/conf.d
		echo 'server {
    listen 127.0.0.1:8080;
    server_name _;
    root /var/www/openvpn-decoy;
    index index.html;
    location / {
        try_files $uri $uri/ =404;
    }
}' > /etc/nginx/conf.d/openvpn-decoy.conf
		systemctl enable --now nginx 2>/dev/null
		systemctl reload nginx 2>/dev/null || systemctl restart nginx
		# Hand non-OpenVPN traffic on 443 to the local decoy web server
		echo 'port-share 127.0.0.1 8080' >> /etc/openvpn/server/server-tcp.conf
	fi
	# Create the UDP 443 fallback instance (QUIC-like camouflage), reusing the same
	# PKI, DNS and routing options but on its own subnet
	if [[ -n "$fallback_udp" ]]; then
		sed 's|^port .*|port 443|; s|^proto .*|proto udp|; s|^server 10\.8\.0\.0 .*|server 10.8.2.0 255.255.255.0|; s|fddd:1194:1194:1194::|fddd:1196:1196:1196::|g; s|^ifconfig-pool-persist ipp\.txt|ifconfig-pool-persist ipp-udp.txt|; s|status-server\.log|status-server-udp.log|' /etc/openvpn/server/server.conf > /etc/openvpn/server/server-udp.conf
		# When the primary is TCP, the UDP tuning block is absent, so add it here
		if ! grep -q '^explicit-exit-notify' /etc/openvpn/server/server-udp.conf; then
			echo 'explicit-exit-notify
fast-io
sndbuf 524288
rcvbuf 524288
push "sndbuf 524288"
push "rcvbuf 524288"' >> /etc/openvpn/server/server-udp.conf
		fi
	fi
	# Enable net.ipv4.ip_forward for the system
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
	# Enable without waiting for a reboot or service restart
	echo 1 > /proc/sys/net/ipv4/ip_forward
	if [[ -n "$ip6" ]]; then
		# Enable net.ipv6.conf.all.forwarding for the system
		echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-openvpn-forward.conf
		# Enable without waiting for a reboot or service restart
		echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi
	# Raise socket buffer limits so the sndbuf/rcvbuf values above take effect
	echo 'net.core.rmem_max=4194304
net.core.wmem_max=4194304' >> /etc/sysctl.d/99-openvpn-forward.conf
	echo 4194304 > /proc/sys/net/core/rmem_max
	echo 4194304 > /proc/sys/net/core/wmem_max
	# Enable BBR congestion control if the kernel supports it
	# Helps the TCP fallback and server-side traffic on lossy links
	if modprobe tcp_bbr 2>/dev/null && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
		echo 'net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.d/99-openvpn-forward.conf
		echo fq > /proc/sys/net/core/default_qdisc
		echo bbr > /proc/sys/net/ipv4/tcp_congestion_control
	fi
	if systemctl is-active --quiet firewalld.service; then
		# Using both permanent and not permanent rules to avoid a firewalld
		# reload.
		# We don't use --add-service=openvpn because that would only work with
		# the default port and protocol.
		firewall-cmd --add-port="$port"/"$protocol"
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --add-port="$port"/"$protocol"
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
		# Set NAT for the VPN subnet
		firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
		firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
		if [[ -n "$ip6" ]]; then
			firewall-cmd --zone=trusted --add-source=fddd:1194:1194:1194::/64
			firewall-cmd --permanent --zone=trusted --add-source=fddd:1194:1194:1194::/64
			firewall-cmd --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
			firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
		fi
		if [[ -n "$fallback" ]]; then
			firewall-cmd --add-port=443/tcp
			firewall-cmd --zone=trusted --add-source=10.8.1.0/24
			firewall-cmd --permanent --add-port=443/tcp
			firewall-cmd --permanent --zone=trusted --add-source=10.8.1.0/24
			firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.1.0/24 ! -d 10.8.1.0/24 -j SNAT --to "$ip"
			firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.1.0/24 ! -d 10.8.1.0/24 -j SNAT --to "$ip"
			if [[ -n "$ip6" ]]; then
				firewall-cmd --zone=trusted --add-source=fddd:1195:1195:1195::/64
				firewall-cmd --permanent --zone=trusted --add-source=fddd:1195:1195:1195::/64
				firewall-cmd --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1195:1195:1195::/64 ! -d fddd:1195:1195:1195::/64 -j SNAT --to "$ip6"
				firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1195:1195:1195::/64 ! -d fddd:1195:1195:1195::/64 -j SNAT --to "$ip6"
			fi
		fi
		if [[ -n "$fallback_udp" ]]; then
			firewall-cmd --add-port=443/udp
			firewall-cmd --zone=trusted --add-source=10.8.2.0/24
			firewall-cmd --permanent --add-port=443/udp
			firewall-cmd --permanent --zone=trusted --add-source=10.8.2.0/24
			firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.2.0/24 ! -d 10.8.2.0/24 -j SNAT --to "$ip"
			firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.2.0/24 ! -d 10.8.2.0/24 -j SNAT --to "$ip"
			if [[ -n "$ip6" ]]; then
				firewall-cmd --zone=trusted --add-source=fddd:1196:1196:1196::/64
				firewall-cmd --permanent --zone=trusted --add-source=fddd:1196:1196:1196::/64
				firewall-cmd --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1196:1196:1196::/64 ! -d fddd:1196:1196:1196::/64 -j SNAT --to "$ip6"
				firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1196:1196:1196::/64 ! -d fddd:1196:1196:1196::/64 -j SNAT --to "$ip6"
			fi
		fi
	else
		# Create a service to set up persistent iptables rules
		iptables_path=$(command -v iptables)
		ip6tables_path=$(command -v ip6tables)
		# nf_tables is not available as standard in OVZ kernels. So use iptables-legacy
		# if we are in OVZ, with a nf_tables backend and iptables-legacy is available.
		if [[ $(systemd-detect-virt) == "openvz" ]] && readlink -f "$(command -v iptables)" | grep -q "nft" && hash iptables-legacy 2>/dev/null; then
			iptables_path=$(command -v iptables-legacy)
			ip6tables_path=$(command -v ip6tables-legacy)
		fi
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
ExecStop=$iptables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" > /etc/systemd/system/openvpn-iptables.service
		if [[ -n "$ip6" ]]; then
			echo "ExecStart=$ip6tables_path -w 5 -t nat -A POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ip6
ExecStart=$ip6tables_path -w 5 -I FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
ExecStart=$ip6tables_path -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$ip6tables_path -w 5 -t nat -D POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ip6
ExecStop=$ip6tables_path -w 5 -D FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
ExecStop=$ip6tables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" >> /etc/systemd/system/openvpn-iptables.service
		fi
		if [[ -n "$fallback" ]]; then
			echo "ExecStart=$iptables_path -w 5 -t nat -A POSTROUTING -s 10.8.1.0/24 ! -d 10.8.1.0/24 -j SNAT --to $ip
ExecStart=$iptables_path -w 5 -I INPUT -p tcp --dport 443 -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -s 10.8.1.0/24 -j ACCEPT
ExecStop=$iptables_path -w 5 -t nat -D POSTROUTING -s 10.8.1.0/24 ! -d 10.8.1.0/24 -j SNAT --to $ip
ExecStop=$iptables_path -w 5 -D INPUT -p tcp --dport 443 -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -s 10.8.1.0/24 -j ACCEPT" >> /etc/systemd/system/openvpn-iptables.service
			if [[ -n "$ip6" ]]; then
				echo "ExecStart=$ip6tables_path -w 5 -t nat -A POSTROUTING -s fddd:1195:1195:1195::/64 ! -d fddd:1195:1195:1195::/64 -j SNAT --to $ip6
ExecStart=$ip6tables_path -w 5 -I FORWARD -s fddd:1195:1195:1195::/64 -j ACCEPT
ExecStop=$ip6tables_path -w 5 -t nat -D POSTROUTING -s fddd:1195:1195:1195::/64 ! -d fddd:1195:1195:1195::/64 -j SNAT --to $ip6
ExecStop=$ip6tables_path -w 5 -D FORWARD -s fddd:1195:1195:1195::/64 -j ACCEPT" >> /etc/systemd/system/openvpn-iptables.service
			fi
		fi
		if [[ -n "$fallback_udp" ]]; then
			echo "ExecStart=$iptables_path -w 5 -t nat -A POSTROUTING -s 10.8.2.0/24 ! -d 10.8.2.0/24 -j SNAT --to $ip
ExecStart=$iptables_path -w 5 -I INPUT -p udp --dport 443 -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -s 10.8.2.0/24 -j ACCEPT
ExecStop=$iptables_path -w 5 -t nat -D POSTROUTING -s 10.8.2.0/24 ! -d 10.8.2.0/24 -j SNAT --to $ip
ExecStop=$iptables_path -w 5 -D INPUT -p udp --dport 443 -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -s 10.8.2.0/24 -j ACCEPT" >> /etc/systemd/system/openvpn-iptables.service
			if [[ -n "$ip6" ]]; then
				echo "ExecStart=$ip6tables_path -w 5 -t nat -A POSTROUTING -s fddd:1196:1196:1196::/64 ! -d fddd:1196:1196:1196::/64 -j SNAT --to $ip6
ExecStart=$ip6tables_path -w 5 -I FORWARD -s fddd:1196:1196:1196::/64 -j ACCEPT
ExecStop=$ip6tables_path -w 5 -t nat -D POSTROUTING -s fddd:1196:1196:1196::/64 ! -d fddd:1196:1196:1196::/64 -j SNAT --to $ip6
ExecStop=$ip6tables_path -w 5 -D FORWARD -s fddd:1196:1196:1196::/64 -j ACCEPT" >> /etc/systemd/system/openvpn-iptables.service
			fi
		fi
		echo "RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" >> /etc/systemd/system/openvpn-iptables.service
		systemctl enable --now openvpn-iptables.service
	fi
	# If SELinux is enabled and a custom port was selected, we need this
	if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 || -n "$fallback" || -n "$fallback_udp" ]]; then
		# Install semanage if not already present
		if ! hash semanage 2>/dev/null; then
				dnf install -y policycoreutils-python-utils
		fi
		if [[ "$port" != 1194 ]]; then
			# If the port is already defined in the base policy, modify it instead
			semanage port -a -t openvpn_port_t -p "$protocol" "$port" 2>/dev/null || semanage port -m -t openvpn_port_t -p "$protocol" "$port"
		fi
		if [[ -n "$fallback" ]]; then
			# 443 belongs to http_port_t in the base policy, so modify it
			semanage port -a -t openvpn_port_t -p tcp 443 2>/dev/null || semanage port -m -t openvpn_port_t -p tcp 443
			# Allow OpenVPN to open the loopback connection to the port-share decoy
			setsebool -P openvpn_can_network_connect 1
		fi
		if [[ -n "$fallback_udp" ]]; then
			semanage port -a -t openvpn_port_t -p udp 443 2>/dev/null || semanage port -m -t openvpn_port_t -p udp 443
		fi
	fi
	# If the server is behind NAT, use the correct IP address
	[[ -n "$public_ip" ]] && ip="$public_ip"
	# client-common.txt is created so we have a template to add further users later
	echo "client
dev tun
remote $ip $port $protocol" > /etc/openvpn/server/client-common.txt
	if [[ -n "$fallback_udp" ]]; then
		# UDP 443 fallback (QUIC-like), tried before TCP for better speed
		echo "remote $ip 443 udp" >> /etc/openvpn/server/client-common.txt
	fi
	if [[ -n "$fallback" ]]; then
		# TCP 443 fallback, last resort for networks that block all UDP
		echo "remote $ip 443 tcp" >> /etc/openvpn/server/client-common.txt
	fi
	if [[ -n "$fallback_udp" || -n "$fallback" ]]; then
		# Move on to the next remote quickly when one is unreachable
		echo "connect-timeout 10" >> /etc/openvpn/server/client-common.txt
	fi
	echo "resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name server name
auth SHA512
ignore-unknown-option block-outside-dns
verb 3" >> /etc/openvpn/server/client-common.txt
	# Restart instances automatically if the daemon ever crashes
	mkdir /etc/systemd/system/openvpn-server@.service.d/ 2>/dev/null
	echo "[Service]
Restart=on-failure
RestartSec=5" > /etc/systemd/system/openvpn-server@.service.d/restart-on-failure.conf
	systemctl daemon-reload
	# Enable and start the OpenVPN service
	systemctl enable --now openvpn-server@server.service
	if [[ -n "$fallback" ]]; then
		systemctl enable --now openvpn-server@server-tcp.service
	fi
	if [[ -n "$fallback_udp" ]]; then
		systemctl enable --now openvpn-server@server-udp.service
	fi
	# Nightly maintenance restart during idle hours
	# Instances with connected clients are skipped, so nobody gets disconnected
	echo '#!/bin/bash
for instance in server server-tcp server-udp; do
	[[ -e /etc/openvpn/server/$instance.conf ]] || continue
	# CLIENT_LIST lines are only present while clients are connected
	grep -q "^CLIENT_LIST" /run/openvpn-server/status-$instance.log 2>/dev/null && continue
	systemctl try-restart openvpn-server@$instance.service
done' > /usr/local/sbin/openvpn-idle-restart
	chmod 755 /usr/local/sbin/openvpn-idle-restart
	echo "[Unit]
Description=Restart idle OpenVPN server instances
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openvpn-idle-restart" > /etc/systemd/system/openvpn-idle-restart.service
	echo "[Unit]
Description=Nightly restart of idle OpenVPN server instances
[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=30min
[Install]
WantedBy=timers.target" > /etc/systemd/system/openvpn-idle-restart.timer
	systemctl enable --now openvpn-idle-restart.timer
	# Build the $client.ovpn file, stripping comments from easy-rsa in the process
	grep -vh '^#' /etc/openvpn/server/client-common.txt /etc/openvpn/server/easy-rsa/pki/inline/private/"$client".inline > "$script_dir"/"$client".ovpn
	# Append the client's individual tls-crypt-v2 key
	echo "<tls-crypt-v2>" >> "$script_dir"/"$client".ovpn
	cat /etc/openvpn/server/easy-rsa/pki/private/"$client".tc-v2.key >> "$script_dir"/"$client".ovpn
	echo "</tls-crypt-v2>" >> "$script_dir"/"$client".ovpn
	# The .ovpn file contains the client private key, so restrict access to it
	chmod 600 "$script_dir"/"$client".ovpn
	echo
	echo "Finished!"
	echo
	echo "The client configuration is available in:" "$script_dir"/"$client.ovpn"
	if [[ -n "$fallback_udp" || -n "$fallback" ]]; then
		echo -n "Clients will connect over $protocol $port and fall back to"
		[[ -n "$fallback_udp" ]] && echo -n " UDP 443"
		[[ -n "$fallback_udp" && -n "$fallback" ]] && echo -n " then"
		[[ -n "$fallback" ]] && echo -n " TCP 443"
		echo " automatically."
	fi
	echo "New clients can be added by running this script again."
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
			echo "Provide a name for the client:"
			read -p "Name: " unsanitized_client
			client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			while [[ -z "$client" || -e /etc/openvpn/server/easy-rsa/pki/issued/"$client".crt ]]; do
				echo "$client: invalid name."
				read -p "Name: " unsanitized_client
				client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
			done
			cd /etc/openvpn/server/easy-rsa/
			./easyrsa --batch --days=1095 build-client-full "$client" nopass
			# Create an individual tls-crypt-v2 key for the new client
			openvpn --tls-crypt-v2 /etc/openvpn/server/tc-v2.key --genkey tls-crypt-v2-client pki/private/"$client".tc-v2.key
			# Build the $client.ovpn file, stripping comments from easy-rsa in the process
			grep -vh '^#' /etc/openvpn/server/client-common.txt /etc/openvpn/server/easy-rsa/pki/inline/private/"$client".inline > "$script_dir"/"$client".ovpn
			# Append the client's individual tls-crypt-v2 key
			echo "<tls-crypt-v2>" >> "$script_dir"/"$client".ovpn
			cat /etc/openvpn/server/easy-rsa/pki/private/"$client".tc-v2.key >> "$script_dir"/"$client".ovpn
			echo "</tls-crypt-v2>" >> "$script_dir"/"$client".ovpn
			# The .ovpn file contains the client private key, so restrict access to it
			chmod 600 "$script_dir"/"$client".ovpn
			echo
			echo "$client added. Configuration available in:" "$script_dir"/"$client.ovpn"
			exit
		;;
		2)
			# This option could be documented a bit better and maybe even be simplified
			# ...but what can I say, I want some sleep too
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
				rm -f /etc/openvpn/server/easy-rsa/pki/reqs/"$client".req
				rm -f /etc/openvpn/server/easy-rsa/pki/private/"$client".key
				rm -f /etc/openvpn/server/easy-rsa/pki/private/"$client".tc-v2.key
				cp /etc/openvpn/server/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem
				# CRL is read with each client connection, when OpenVPN is dropped to nobody
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
					ip=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep '\-s 10.8.0.0/24 '"'"'!'"'"' -d 10.8.0.0/24' | grep -oE '[^ ]+$')
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --remove-port="$port"/"$protocol"
					firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --permanent --remove-port="$port"/"$protocol"
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
					firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
					if grep -qs "server-ipv6" /etc/openvpn/server/server.conf; then
						ip6=$(firewall-cmd --direct --get-rules ipv6 nat POSTROUTING | grep '\-s fddd:1194:1194:1194::/64 '"'"'!'"'"' -d fddd:1194:1194:1194::/64' | grep -oE '[^ ]+$')
						firewall-cmd --zone=trusted --remove-source=fddd:1194:1194:1194::/64
						firewall-cmd --permanent --zone=trusted --remove-source=fddd:1194:1194:1194::/64
						firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
						firewall-cmd --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ip6"
					fi
					if [[ -e /etc/openvpn/server/server-tcp.conf ]]; then
						firewall-cmd --remove-port=443/tcp
						firewall-cmd --zone=trusted --remove-source=10.8.1.0/24
						firewall-cmd --permanent --remove-port=443/tcp
						firewall-cmd --permanent --zone=trusted --remove-source=10.8.1.0/24
						firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.1.0/24 ! -d 10.8.1.0/24 -j SNAT --to "$ip"
						firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.1.0/24 ! -d 10.8.1.0/24 -j SNAT --to "$ip"
						if grep -qs "server-ipv6" /etc/openvpn/server/server-tcp.conf; then
							firewall-cmd --zone=trusted --remove-source=fddd:1195:1195:1195::/64
							firewall-cmd --permanent --zone=trusted --remove-source=fddd:1195:1195:1195::/64
							firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1195:1195:1195::/64 ! -d fddd:1195:1195:1195::/64 -j SNAT --to "$ip6"
							firewall-cmd --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1195:1195:1195::/64 ! -d fddd:1195:1195:1195::/64 -j SNAT --to "$ip6"
						fi
					fi
					if [[ -e /etc/openvpn/server/server-udp.conf ]]; then
						firewall-cmd --remove-port=443/udp
						firewall-cmd --zone=trusted --remove-source=10.8.2.0/24
						firewall-cmd --permanent --remove-port=443/udp
						firewall-cmd --permanent --zone=trusted --remove-source=10.8.2.0/24
						firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.2.0/24 ! -d 10.8.2.0/24 -j SNAT --to "$ip"
						firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.2.0/24 ! -d 10.8.2.0/24 -j SNAT --to "$ip"
						if grep -qs "server-ipv6" /etc/openvpn/server/server-udp.conf; then
							firewall-cmd --zone=trusted --remove-source=fddd:1196:1196:1196::/64
							firewall-cmd --permanent --zone=trusted --remove-source=fddd:1196:1196:1196::/64
							firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1196:1196:1196::/64 ! -d fddd:1196:1196:1196::/64 -j SNAT --to "$ip6"
							firewall-cmd --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1196:1196:1196::/64 ! -d fddd:1196:1196:1196::/64 -j SNAT --to "$ip6"
						fi
					fi
				else
					systemctl disable --now openvpn-iptables.service
					rm -f /etc/systemd/system/openvpn-iptables.service
				fi
				if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing"; then
					if [[ "$port" != 1194 ]]; then
						semanage port -d -t openvpn_port_t -p "$protocol" "$port"
					fi
					if [[ -e /etc/openvpn/server/server-tcp.conf ]]; then
						semanage port -d -t openvpn_port_t -p tcp 443
					fi
					if [[ -e /etc/openvpn/server/server-udp.conf ]]; then
						semanage port -d -t openvpn_port_t -p udp 443
					fi
				fi
				systemctl disable --now openvpn-server@server.service
				if [[ -e /etc/openvpn/server/server-tcp.conf ]]; then
					systemctl disable --now openvpn-server@server-tcp.service
				fi
				if [[ -e /etc/openvpn/server/server-udp.conf ]]; then
					systemctl disable --now openvpn-server@server-udp.service
				fi
				systemctl disable --now openvpn-idle-restart.timer
				rm -f /etc/systemd/system/openvpn-idle-restart.timer /etc/systemd/system/openvpn-idle-restart.service /usr/local/sbin/openvpn-idle-restart
				rm -f /etc/systemd/system/openvpn-server@.service.d/disable-limitnproc.conf
				rm -f /etc/systemd/system/openvpn-server@.service.d/restart-on-failure.conf
				rm -f /etc/sysctl.d/99-openvpn-forward.conf
				# Remove the port-share decoy site (nginx itself is left installed)
				if [[ -e /etc/nginx/conf.d/openvpn-decoy.conf ]]; then
					rm -f /etc/nginx/conf.d/openvpn-decoy.conf
					rm -rf /var/www/openvpn-decoy
					systemctl reload nginx 2>/dev/null
				fi
				if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
					rm -rf /etc/openvpn/server
					apt-get remove --purge -y openvpn
				else
					# Else, OS must be CentOS or Fedora
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
