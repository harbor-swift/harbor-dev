#!/usr/bin/env bash
# Stops the processes up.sh started and removes the Postgres and Temporal containers, with their data.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
for pid_file in "$here/.local/pids/"*.pid; do
  [[ -f "$pid_file" ]] || continue
  kill "$(cat "$pid_file")" 2>/dev/null
  rm -f "$pid_file"
done
container rm -f harbor-temporal-ui harbor-temporal harbor-temporal-postgres \
  harbor-auth-postgres harbor-users-postgres >/dev/null 2>&1
container network delete harbor >/dev/null 2>&1
echo "Harbor is down."
