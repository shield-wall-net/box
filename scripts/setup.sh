#!/usr/bin/env bash

set -euo pipefail

echo ''
echo '######################'
echo '### SHIELDWALL BOX ###'
echo '######################'
echo ''

if [[ "$(id -u)" != '0' ]]
then
  echo "ERROR: Script needs to be ran as root!"
  exit 1
fi

# shellcheck disable=SC2009
if ! [[ -f '/lib/systemd/systemd' ]] || ! ps 1 | grep -qE 'systemd|/sbin/init'
then
  echo "ERROR: ShieldWall depends on Systemd! Init process is other!"
  exit 1
fi

function log() {
  echo ''
  echo "### $1 ###"
  echo ''
  sleep 2
}

function insert_after() {
  file="$1"
  after="$2"
  insert="$3"
  line_nr=$(grep -Fn "$after" "$file" | cut -d ':' -f1)
  line_nr=$(( line_nr + 1 ))
  cp "$file" "${file}.old"
  awk -v insert="$insert\n" -v line_nr="$line_nr" 'NR==line_nr{printf insert}1' "${file}.old" > "$file"
}

function new_service() {
  echo "Enabling & starting $1.service ..."
  systemctl daemon-reload
  systemctl enable "$1.service"
  systemctl start "$1.service"
  systemctl restart "$1.service"
}

BOX_VERSION='latest'
CTRL_VERSION='latest'
REPO_CTRL="https://raw.githubusercontent.com/shield-wall-net/controller/${CTRL_VERSION}"

USER='shieldwall'
USER_ID='2000'
DIR_HOME='/home/shieldwall'
DIR_LIB='/var/local/lib/shieldwall'
DIR_SCRIPT='/usr/local/bin/shieldwall'
DIR_LOG='/var/log/shieldwall'
DIR_CNF='/etc/shieldwall'

cd '/tmp/'

log 'INSTALLING TIMESYNC'
apt install systemd-timesyncd
printf '[Time]\nNTP=0.pool.ntp.org 1.pool.ntp.org\n' > '/etc/systemd/timesyncd.conf'
systemctl enable systemd-timesyncd
systemctl start systemd-timesyncd
systemctl restart systemd-timesyncd
sleep 5

log 'INSTALLING DEPENDENCIES & UTILS'
apt update
apt -y --upgrade install openssl python3 wget gpg lsb-release apt-transport-https ca-certificates gnupg curl net-tools dnsutils zip

log 'DOWNLOADING SETUP FILES'
wget "https://codeload.github.com/shield-wall-net/box/zip/refs/heads/${BOX_VERSION}" -O '/tmp/shieldwall_box.zip'
DIR_SETUP="/tmp/box-${BOX_VERSION}"

log 'INSTALLING PACKET-FILTER'
apt -y remove ufw firewalld* arptables ebtables xtables*
apt -y purge ufw firewalld* arptables ebtables xtables*
if ! [ -f '/etc/systemd/system/docker.service.d/override.conf' ]
then
  apt -y remove iptables*
  apt -y purge iptables*
fi
apt -y --upgrade install nftables

log 'INSTALLING SYSLOG'
apt -y --upgrade install rsyslog rsyslog-openssl logrotate

log 'INSTALLING PROXY'
apt -y --upgrade install squid-openssl

log 'CREATING SERVICE-USER & DIRECTORIES'
DISTRO=$(lsb_release -i -s | tr '[:upper:]' '[:lower:]')
CODENAME=$(lsb_release -c -s | tr '[:upper:]' '[:lower:]')
CPU_ARCH=$(uname -i)
# BOX_IPS=$(ip a | grep inet | cut -d ' ' -f6 | cut -d '/' -f1)

if [[ "$CPU_ARCH" == 'unknown' ]] || [[ "$CPU_ARCH" == 'x86_64' ]]
then
  CPU_ARCH='amd64'
fi

if ! grep -q "$USER" < /etc/passwd
then
  useradd "$USER" --shell /bin/bash --home-dir "$DIR_HOME" --create-home --uid "$USER_ID"
fi
chown -R "$USER":'root' "$DIR_HOME"
chmod 750 "$DIR_HOME"

