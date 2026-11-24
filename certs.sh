#!/usr/bin/env bash
# Makes everything a local run mounts, as production's deployment would: a development certificate authority
# and a certificate pair per identity, the Ed25519 key pair that signs and verifies access tokens, and each
# Postgres role's password.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
local_dir="$here/.local"
out="$local_dir/certs"
mkdir -p "$out"

if [[ ! -f "$out/ca.pem" ]]; then
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/ca-key.pem"
  openssl req -x509 -new -key "$out/ca-key.pem" -sha256 -days 825 \
    -subj "/CN=Harbor Development CA" -out "$out/ca.pem"
fi

# identity: the DNS name the certificate carries beside localhost, which InternalCallerInterceptor admits.
issue() {
  local identity="$1"
  local dir="$out/$identity"
  [[ -f "$dir/cert.pem" ]] && return
  mkdir -p "$dir"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/key.pem"
  openssl req -new -key "$dir/key.pem" -subj "/CN=$identity" -out "$dir/csr.pem"
  cat > "$dir/ext.cnf" <<EXT
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:$identity, DNS:localhost, IP:127.0.0.1
EXT
  openssl x509 -req -in "$dir/csr.pem" -CA "$out/ca.pem" -CAkey "$out/ca-key.pem" -CAcreateserial \
    -days 397 -sha256 -extfile "$dir/ext.cnf" -out "$dir/cert.pem"
  rm "$dir/csr.pem" "$dir/ext.cnf"
  chmod 600 "$dir/key.pem"
}

# The processes, each service's Postgres, and Temporal's frontend and UI.
for identity in auth auth-worker users gateway auth-postgres users-postgres temporal temporal-ui; do
  issue "$identity"
done

# The access tokens' Ed25519 key pair: Auth mounts the private key, every verifier the public key file.
jwt="$local_dir/jwt"
if [[ ! -f "$jwt/private.pem" ]]; then
  mkdir -p "$jwt"
  openssl genpkey -algorithm ed25519 -out "$jwt/private.pem"
  openssl pkey -in "$jwt/private.pem" -pubout -out "$jwt/public.pem"
  chmod 600 "$jwt/private.pem"
fi

# password <service> <role>: a random password, one file per Postgres role.
password() {
  local file="$local_dir/secrets/$1/postgres-$2-password"
  [[ -f "$file" ]] && return
  mkdir -p "$(dirname "$file")"
  openssl rand -hex 24 > "$file"
  chmod 600 "$file"
}
password auth owner
password auth service
password users owner
password users service
password users internal
password temporal store

echo "Certificates in $out, token keys in $jwt, passwords in $local_dir/secrets"
