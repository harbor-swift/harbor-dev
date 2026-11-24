#!/usr/bin/env bash
# Walks the whole flow through the gateway: register, read the verification email from the log, verify,
# sign in, read the user, refresh, and show that a reused refresh token ends the session.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
api="http://localhost:8080/v1"
email="ada.$(date +%s)@example.com"
worker_log="$here/.local/logs/auth-worker.log"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "Register $email"
curl -sS -X POST "$api/account" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: $(uuidgen)" \
  -d "{\"email\": \"$email\", \"password\": \"correct horse battery\", \"displayName\": \"Ada Lovelace\"}"
echo

step "Read the verification token from the fake email provider's log"
token=""
for _ in $(seq 1 30); do
  token="$(grep -A6 "To: Ada Lovelace <$email>" "$worker_log" | sed -n 's/.*verify-email: \(.*\)$/\1/p' | tail -1 || true)"
  [[ -n "$token" ]] && break
  sleep 1
done
[[ -n "$token" ]] || { echo "No verification email was logged" >&2; exit 1; }
echo "token: $token"

step "Sign in before verifying (refused)"
curl -sS -X POST "$api/account/sign-in" -H 'Content-Type: application/json' \
  -d "{\"email\": \"$email\", \"password\": \"correct horse battery\"}"
echo

step "Verify the address"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -X POST "$api/account/verify-email" \
  -H 'Content-Type: application/json' -d "{\"token\": \"$token\"}"

step "Sign in"
session="$(curl -sS -X POST "$api/account/sign-in" -H 'Content-Type: application/json' \
  -d "{\"email\": \"$email\", \"password\": \"correct horse battery\"}")"
echo "$session"
access_token="$(echo "$session" | sed -n 's/.*"accessToken" *: *"\([^"]*\)".*/\1/p')"
refresh_token="$(echo "$session" | sed -n 's/.*"refreshToken" *: *"\([^"]*\)".*/\1/p')"

step "Read the user (created by the registration workflow once the address was verified)"
user_file="$(mktemp)"
for _ in $(seq 1 20); do
  status="$(curl -sS -o "$user_file" -w '%{http_code}' "$api/users/me" \
    -H "Authorization: Bearer $access_token")"
  [[ "$status" == "200" ]] && break
  sleep 0.5
done
cat "$user_file"
rm -f "$user_file"
echo
[[ "$status" == "200" ]] || { echo "The user was not created" >&2; exit 1; }

step "Read the user without a token (refused)"
curl -sS "$api/users/me"
echo

step "Refresh the session"
curl -sS -X POST "$api/account/refresh" -H 'Content-Type: application/json' \
  -d "{\"refreshToken\": \"$refresh_token\"}"
echo

step "Present the used refresh token again (refused, and the session ends)"
curl -sS -X POST "$api/account/refresh" -H 'Content-Type: application/json' \
  -d "{\"refreshToken\": \"$refresh_token\"}"
echo