mkdir -p "$DIR_LIB" "$DIR_SCRIPT" "$DIR_LOG" "$DIR_CNF"
chown "$USER" "$DIR_LIB" "$DIR_CNF"
chown "$USER":"$USER" "$DIR_SCRIPT" "$DIR_LOG"
chmod 750 "$DIR_LIB" "$DIR_SCRIPT" "$DIR_CNF"
chmod 770 "$DIR_LOG"
chmod 700 "${DIR_CNF}/ssl"

touch "${DIR_CNF}/update.env"
chown "$USER" "${DIR_CNF}/update.env"

# so services don't die until we get the actual certs
if ! [ -f '/etc/ssl/certs/shieldwall.box.crt' ]
then
  DUMMY_CERT_CN='/C=AT/O=shield-wall.net/CN=ShieldWall Box Dummy Cert'
  openssl req -x509 -newkey rsa:4096 -keyout '/etc/ssl/private/shieldwall.box.key' -out '/etc/ssl/certs/shieldwall.box.crt' -sha256 -days 3650 -nodes -subj "$DUMMY_CERT_CN"
  DUMMY_CA_CN='/C=AT/O=shield-wall.net/CN=ShieldWall Box Dummy CA'
  openssl req -x509 -newkey rsa:4096 -keyout '/tmp/dummy.txt' -out '/etc/ssl/certs/shieldwall.ca.crt' -sha256 -days 3650 -nodes -subj "$DUMMY_CA_CN"
  rm '/tmp/dummy.txt'
  ln -s '/etc/ssl/certs/shieldwall.ca.crt' '/etc/ssl/certs/shieldwall.trusted_cas.crt'
fi
chown "$USER" '/etc/ssl/certs/shieldwall.box.crt' '/etc/ssl/private/shieldwall.box.key' '/etc/ssl/certs/shieldwall.ca.crt'
groupadd 'ssl-cert'
chown "$USER":'ssl-cert' '/etc/ssl/private'
chmod 750 '/etc/ssl/private'

log 'UPDATING DEFAULT APT-REPOSITORIES'
rm '/etc/apt/sources.list'
cp "${DIR_SETUP}/files/apt/sources.list" '/etc/apt/sources.list'
sed -i "s/CODENAME/$CODENAME/g" '/etc/apt/sources.list'

log 'INSTALLING DOCKER (containerized packages)'
DOCKER_GPG_FILE='/usr/share/keyrings/docker-archive-keyring.gpg'
DOCKER_REPO_FILE='/etc/apt/sources.list.d/docker.list'

if ! [ -f "$DOCKER_GPG_FILE" ]
then
  wget -4 "https://download.docker.com/linux/${DISTRO}/gpg" -O "${DOCKER_GPG_FILE}_armored"
  gpg --dearmor < "${DOCKER_GPG_FILE}_armored" > "$DOCKER_GPG_FILE"
fi

if ! [ -f "$DOCKER_REPO_FILE" ]
then
  docker_repo="deb [arch=${CPU_ARCH} signed-by=${DOCKER_GPG_FILE}] https://download.docker.com/linux/${DISTRO} ${CODENAME} stable"
  echo "$docker_repo" > "$DOCKER_REPO_FILE"
fi

chmod 644 "$DOCKER_GPG_FILE" "$DOCKER_REPO_FILE"
chown "$USER" "$DOCKER_GPG_FILE" "$DOCKER_REPO_FILE"

apt update
apt -y install docker-ce containerd.io

mkdir -p '/etc/systemd/system/docker.service.d/'
cp "${DIR_SETUP}/files/docker.override.conf" '/etc/systemd/system/docker.service.d/override.conf'
chown "$USER" '/etc/systemd/system/docker.service.d/override.conf'
new_service 'docker'

log 'ADDING PROXY BASE CONFIG'
# dockerized proxy would be preferred; but it does not work as docker DNAT's the traffic sent to its listener
SQUID_USER='proxy'
SQUID_DIR_CONF='/etc/squid'
SQUID_DIR_LIB='/var/lib/squid'
SQUID_DIR_CACHE='/var/spool/squid'
SQUID_DIR_SSL="${SQUID_DIR_LIB}/ssl"
SQUID_CONFIG="${SQUID_DIR_CONF}/squid.conf"

usermod -a -G "$USER" "$SQUID_USER"
mkdir -p /etc/systemd/system/squid.service.d/
cp "${DIR_SETUP}/files/squid/override.conf" '/etc/systemd/system/squid.service.d/override.conf'
chown "$USER" '/etc/systemd/system/squid.service.d/override.conf'

