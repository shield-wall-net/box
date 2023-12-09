#!/usr/bin/env bash

set -eo pipefail

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
if ! [ -f '/lib/systemd/systemd' ] || ! ps 1 | grep -qE 'systemd|/sbin/init'
then
  echo "ERROR: ShieldWall depends on Systemd! Init process is other!"
  exit 1
fi

# todo: support for dns
if [ -z "$1" ]
then
  echo "ERROR: You need to supply the controller IP (v4) as argument 1!"
  exit 1
fi

IS_CONTAINER=$(grep -c 'lxc|docker' < '/proc/self/mountinfo')
if [[ "$IS_CONTAINER" != "0" ]]
then
  echo "ERROR: ShieldWall Box not supported to run in a containerized environment!"
  exit 1
fi

set -u

CONTROLLER_IP="$1"
echo "${CONTROLLER_IP} controller.shieldwall" >> '/etc/hosts'

if ! [ -f '/etc/shieldwall_id.txt' ]
then
  echo "WARNING: ShieldWall-Box-ID was not found! (/etc/shieldwall_id.txt)"
  echo '00000000-0000-0000-0000-000000000000' > '/etc/shieldwall_id.txt'
  echo '127.0.0.1 00000000-0000-0000-0000-000000000000.box.shieldwall' >> '/etc/hosts'
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

function purge_pkg() {
  # shellcheck disable=SC2086
  apt -y remove $1 || true
  # shellcheck disable=SC2086
  apt -y purge $1 || true
}

BOX_VERSION='latest'
CTRL_VERSION='latest'
REPO_CTRL="https://raw.githubusercontent.com/shield-wall-net/controller/${CTRL_VERSION}"

USER='shieldwall'
USER_ID='2000'
USER_ID_PROM='2001'
USER_ID_NETFLOW='2002'
DIR_HOME='/home/shieldwall'
DIR_LIB='/var/local/lib/shieldwall'
DIR_LOG='/var/log/shieldwall'
DIR_CNF='/etc/shieldwall'
DIR_CACHE='/var/cache/shieldwall'

cd '/tmp/'

log 'SETTING DEFAULT LANGUAGE'
export LANG="en_US.UTF-8"
export LANGUAGE="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
update-locale LANG=en_US.UTF-8 || true
dpkg-reconfigure --frontend=noninteractive locales

log 'INSTALLING TIMESYNC'
apt install systemd-timesyncd
printf '[Time]\nNTP=0.pool.ntp.org 1.pool.ntp.org\n' > '/etc/systemd/timesyncd.conf'
systemctl enable systemd-timesyncd
systemctl start systemd-timesyncd
systemctl restart systemd-timesyncd
sleep 5

log 'INSTALLING DEPENDENCIES & UTILS'
apt update
apt -y --upgrade install openssl python3 wget gpg lsb-release apt-transport-https ca-certificates gnupg curl net-tools dnsutils zip ncdu man

log 'DOWNLOADING SETUP FILES'
DIR_SETUP="/tmp/box-${BOX_VERSION}"
rm -rf "$DIR_SETUP"
wget "https://codeload.github.com/shield-wall-net/box/zip/refs/heads/${BOX_VERSION}" -O '/tmp/shieldwall_box.zip'
unzip 'shieldwall_box.zip'

log 'INSTALLING PACKET-FILTER'
purge_pkg 'ufw'
purge_pkg 'firewalld*'
purge_pkg 'arptables'
purge_pkg 'ebtables'
purge_pkg 'xtables*'
purge_pkg 'iptables*'
apt -y --upgrade install nftables

log 'INSTALLING SYSLOG'
apt -y --upgrade install rsyslog rsyslog-gnutls logrotate

log 'INSTALLING NETFLOW'
apt -y --upgrade install softflowd

log 'INSTALLING PROXY'
apt -y --upgrade install squid-openssl

log 'CREATING SERVICE-USER & DIRECTORIES'
#DISTRO=$(lsb_release -i -s | tr '[:upper:]' '[:lower:]')
CODENAME="$(lsb_release -c -s | tr '[:upper:]' '[:lower:]')"
CPU_ARCH_RAW="$(uname -i)"

# BOX_IPS=$(ip a | grep inet | cut -d ' ' -f6 | cut -d '/' -f1)
if [[ "$CPU_ARCH_RAW" == 'unknown' ]] && [[ "$IS_CONTAINER" == "0" ]]
then
  IS_CONTAINER="1"
fi

if [[ "$CPU_ARCH_RAW" == 'unknown' ]]
then
  $CPU_ARCH_RAW='x86_64'
