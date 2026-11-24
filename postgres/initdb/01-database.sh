#!/usr/bin/env bash
# What the deployment provides before a service first deploys: the service's database and its owner, who may
# create the service's other roles in its migrations. HARBOR_DATABASE and HARBOR_OWNER name them; the owner's
# password is the mounted secret.
set -euo pipefail
owner_password="$(head -n 1 /harbor/secrets/postgres-owner-password)"
psql -v ON_ERROR_STOP=1 -U postgres \
  -v owner="$HARBOR_OWNER" -v database="$HARBOR_DATABASE" -v owner_password="$owner_password" <<'SQL'
CREATE ROLE :"owner" LOGIN CREATEROLE PASSWORD :'owner_password';
CREATE DATABASE :"database" OWNER :"owner";
SQL
