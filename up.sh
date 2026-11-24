#!/usr/bin/env bash
# Starts the whole system on this machine: each service's Postgres, Temporal with its own store and its UI, in
# Apple `container`, then the migrations, then auth, its worker, users and the gateway as native processes.
# Logs go to harbor-dev/.local/logs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
export LOCAL="$here/.local"
mkdir -p "$LOCAL/logs" "$LOCAL/pids"

"$here/certs.sh" >/dev/null

echo "==> Building"
for package in harbor-auth harbor-users harbor-gateway; do
  (cd "$root/$package" && swift build --quiet)
done

container system start >/dev/null 2>&1 || true
network=harbor
container network inspect "$network" >/dev/null 2>&1 || container network create "$network" >/dev/null

exists() { container ls --all | awk '{ print $1 }' | grep -qx "$1"; }
ip_of() { container ls | awk -v name="$1" '$1 == name { print $6 }' | cut -d/ -f1; }

wait_for() {
  local description="$1" attempts="$2"
  shift 2
  for _ in $(seq 1 "$attempts"); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for $description" >&2
  exit 1
}

echo "==> Starting each service's Postgres 18"
# postgres <service> <host port> <database> <owner>
postgres() {
  local service="$1" port="$2" database="$3" owner="$4" name="harbor-$1-postgres"
  if ! exists "$name"; then
    container run -d --name "$name" --network "$network" -p "127.0.0.1:$port:5432" \
      -e POSTGRES_PASSWORD="$(openssl rand -hex 24)" \
      -e HARBOR_DATABASE="$database" -e HARBOR_OWNER="$owner" -e HARBOR_TLS_IDENTITY="$service-postgres" \
      -v "$here/postgres/initdb:/docker-entrypoint-initdb.d" \
      -v "$here/postgres:/harbor/postgres" \
      -v "$LOCAL/certs:/harbor/certs" \
      -v "$LOCAL/secrets/$service:/harbor/secrets" \
      --entrypoint /bin/bash \
      docker.io/library/postgres:18-alpine /harbor/postgres/start.sh >/dev/null
  fi
}
postgres auth 5432 harbor_auth auth_owner
postgres users 5433 harbor_users users_owner

echo "==> Starting Temporal over mutual TLS, with its own store and its UI"
if ! exists harbor-temporal-postgres; then
  container run -d --name harbor-temporal-postgres --network "$network" \
    -e POSTGRES_PASSWORD="$(cat "$LOCAL/secrets/temporal/postgres-store-password")" \
    docker.io/library/postgres:18-alpine >/dev/null
fi
wait_for "Temporal's store" 60 container exec harbor-temporal-postgres pg_isready -U postgres -h localhost
sleep 2
wait_for "Temporal's store" 60 container exec harbor-temporal-postgres pg_isready -U postgres -h localhost
if ! exists harbor-temporal; then
  tls=/harbor/certs/temporal
  container run -d --name harbor-temporal --network "$network" -p 127.0.0.1:7233:7233 \
    -e DB=postgres12 -e DB_PORT=5432 -e POSTGRES_SEEDS="$(ip_of harbor-temporal-postgres)" \
    -e POSTGRES_USER=postgres -e POSTGRES_PWD="$(cat "$LOCAL/secrets/temporal/postgres-store-password")" \
    -e DEFAULT_NAMESPACE=harbor-auth \
    -e BIND_ON_IP=0.0.0.0 -e TEMPORAL_BROADCAST_ADDRESS=127.0.0.1 \
    -e TEMPORAL_TLS_REQUIRE_CLIENT_AUTH=true \
    -e TEMPORAL_TLS_FRONTEND_CERT="$tls/cert.pem" -e TEMPORAL_TLS_FRONTEND_KEY="$tls/key.pem" \
    -e TEMPORAL_TLS_SERVER_CERT="$tls/cert.pem" -e TEMPORAL_TLS_SERVER_KEY="$tls/key.pem" \
    -e TEMPORAL_TLS_SERVER_CA_CERT=/harbor/certs/ca.pem -e TEMPORAL_TLS_CLIENT1_CA_CERT=/harbor/certs/ca.pem \
    -e TEMPORAL_TLS_FRONTEND_SERVER_NAME=localhost -e TEMPORAL_TLS_INTERNODE_SERVER_NAME=localhost \
    -e TEMPORAL_ADDRESS=127.0.0.1:7233 -e TEMPORAL_CLI_ADDRESS=127.0.0.1:7233 \
    -e TEMPORAL_TLS_CA=/harbor/certs/ca.pem -e TEMPORAL_TLS_CERT="$tls/cert.pem" -e TEMPORAL_TLS_KEY="$tls/key.pem" \
    -e TEMPORAL_TLS_SERVER_NAME=localhost \
    -e TEMPORAL_CLI_TLS_CA=/harbor/certs/ca.pem -e TEMPORAL_CLI_TLS_CERT="$tls/cert.pem" \
    -e TEMPORAL_CLI_TLS_KEY="$tls/key.pem" -e TEMPORAL_CLI_TLS_SERVER_NAME=localhost \
    -v "$LOCAL/certs:/harbor/certs" \
    docker.io/temporalio/auto-setup:1.29.7 >/dev/null