fi
if [[ "$CPU_ARCH_RAW" == 'x86_64' ]]
then
  CPU_ARCH='amd64'
else
  CPU_ARCH="$CPU_ARCH_RAW"
fi

function download_latest_github_release_filter_arch() {
  gh_user="$1"
  gh_repo="$2"
  out_file="$3"
  filter="$4"
  filter_exclude="$5"
  arch="$6"
  url="$(curl -s "https://api.github.com/repos/${gh_user}/${gh_repo}/releases/latest" | grep 'download_url' | grep "linux-${arch}" | grep "$filter" | grep -Ev "$filter_exclude" | head -n 1 | cut -d '"' -f 4)"
  wget -4 "$url" -O "$out_file"
}

function download_latest_github_release_filter() {
  download_latest_github_release_filter_arch "$1" "$2" "$3" "$4" "$5" "${CPU_ARCH}"
}

function download_latest_github_release() {
  download_latest_github_release_filter "$1" "$2" "$3" '' '$%&'
}

if ! grep -q "$USER" < '/etc/passwd'
then
  useradd "$USER" --shell '/bin/bash' --home-dir "$DIR_HOME" --create-home --uid "$USER_ID"
fi
chown -R "$USER":'root' "$DIR_HOME"
chmod 750 "$DIR_HOME"

if ! grep -q 'ssl-cert' < '/etc/group'
then
  groupadd 'ssl-cert'
fi

mkdir -p "$DIR_LIB" "$DIR_LOG" "$DIR_CNF" "$DIR_CACHE"
chown "$USER" "$DIR_LIB" "$DIR_CNF"
chown "$USER":"$USER" "$DIR_CACHE"
chown 'root':'adm' "$DIR_LOG"
chmod 750 "$DIR_LIB" "$DIR_CNF" "$DIR_LOG"
chmod 770 "$DIR_CACHE"

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
chown "$USER":'ssl-cert' '/etc/ssl/certs/shieldwall.box.crt' '/etc/ssl/private/shieldwall.box.key' '/etc/ssl/certs/shieldwall.ca.crt'
chown "$USER":'ssl-cert' '/etc/ssl/private'
chmod 750 '/etc/ssl/private'
chmod 640 '/etc/ssl/private/shieldwall.box.key'

log 'UPDATING DEFAULT APT-REPOSITORIES'
rm -f '/etc/apt/sources.list'
cp "${DIR_SETUP}/files/apt/sources.list" '/etc/apt/sources.list'
sed -i "s/CODENAME/$CODENAME/g" '/etc/apt/sources.list'
apt update

log 'ADDING PROXY BASE CONFIG'
SQUID_USER='proxy'
SQUID_DIR_CONF='/etc/squid'
SQUID_DIR_LIB='/var/lib/squid'
SQUID_DIR_CACHE='/var/spool/squid'
SQUID_DIR_SSL="${SQUID_DIR_LIB}/ssl"
SQUID_CONFIG="${SQUID_DIR_CONF}/squid.conf"

usermod -a -G "$USER" "$SQUID_USER"
mkdir -p /etc/systemd/system/squid.service.d/
cp "${DIR_SETUP}/files/squid/service_override.conf" '/etc/systemd/system/squid.service.d/override.conf'
chown "$USER" '/etc/systemd/system/squid.service.d/override.conf'

cp "${DIR_SETUP}/files/squid/main.conf" "$SQUID_CONFIG"
chown "$USER":"$SQUID_USER" "$SQUID_CONFIG"
chmod 640 "$SQUID_CONFIG"

cp "${DIR_SETUP}/files/squid/startup.sh" '/usr/local/bin/squid_startup.sh'
chown "$USER":"$SQUID_USER" '/usr/local/bin/squid_startup.sh'
chmod 750 '/usr/local/bin/squid_startup.sh'

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
    cp "${DIR_SETUP}/files/packet_filter/setup_${mark}.conf" "/tmp/nftables_setup_${mark}.conf"
    to_insert=$(cat "/tmp/nftables_setup_${mark}.conf")
    insert_after '/tmp/nftables_managed.j2' "# MARK: INSERT BOX-SETUP ${mark}" "$to_insert"
}

mkdir -p '/etc/nftables.d/' '/etc/systemd/system/nftables.service.d/'
cp "${DIR_SETUP}/files/packet_filter/service_override.conf" '/etc/systemd/system/nftables.service.d/override.conf'
chown "$USER" '/etc/systemd/system/nftables.service.d/override.conf'

cp "${DIR_SETUP}/files/packet_filter/main.conf" '/etc/nftables.conf'
wget -4 "${REPO_CTRL}/templates/packet_filter/nftables_box_base.j2" -O '/tmp/nftables_managed.j2'