cp "${DIR_SETUP}/files/squid/main.conf" "$SQUID_CONFIG"
chown "$USER":"$SQUID_USER" "$SQUID_CONFIG"
chmod 640 "$SQUID_CONFIG"

cp "${DIR_SETUP}/files/squid/startup.sh" "${DIR_SCRIPT}/squid_startup.sh"
chown "$USER":"$SQUID_USER" "${DIR_SCRIPT}/squid_startup.sh"
chmod 750 "${DIR_SCRIPT}/squid_startup.sh"

squid_create_dir() {
  directory="$1"
  if ! [ -d "$directory" ]
  then
    mkdir -p "$directory"
  fi
  chown -R "$SQUID_USER":"$SQUID_USER" "$directory"
  chmod 750 "$directory"
}

squid_create_dir "$SQUID_DIR_CACHE"
squid_create_dir "$SQUID_DIR_SSL"
squid_create_dir "$SQUID_DIR_LIB"
new_service 'squid'

log 'ADDING FIREWALL BASE CONFIG'
modprobe nft_ct
modprobe nft_log
modprobe nft_nat
modprobe nft_redir
modprobe nft_limit
modprobe nft_quota
modprobe nft_connlimit
modprobe nft_reject

function insert_nftables_block() {
    mark="$1"
    cp "${DIR_SETUP}/files/nftables/setup_${mark}.conf" "/tmp/nftables_setup_${mark}.conf"
    to_insert=$(cat "/tmp/nftables_setup_${mark}.conf")
    insert_after '/tmp/nftables_managed.j2' "# MARK: INSERT BOX-SETUP ${mark}" "$to_insert"
}

mkdir -p '/etc/nftables.d/' '/etc/systemd/system/nftables.service.d/'
cp "${DIR_SETUP}/files/nftables/override.conf" '/etc/systemd/system/nftables.service.d/override.conf'
chown "$USER" '/etc/systemd/system/nftables.service.d/override.conf'

cp "${DIR_SETUP}/files/nftables/main.conf" '/etc/nftables.conf'
wget -4 "${REPO_CTRL}/templates/packet_filter/nftables_box_base.j2" -O '/tmp/nftables_managed.j2'

insert_nftables_block 'input'
insert_nftables_block 'prerouting_dnat'

grep -v "{% " < '/tmp/nftables_managed.j2' > '/etc/nftables.d/managed.conf'

chmod 750 '/etc/nftables.d/'
chmod 640 '/etc/nftables.conf' '/etc/nftables.d/managed.conf'
chown -R "$USER":"$USER" /etc/nftables*
new_service 'nftables'

log 'SYSCTL CONFIG'
wget -4 "${REPO_CTRL}/templates/sysctl.j2" -O '/tmp/sysctl.conf'
grep -v "{" < '/tmp/sysctl.conf' > '/etc/sysctl.d/shieldwall.conf'
chmod 640 '/etc/sysctl.d/shieldwall.conf'
chown "$USER" '/etc/sysctl.d/shieldwall.conf'

log 'LOGGING CONFIG'
cp "${DIR_SETUP}/files/rsyslog/forward.conf" '/etc/rsyslog.d/0_shieldwall_forward.conf'
cp "${DIR_SETUP}/files/rsyslog/box.conf" '/etc/rsyslog.d/1_shieldwall_box.conf'
cp "${DIR_SETUP}/files/rsyslog/update.conf" '/etc/rsyslog.d/1_shieldwall_update.conf'
cp "${DIR_SETUP}/files/rsyslog/nftables.conf" '/etc/rsyslog.d/1_shieldwall_nftables.conf'
cp "${DIR_SETUP}/files/rsyslog/proxy.conf" '/etc/rsyslog.d/1_shieldwall_proxy.conf'
cp "${DIR_SETUP}/files/logrotate.conf" '/etc/logrotate.d/shieldwall'

chown "$USER" /etc/rsyslog.d/*shieldwall*
chown "$USER" '/etc/logrotate.d/shieldwall'

new_service 'rsyslog'
new_service 'logrotate'

echo '#########################################'
log 'SETUP FINISHED! Please reboot the system!'

exit 0
