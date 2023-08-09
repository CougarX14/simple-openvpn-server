#!/bin/bash
echo $@

# defaults 
ADMINPASSWORD="secret"
DNS1="8.8.8.8"
DNS2="8.8.4.4"
PROTOCOL=udp
EMAIL="example@example.com"
PORT=1194
HOST=$(wget -4qO- "http://whatismyip.akamai.com/")
NETWORK="$NETWORK"

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --adminpassword)
      ADMINPASSWORD="$2"
      shift # past argument
      shift # past value
      ;;
    --dns1)
      DNS1="$2"
      shift # past argument
      shift # past value
      ;;
    --dns2)
      DNS2="$2"
      shift # past argument
      shift # past value
      ;;
    --vpnport)
      PORT="$2"
      shift # past argument
      ;;
    --protocol)
      PROTOCOL="$2"
      shift # past argument
      ;;
    --host)
      HOST="$2"
      shift # past argument
      ;;
    --network)
      NETWORK="$2"
      shift # past argument
      ;;
    --email)
      EMAIL="$2"
      shift # past argument
      ;;
    *)    # unknown option
      POSITIONAL+=("$1") # save it in an array for later
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL[@]}" # restore positional parameters

echo "ADMIN PASSWORD  = ${ADMINPASSWORD}"
echo "EMAIL  = ${EMAIL}"
echo "DNS1            = ${DNS1}"
echo "DNS2            = ${DNS2}"
echo "HOST            = ${HOST}"
echo "PORT            = ${PORT}"
echo "PROTOCOL        = ${PROTOCOL}"
echo "NETWORK         = ${NETWORK}"

[ "${ADMINPASSWORD}" == "secret" ] && echo "fatal: password is not set" && exit 1

# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -qs "dash"; then
	echo "This script needs to be run with bash, not sh"
	exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "Sorry, you need to run this as root"
	exit 2
fi

if [[ ! -e /dev/net/tun ]]; then
	echo "The TUN device is not available. You need to enable TUN before running this script."
	exit 3
fi


if [[ -e /etc/debian_version ]]; then
	OS=debian
	GROUPNAME=nogroup
	RCLOCAL='/etc/rc.local'
else
	echo "Looks like you aren't running this installer on Debian or Ubuntu"
	exit 5
fi

# Try to get our IP from the system and fallback to the Internet.

IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
if [[ "$IP" = "" ]]; then
	IP=$(wget -4qO- "http://whatismyip.akamai.com/")
fi

#apt-get clean
#mv /var/lib/apt/lists /tmp
#mkdir -p /var/lib/apt/lists/partial
#apt-get clean
apt-get update
apt-get install openvpn iptables openssl fcgiwrap ca-certificates certbot python3-certbot-nginx apache2-utils nginx -y

# An old version of easy-rsa was available by default in some openvpn packages
if [[ -d /etc/openvpn/easy-rsa/ ]]; then
	rm -rf /etc/openvpn/easy-rsa/
fi
# Get easy-rsa

#wget -O ~/EasyRSA-3.0.1.tgz "https://github.com/OpenVPN/easy-rsa/releases/download/3.0.1/EasyRSA-3.0.1.tgz"
#tar xzf ~/EasyRSA-3.0.1.tgz -C ~/
#mv ~/EasyRSA-3.0.1/ /etc/openvpn/
#mv /etc/openvpn/EasyRSA-3.0.1/ /etc/openvpn/easy-rsa/
#chown -R root:root /etc/openvpn/easy-rsa/
#rm -rf ~/EasyRSA-3.0.1.tgz
#cd /etc/openvpn/easy-rsa/

# Create the PKI, set up the CA, the DH params and the server + client certificates
#./easyrsa init-pki
#./easyrsa --batch build-ca nopass
#./easyrsa gen-dh
#./easyrsa build-server-full server nopass

# ./easyrsa build-client-full $CLIENT nopass
#EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl

# Move the stuff we need
#cp pki/ca.crt pki/private/ca.key pki/dh.pem pki/issued/server.crt pki/private/server.key /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn

# CRL is read with each client connection, when OpenVPN is dropped to nobody
#chown nobody:$GROUPNAME /etc/openvpn/crl.pem



easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.1.5/EasyRSA-3.1.5.tgz'
mkdir -p /etc/openvpn/server/easy-rsa/
{ wget -qO- "$easy_rsa_url" 2>/dev/null || curl -sL "$easy_rsa_url" ; } | tar xz -C /etc/openvpn/server/easy-rsa/ --strip-components 1
chown -R root:root /etc/openvpn/server/easy-rsa/
cd /etc/openvpn/server/easy-rsa/
# Create the PKI, set up the CA and the server and client certificates
./easyrsa --batch init-pki
./easyrsa --batch build-ca nopass
./easyrsa --batch --days=3650 build-server-full server nopass
#./easyrsa --batch --days=3650 build-client-full "$client" nopass
./easyrsa --batch --days=3650 gen-crl
# Move the stuff we need
cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server
# CRL is read with each client connection, while OpenVPN is dropped to nobody
chown nobody:"$group_name" /etc/openvpn/server/crl.pem
# Without +x in the directory, OpenVPN can't run a stat() on the CRL file
chmod o+x /etc/openvpn/server/

# Generate key for tls-auth
openvpn --genkey --secret /etc/openvpn/ta.key

# Generate server.conf
echo "port $PORT
proto $PROTOCOL
dev tun
sndbuf 0
rcvbuf 0
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-auth ta.key 0
topology subnet
server $NETWORK 255.255.255.0
ifconfig-pool-persist ipp.txt" > /etc/openvpn/server.conf
#echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server.conf

# DNS
#echo "push \"dhcp-option DNS $DNS1\"" >> /etc/openvpn/server.conf
#echo "push \"dhcp-option DNS $DNS2\"" >> /etc/openvpn/server.conf
echo "keepalive 10 120
cipher AES-256-CBC

user nobody
group $GROUPNAME
persist-key
persist-tun
status openvpn-status.log
verb 4
log openvpn_server.log
crl-verify crl.pem


# EXAMPLE: Suppose the client
# having the certificate common name "Thelonious"
# also has a small subnet behind his connecting
# machine, such as 192.168.40.128/255.255.255.248.
# First, uncomment out these lines:
;client-config-dir ccd
;route 192.168.40.128 255.255.255.248

# Then create a file ccd/Thelonious with this line:
#   iroute 192.168.40.128 255.255.255.248
# This will allow Thelonious' private subnet to
# access the VPN.  This example will only work
# if you are routing, not bridging, i.e. you are
# using "dev tun" and "server" directives.

# Push routes to the client to allow it
# to reach other private subnets behind
# the server.  Remember that these
# private subnets will also need
# to know to route the OpenVPN client
# address pool (10.8.X.0/255.255.255.0)
# back to the OpenVPN server.
;push \"route 192.168.10.0 255.255.255.0\"
 
# Uncomment this directive to allow different
# clients to be able to "see" each other.
# By default, clients will only see the server.
# To force clients to only see the server, you
# will also need to appropriately firewall the
# server's TUN/TAP interface.
client-to-client" >> /etc/openvpn/server.conf

# Enable net.ipv4.ip_forward for the system
sed -i '/\<net.ipv4.ip_forward\>/c\net.ipv4.ip_forward=1' /etc/sysctl.conf
if ! grep -q "\<net.ipv4.ip_forward\>" /etc/sysctl.conf; then
	echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

# Avoid an unneeded reboot
echo 1 > /proc/sys/net/ipv4/ip_forward
if pgrep firewalld; then
	# Using both permanent and not permanent rules to avoid a firewalld
	# reload.
	# We don't use --add-service=openvpn because that would only work with
	# the default port and protocol.
	firewall-cmd --zone=public --add-port=$PORT/$PROTOCOL
	firewall-cmd --zone=trusted --add-source=$NETWORK/24
	firewall-cmd --permanent --zone=public --add-port=$PORT/$PROTOCOL
	firewall-cmd --permanent --zone=trusted --add-source=$NETWORK/24
	# Set NAT for the VPN subnet
	firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s $NETWORK/24 -j SNAT --to $IP
	firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s $NETWORK/24 -j SNAT --to $IP
else
	# Needed to use rc.local with some systemd distros
	if [[ "$OS" = 'debian' && ! -e $RCLOCAL ]]; then
		echo '#!/bin/sh -e