insert_nftables_block 'input'
insert_nftables_block 'prerouting_dnat'

grep -v "{% " < '/tmp/nftables_managed.j2' > '/etc/nftables.d/managed.conf'
sed -i "s/IP4_CONTROLLER = { 127.0.0.1 }/IP4_CONTROLLER = { ${CONTROLLER_IP }/g" '/etc/nftables.d/managed.conf'

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
cp "${DIR_SETUP}/files/log/rsyslog.conf" '/etc/rsyslog.d/shieldwall.conf'
cp "${DIR_SETUP}/files/log/logrotate" '/etc/logrotate.d/shieldwall'

# NOTE: logrotate config must be owned by root and not writable by group
chown "$USER" /etc/rsyslog.d/*shieldwall*

touch "${DIR_CACHE}/netflow_data.flowlog"

new_service 'rsyslog'
systemctl restart logrotate.service

log 'NETFLOW CONFIG'

NETFLOW_USER='netflow'

if ! [ -f '/usr/local/bin/goflow2' ]
then
  # NOTE: repo has non-standard naming scheme for binaries..
  download_latest_github_release_filter_arch 'netsampler' 'goflow2' '/tmp/goflow2' '' '$%&' "$CPU_ARCH_RAW"
  mv '/tmp/goflow2' '/usr/local/bin/goflow2'
  chown "$USER" '/usr/local/bin/goflow2'
  chmod +x '/usr/local/bin/goflow2'
fi

if ! grep -q "$NETFLOW_USER" < '/etc/passwd'
then
  useradd "$NETFLOW_USER" --shell '/usr/sbin/nologin' --uid "$USER_ID_NETFLOW"
  usermod -a -G "$USER" "$NETFLOW_USER"
fi

chown "$USER":"$USER" "${DIR_CACHE}/netflow_data.flowlog"
chmod 660 "${DIR_CACHE}/netflow_data.flowlog"
cp "${DIR_SETUP}/files/netflow/shieldwall_netflow.service" '/etc/systemd/system/shieldwall_netflow.service'
chown "$USER" '/etc/systemd/system/shieldwall_netflow.service'
new_service 'shieldwall_netflow'

cp "${DIR_SETUP}/files/netflow/softflowd.conf" '/etc/softflowd/shieldwall.conf'
chown "$USER" '/etc/softflowd/shieldwall.conf'
new_service 'softflowd@shieldwall'

log 'METRIC CONFIG (PROMETHEUS)'

PROM_USER='prometheus_exporter'

if ! grep -q "$PROM_USER" < '/etc/passwd'
then
  useradd "$PROM_USER" --shell '/usr/sbin/nologin' --uid "$USER_ID_PROM"
  usermod -a -G 'ssl-cert' "$PROM_USER"
fi

if ! [ -f '/usr/local/bin/prometheus_node_exporter' ]
then
  download_latest_github_release 'prometheus' 'node_exporter' '/tmp/node_exporter.tar.gz'
  tar -xzf '/tmp/node_exporter.tar.gz' -C '/tmp/' --strip-components=1
  mv '/tmp/node_exporter' '/usr/local/bin/prometheus_node_exporter'
fi

if ! [ -f '/usr/local/bin/prometheus_proxy_client' ]
then
  download_latest_github_release_filter 'shield-wall-net' 'Prometheus-Proxy' '/tmp/prometheus_proxy.tar.gz' 'client' '$%&'
  tar -xzf '/tmp/prometheus_proxy.tar.gz' -C '/tmp/'
  mv "/tmp/prometheus-proxy-client-linux-${CPU_ARCH}-CGO0" '/usr/local/bin/prometheus_proxy_client'
fi

cp "${DIR_SETUP}/files/metrics/prometheus_exporter.sh" '/usr/local/bin/prometheus_exporter.sh'
cp "${DIR_SETUP}/files/metrics/shieldwall_metrics.service" '/etc/systemd/system/shieldwall_metrics.service'
cp "${DIR_SETUP}/files/metrics/prometheus_node_exporter.yml" '/etc/prometheus_node_exporter.yml'
chown "$USER" '/usr/local/bin/prometheus_node_exporter' '/usr/local/bin/prometheus_proxy_client' '/usr/local/bin/prometheus_exporter.sh' '/etc/systemd/system/shieldwall_metrics.service' '/etc/prometheus_node_exporter.yml'

new_service 'shieldwall_metrics'

echo '#########################################'
log 'SETUP FINISHED! Please reboot the system!'

exit 0
