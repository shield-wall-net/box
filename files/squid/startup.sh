#!/usr/bin/env bash

set -euo pipefail

SQUID_DIR_CONF='/etc/squid'
SQUID_DIR_CACHE='/var/spool/squid'
SQUID_DIR_LOG=/'var/log/squid'
SQUID_DIR_LIB='/var/lib/squid'
SQUID_USER='proxy'
SQUID_DH_SIZE=2048
SQUID_CERT_CN='/C=AT/O=shield-wall.net/CN=ShieldWall Forward Proxy'

SQUID_DIR_SSL="${SQUID_DIR_LIB}/ssl"
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
  chown 'root':"$SQUID_USER" "${SQUID_DIR_SSL}/$1"
  chmod 640 "${SQUID_DIR_SSL}/$1"
}

create_missing_certs() {
  if ! [ -f "${SQUID_DIR_SSL}/server.crt" ]
  then
    echo ''
    echo '### CREATING CERTIFICATES ###'
    openssl req -x509 -newkey rsa:4096 -keyout "${SQUID_DIR_SSL}/server.key" -out "${SQUID_DIR_SSL}/server.crt" -sha256 -days 3650 -nodes -subj "$SQUID_CERT_CN"
  fi
  if ! [ -f "${SQUID_DIR_SSL}/server.dh.pem" ]
  then
    echo ''
    echo '### CREATING DH ###'
    openssl dhparam -outform PEM -out "${SQUID_DIR_SSL}/server.dh.pem" "$SQUID_DH_SIZE"
  fi

  set_cert_privileges 'server.crt'
  set_cert_privileges 'server.key'
  set_cert_privileges 'server.dh.pem'
}

recreate_ssldb() {
  echo ''
  echo '### CREATING SSL-DB ###'
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
    chown "$SQUID_USER":"$SQUID_USER" "$logfile"
    chmod 640 "$logfile"
  fi
}

create_trusted_ca_file() {
  touch "${SQUID_DIR_SSL}/trusted_cas.crt"
  set_cert_privileges 'trusted_cas.crt'
}

create_dir "$SQUID_DIR_LOG"
create_dir "$SQUID_DIR_CACHE"
create_dir "$SQUID_DIR_SSL"
create_dir "$SQUID_DIR_LIB"
create_missing_certs
create_missing_logfile 'access.log'
create_missing_logfile 'cache.log'
create_missing_logfile 'store.log'
create_trusted_ca_file
recreate_ssldb

exit 0
