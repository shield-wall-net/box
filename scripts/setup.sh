#!/usr/bin/env bash

set -euo pipefail

if [[ "$(id -u)" != '0' ]]
then
  echo "ERROR: Script needs to be ran as root!"
  exit 1
fi

# shellcheck disable=SC2009
if ! ps 1 | grep -q 'systemd'
then
  echo "ERROR: ShieldWall depends on Systemd! Init process is other!"
  exit 1
fi

function log() {
  echo ''
  echo "### $1 ###"
  echo ''
}

VERSION="latest"
CTRL_VERSION="latest"
REPO_BOX="https://raw.githubusercontent.com/shield-wall-net/box/${VERSION}"
REPO_CTRL="https://raw.githubusercontent.com/shield-wall-net/controller/${CTRL_VERSION}"

USER="shieldwall"
DIR_HOME="/home/shieldwall"
DIR_LIB="/var/local/lib/shieldwall"

log "INSTALLING DEPENDENCIES & UTILS"
apt -y install openssl python3 wget gpg lsb-release uname apt-transport-https ca-certificates gnupg curl

log "INSTALLING FIREWALL"
apt -y install nftables
apt -y remove ufw

log "INSTALLING SYSLOG"
apt -y install rsyslog rsyslog-gnutls logrotate

DISTRO=$(lsb_release -i -s | tr '[:upper:]' '[:lower:]')
CODENAME=$(lsb_release -c -s | tr '[:upper:]' '[:lower:]')
DOCKER_GPG='/usr/share/keyrings/docker-archive-keyring.gpg'
CPU_ARCH=$(uname -i)

if [[ "$CPU_ARCH" == 'unknown' ]] || [[ "$CPU_ARCH" == 'x86_64' ]]
then
  CPU_ARCH='amd64'
fi

useradd "$USER" --shell /bin/bash --home-dir "$DIR_HOME" --create-home
chmod 0750 "$DIR_HOME"

mkdir -p "$DIR_LIB"
chown "$USER":"$USER" "$DIR_LIB"
chmod 0750 "$DIR_LIB"

log "INSTALLING DOCKER (to run dockerized packages)"
wget "https://download.docker.com/linux/${DISTRO}/gpg" -O "${DOCKER_GPG}_armored"
gpg --dearmor < "${DOCKER_GPG}_armored" > "$DOCKER_GPG"

docker_repo="deb [arch=${CPU_ARCH} signed-by=${DOCKER_GPG}] https://download.docker.com/linux/${DISTRO} ${CODENAME} stable"
echo "$docker_repo" > '/etc/apt/sources.list.d/docker.list'

apt update
apt -y install docker-ce containerd.io

mkdir -p /etc/systemd/system/docker.service.d/
wget "${REPO_BOX}/files/docker.override.conf" -O /etc/systemd/system/docker.service.d/override.conf

systemctl daemon-reload
systemctl enable docker.service
systemctl start docker.service

log "ADDING FIREWALL BASE CONFIG"
modprobe nft_ct
modprobe nft_log
modprobe nft_nat
modprobe nft_redir
modprobe nft_limit
modprobe nft_quota
modprobe nft_connlimit
modprobe nft_reject

mkdir -p /etc/nftables.d/ /etc/systemd/system/nftables.service.d/
wget "${REPO_BOX}/files/nftables/override.conf" -O /etc/systemd/system/nftables.service.d/override.conf
wget "${REPO_BOX}/files/nftables/main.conf" -O /etc/nftables.conf
wget "${REPO_CTRL}/templates/firewall/nftables_box_base.j2" -O /tmp/nftables_managed.j2
grep -v "{% block" < /tmp/nftables_managed.j2 > /etc/nftables.d/managed.conf
chmod 750 /etc/nftables.d/
chmod 640 /etc/nftables.conf /etc/nftables.d/managed.conf
chown -R "$USER":"$USER" /etc/nftables*

systemctl daemon-reload
systemctl enable nftables.service
systemctl start nftables.service
systemctl reload nftables.service
