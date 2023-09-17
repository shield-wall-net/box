#!/usr/bin/env bash
# ShieldWall managed

set -euo pipefail

SHIELDWALL_USER='shieldwall'
SQUID_DIR_CONF='/etc/squid'
SQUID_DIR_CACHE='/var/spool/squid'
SQUID_DIR_LOG=/'var/log/shieldwall'
SQUID_DIR_LIB='/var/lib/squid'
SQUID_USER='proxy'
SQUID_DH_SIZE=2048
SQUID_CERT_CN='/C=AT/O=shield-wall.net/CN=ShieldWall Forward Proxy'

SQUID_DIR_CERT='/etc/ssl/certs'
SQUID_DIR_KEY='/etc/ssl/private'
SQUID_DIR_SSLDB="${SQUID_DIR_LIB}/ssl_db"
SQUID_CONFIG="${SQUID_DIR_CONF}/squid.conf"

create_dir() {
  directory="$1"
  if ! [ -d "$directory" ]
  then
    mkdir -p "$directory"
  fi
  chown -R "$SQUID_USER":"$SQUID_USER" "$directory"
  chmod 750 "$directory"
}

set_cert_privileges() {
  chown "$SHIELDWALL_USER":"$SQUID_USER" "$1"
  chmod 640 "$1"
}

create_missing_certs() {
  if ! [ -f "${SQUID_DIR_CERT}/proxy.crt" ]
  then
    echo ''
    echo '### CREATING CERTIFICATES ###'
    openssl req -x509 -newkey rsa:4096 -keyout "${SQUID_DIR_KEY}/proxy.key" -out "${SQUID_DIR_CERT}/proxy.crt" -sha256 -days 3650 -nodes -subj "$SQUID_CERT_CN"
  fi
  if ! [ -f "${SQUID_DIR_KEY}/proxy.dh.pem" ]
  then
    echo ''
    echo '### CREATING DH ###'
    openssl dhparam -outform PEM -out "${SQUID_DIR_KEY}/proxy.dh.pem" "$SQUID_DH_SIZE"
  fi

  set_cert_privileges "${SQUID_DIR_CERT}/proxy.crt"
  set_cert_privileges "${SQUID_DIR_KEY}/proxy.key"
  set_cert_privileges "${SQUID_DIR_KEY}/proxy.dh.pem"
}

recreate_ssldb() {
  echo ''
  echo '### RE-CREATING SSL-DB ###'
  rm -rf "$SQUID_DIR_SSLDB"

  SQUID_SSLDB_SIZE=$(grep 'sslproxy_session_cache_size' < "$SQUID_CONFIG" | cut -d ' ' -f 2)
  /usr/lib/squid/security_file_certgen -c -s "$SQUID_DIR_SSLDB" -M "$SQUID_SSLDB_SIZE"
  chown -R "$SQUID_USER":"$SQUID_USER" "${SQUID_DIR_SSLDB}"
  chmod 750 "$SQUID_DIR_SSLDB"
}

create_missing_logfile() {
  logfile="${SQUID_DIR_LOG}/$1"
  if ! [ -f "$logfile" ]
  then
    touch "$logfile"
  fi
  chown "$SHIELDWALL_USER":"$SQUID_USER" "$logfile"
  chmod 660 "$logfile"
}

create_dir "$SQUID_DIR_CACHE"
create_dir "$SQUID_DIR_LIB"
create_missing_certs
# create_missing_logfile 'squid_access.log'
create_missing_logfile 'squid_cache.log'
create_missing_logfile 'squid_store.log'
recreate_ssldb

exit 0