fi
wait_for "Temporal's harbor-auth namespace" 240 \
  container exec harbor-temporal temporal operator namespace describe --namespace harbor-auth
if ! exists harbor-temporal-ui; then
  tls=/harbor/certs/temporal-ui
  container run -d --name harbor-temporal-ui --network "$network" -p 127.0.0.1:8233:8080 \
    -e TEMPORAL_ADDRESS="$(ip_of harbor-temporal):7233" -e TEMPORAL_DEFAULT_NAMESPACE=harbor-auth \
    -e TEMPORAL_TLS_CA=/harbor/certs/ca.pem -e TEMPORAL_TLS_CERT="$tls/cert.pem" -e TEMPORAL_TLS_KEY="$tls/key.pem" \
    -e TEMPORAL_TLS_SERVER_NAME=localhost -e TEMPORAL_TLS_ENABLE_HOST_VERIFICATION=true \
    -e TEMPORAL_CSRF_COOKIE_INSECURE=true \
    -v "$LOCAL/certs:/harbor/certs" \
    docker.io/temporalio/ui:2.58.1 >/dev/null
fi

# Each Postgres restarts once after its init scripts; wait for the final server.
for name in harbor-auth-postgres harbor-users-postgres; do
  wait_for "$name" 60 container exec "$name" pg_isready -U postgres -h localhost
  sleep 2
  wait_for "$name" 60 container exec "$name" pg_isready -U postgres -h localhost
done

run_env() {
  # shellcheck disable=SC1090
  (source "$here/env/common.env"; for file in "${@:2}"; do source "$here/env/$file.env"; done; eval "$1")
}

echo "==> Migrating"
run_env "'$root/harbor-auth/.build/debug/auth' migrate" auth-migrator
run_env "'$root/harbor-users/.build/debug/users' migrate" users-migrator

start() {
  local name="$1" command="$2"
  shift 2
  if [[ -f "$LOCAL/pids/$name.pid" ]] && kill -0 "$(cat "$LOCAL/pids/$name.pid")" 2>/dev/null; then
    return
  fi
  run_env "nohup $command > '$LOCAL/logs/$name.log' 2>&1 & echo \$! > '$LOCAL/pids/$name.pid'" "$@"
}

echo "==> Starting services"
start auth "'$root/harbor-auth/.build/debug/auth' serve" auth
wait_for "auth" 60 nc -z localhost 50051
start users "'$root/harbor-users/.build/debug/users' serve" users
wait_for "users" 60 nc -z localhost 50052
start auth-worker "'$root/harbor-auth/.build/debug/auth' worker run" auth-worker
start gateway "'$root/harbor-gateway/.build/debug/gateway' serve" gateway
wait_for "gateway" 60 curl -fsS http://localhost:8080/health

echo
echo "Harbor is up:"
echo "  API          http://localhost:8080/v1   (try harbor-dev/demo.sh)"
echo "  Temporal UI  http://localhost:8233"
echo "  Logs         $LOCAL/logs   (the fake email provider writes to auth-worker.log)"
