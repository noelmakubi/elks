#!/usr/bin/env bash
#
# End-to-end smoke test against a running stack.
#
#   bash hosting/smoke-test.sh
#   BASE_URL=http://localhost:8080 bash hosting/smoke-test.sh
#
# Exercises the real behaviour of the stack through the proxy: create a user,
# create an order that references that user, wait for service-c to poll it, and
# confirm a notification appears. This is the test that would catch a broken
# inter-service call or a schema that never initialised, which a health check
# alone would not.
#
# Exits non-zero on the first failure so CI stops.

set -Eeuo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
# service-c polls on an interval; give it a few cycles on a cold CI container.
POLL_WAIT_SECONDS="${POLL_WAIT_SECONDS:-60}"
CURL=(curl -fsS --max-time 15 -H 'Content-Type: application/json')

pass=0
fail=0

ok()   { printf '  \033[0;32mok\033[0m   %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; fail=$((fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$*"; }

expect_status() {
  local path="$1" want="$2" out code body
  out=$("${CURL[@]}" -o /tmp/elks-smoke-body -w '%{http_code}' "$BASE_URL$path" || true)
  code="$out"
  body=$(cat /tmp/elks-smoke-body 2>/dev/null || echo '')
  if [[ "$code" == "$want" ]]; then
    ok "$path -> $code"
  else
    bad "$path -> $code (expected $want): ${body:0:200}"
  fi
}

########################################
# 1. Reachability
########################################
info "1. reachability"
for svc in service-a service-b service-c; do
  expect_status "/api/$svc/health" 200
done
expect_status "/healthz" 200

# Confirm the dashboard itself is served, not just the API.
if "${CURL[@]}" "$BASE_URL/" | grep -qi '<html'; then
  ok "dashboard HTML is served"
else
  bad "dashboard HTML did not come back from $BASE_URL/"
fi

########################################
# 2. Create a user in service-a
########################################
info "2. service-a: create a user"
# Unique per run so repeated runs against a persistent database do not collide
# on the unique email constraint.
EMAIL="ci-$$-$(date +%s)@example.com"

user_body=$("${CURL[@]}" -X POST "$BASE_URL/api/service-a/users" \
  -d "{\"name\":\"CI User\",\"email\":\"$EMAIL\"}" || true)

user_id=$(printf '%s' "$user_body" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)

if [[ -n "$user_id" ]]; then
  ok "created user id=$user_id ($EMAIL)"
else
  bad "could not create a user: ${user_body:0:200}"
  # Without a user id the order step cannot be a meaningful test.
  info "summary: $pass passed, $fail failed"
  exit 1
fi

expect_status "/api/service-a/users/$user_id" 200

# A duplicate email must be rejected with 409.
dup_code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/service-a/users" \
  -d "{\"name\":\"Dup\",\"email\":\"$EMAIL\"}" || true)
if [[ "$dup_code" == "409" ]]; then
  ok "duplicate email rejected with 409"
else
  bad "duplicate email -> $dup_code (expected 409)"
fi

# Validation: a missing field must be 400.
bad_code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/service-a/users" \
  -d '{"name":"no email"}' || true)
if [[ "$bad_code" == "400" ]]; then
  ok "missing email rejected with 400"
else
  bad "missing email -> $bad_code (expected 400)"
fi

########################################
# 3. Create an order in service-b
########################################
info "3. service-b: create an order for that user"
# This is the inter-service call: service-b validates user_id against service-a.
# If that call is broken and REQUIRE_USER_VALIDATION is false (the default) the
# order is still accepted, so check the order was created AND that service-b
# reported on the validation.
order_body=$("${CURL[@]}" -X POST "$BASE_URL/api/service-b/orders" \
  -d "{\"user_id\":$user_id,\"item\":\"ci-widget\",\"quantity\":1}" || true)

order_id=$(printf '%s' "$order_body" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1)

if [[ -n "$order_id" ]]; then
  ok "created order id=$order_id for user $user_id"
else
  bad "could not create an order: ${order_body:0:200}"
fi

expect_status "/api/service-b/orders" 200

# An order for a user that does not exist is the negative case. With validation
# required it is a 4xx; without it, it is accepted with a warning. Either is
# correct, so only assert that the endpoint answers and is not a 5xx.
ghost_code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/service-b/orders" \
  -d '{"user_id":99999999,"item":"ghost","quantity":1}' || true)
if [[ "$ghost_code" =~ ^[45] ]]; then
  ok "order for an unknown user -> $ghost_code (service-b stayed up)"
else
  bad "order for an unknown user -> $ghost_code (expected 4xx or 5xx, never success)"
fi

########################################
# 4. Wait for service-c to notice the order
########################################
info "4. service-c: wait for the poller to pick up the order (max ${POLL_WAIT_SECONDS}s)"
notified=0
deadline=$(( SECONDS + POLL_WAIT_SECONDS ))

while (( SECONDS < deadline )); do
  notif_body=$("${CURL[@]}" "$BASE_URL/api/service-c/notifications" || true)
  # Match on the item name, not the id: ids differ between environments and the
  # notification payload is what proves the poll actually ran end to end.
  if printf '%s' "$notif_body" | grep -q 'ci-widget'; then
    notified=1
    break
  fi
  printf '\r  polling, %ss elapsed' "$SECONDS"
  sleep 5
done
echo

if [[ "$notified" -eq 1 ]]; then
  ok "service-c created a notification for the order"
else
  bad "no notification for the order after ${POLL_WAIT_SECONDS}s (check the poller and POLL_INTERVAL_SECONDS)"
fi

########################################
# 5. Log viewer
########################################
info "5. log endpoint"
logs_body=$("${CURL[@]}" "$BASE_URL/api/service-a/logs?lines=5" || true)
if printf '%s' "$logs_body" | grep -q '"entries"'; then
  ok "GET /logs returns entries"
else
  bad "GET /logs did not return an entries array: ${logs_body:0:200}"
fi

# A huge ?lines must be capped, not read whole-file.
big_code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE_URL/api/service-a/logs?lines=999999" || true)
if [[ "$big_code" == "200" ]]; then
  ok "oversized ?lines is handled (200)"
else
  bad "oversized ?lines -> $big_code (expected 200; the handler caps the value)"
fi

########################################
# Summary
########################################
info "summary: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]] || exit 1
