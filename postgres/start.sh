#!/usr/bin/env bash
# Runs inside a service's Postgres container: copies the server's pair, named by HARBOR_TLS_IDENTITY, where
# Postgres accepts its key's ownership, then starts Postgres with TLS on and password logins over TLS only.
set -euo pipefail
tls=/var/lib/postgresql/tls
mkdir -p "$tls"
cp "/harbor/certs/$HARBOR_TLS_IDENTITY/cert.pem" "/harbor/certs/$HARBOR_TLS_IDENTITY/key.pem" "$tls/"
cp /harbor/postgres/conf/pg_hba.conf "$tls/"
chown -R postgres:postgres "$tls"
chmod 600 "$tls/key.pem"
exec docker-entrypoint.sh postgres \
  -c ssl=on \
  -c ssl_cert_file="$tls/cert.pem" \
  -c ssl_key_file="$tls/key.pem" \
  -c password_encryption=scram-sha-256 \
  -c hba_file="$tls/pg_hba.conf"