exit 0' > $RCLOCAL
	fi
	chmod +x $RCLOCAL
	# Set NAT for the VPN subnet
	iptables -t nat -A POSTROUTING -s $NETWORK/24 -j SNAT --to $IP
	sed -i "1 a\iptables -t nat -A POSTROUTING -s $NETWORK/24 -j SNAT --to $IP" $RCLOCAL
	if iptables -L -n | grep -qE '^(REJECT|DROP)'; then
		# If iptables has at least one REJECT rule, we asume this is needed.
		# Not the best approach but I can't think of other and this shouldn't
		# cause problems.
		iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT
		iptables -I FORWARD -s $NETWORK/24 -j ACCEPT
		iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
		sed -i "1 a\iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -s $NETWORK/24 -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" $RCLOCAL
	fi
fi
# If SELinux is enabled and a custom port or TCP was selected, we need this
if hash sestatus 2>/dev/null; then
	if sestatus | grep "Current mode" | grep -qs "enforcing"; then
		if [[ "$PORT" != '1194' || "$PROTOCOL" = 'tcp' ]]; then
			# semanage isn't available in CentOS 6 by default
			if ! hash semanage 2>/dev/null; then
				yum install policycoreutils-python -y
			fi
			semanage port -a -t openvpn_port_t -p $PROTOCOL $PORT
		fi
	fi
fi

# And finally, restart OpenVPN

# Little hack to check for systemd
if pgrep systemd-journal; then
	systemctl restart openvpn@server.service
else
	/etc/init.d/openvpn restart
fi


# Try to detect a NATed connection and ask about it to potential LowEndSpirit users


# client-common.txt is created so we have a template to add further users later
echo "client
dev tun
proto $PROTOCOL
sndbuf 0
rcvbuf 0
remote $HOST $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-CBC
key-direction 1
verb 3" > /etc/openvpn/client-common.txt

# Generates the custom client.ovpn
mv /etc/openvpn/clients/ /etc/openvpn/clients.$$/
mkdir /etc/openvpn/clients/

#Setup the web server to use an self signed cert
# mkdir /etc/openvpn/clients/

#Set permissions for easy-rsa and open vpn to be modified by the web user.
chown -R www-data:www-data /etc/openvpn/easy-rsa
chown -R www-data:www-data /etc/openvpn/clients/
chmod -R 755 /etc/openvpn/
chmod -R 777 /etc/openvpn/crl.pem
chmod g+s /etc/openvpn/clients/
chmod g+s /etc/openvpn/easy-rsa/

#Generate a self-signed certificate for the web server
# mv /etc4/lighttpd/ssl/ /etc/lighttpd/ssl.$$/
# mkdir /etc/nginx/ssl/
# openssl req -x509 -nodes -days 9999 -newkey rsa:2048 -keyout /etc/nginx/ssl/nginx.key -out /etc/nginx/ssl/nginx.crt -subj "/C=US/ST=California/L=San Francisco/O=example.com/OU=Ops Department/CN=example.com"


#Configure the web server with the lighttpd.conf from GitHub
mv  /etc/nginx/sites-available/default /etc/nginx/sites-available/default.$$
wget -O /etc/nginx/sites-available/default https://raw.githubusercontent.com/cougarx14/simple-openvpn-server/featureUpdate/default

sed -i "s/server_name  example.com;/server_name  $HOST;/g" /etc/nginx/sites-available/default


#install the webserver scripts
rm /var/www/html/*
mkdir -p /var/www/html/
wget -O /var/www/html/index.sh https://raw.githubusercontent.com/cougarx14/simple-openvpn-server/featureUpdate/index.sh

wget -O /var/www/html/download.sh https://raw.githubusercontent.com/cougarx14/simple-openvpn-server/featureUpdate/download.sh
chown -R www-data:www-data /var/www/html/
chmod +x /var/www/html/*

#set the password file for the WWW logon
# systecho "admin:$ADMINPASSWORD" >> /etc/lighttpd/.lighttpdpassword
htpasswd -b -c /etc/nginx/.htpasswd admin $ADMINPASSWORD


#Obtain a Certificate from Let's Encrypt
certbot run -d $HOST --agree-tos --nginx --test-cert -m $EMAIL -n
#systemctl restart apache2

#restart the web server
systemctl restart nginx
