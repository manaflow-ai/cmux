#!/usr/bin/env bash
set -euo pipefail

# End-to-end tests for cmux-proxy using Docker and LD_PRELOAD isolation.
# - Builds the runtime image
# - Starts proxy container publishing :39379
# - Inside the container, starts HTTP servers bound by workspace via LD_PRELOAD
# - Verifies isolation from inside the container
# - Verifies proxy from host via headers and subdomain Host routing

PORT="${PORT:-39379}"
IMAGE="${IMAGE:-cmux-proxy-e2e:latest}"
CONTAINER="${CONTAINER:-cmux-proxy-e2e}"

WS_A="workspace-a"
WS_B="workspace-b"

red() { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { red "Missing required command: $1"; exit 1; }
}

require_cmd docker
require_cmd curl

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "[1/8] Building runtime image: $IMAGE"
docker build --target runtime -t "$IMAGE" .

echo "[2/8] Starting proxy container: $CONTAINER (publishing :$PORT)"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --rm \
  -p "$PORT:39379" \
  --name "$CONTAINER" \
  "$IMAGE" >/dev/null

echo "[3/8] Waiting for proxy to listen on :$PORT"
for i in $(seq 1 50); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/" || true)
  # No header -> expect 400 once proxy is up
  if [ "$code" = "400" ]; then break; fi
  sleep 0.1
done
code=$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/" || true)
if [ "$code" != "400" ]; then
  red "Proxy did not start (expected HTTP 400 without headers). Got: $code"
  exit 1
fi
green "Proxy is up."

echo "[4/8] Prepare workspaces and start server in $WS_A on port 3000"
docker exec "$CONTAINER" bash -lc "mkdir -p /root/$WS_A /root/$WS_B"
docker exec "$CONTAINER" bash -lc "cd /root/$WS_A && echo ok-A > index.html && nohup python3 -m http.server 3000 --bind 127.0.0.1 >/tmp/a.log 2>&1 & echo \$! > /tmp/a.pid"

echo "Waiting for A:3000 inside container"
for i in $(seq 1 50); do
  if docker exec "$CONTAINER" bash -lc "cd /root/$WS_A && curl -sS --fail http://127.0.0.1:3000 >/dev/null"; then
    break
  fi
  sleep 0.1
done
docker exec "$CONTAINER" bash -lc "cd /root/$WS_A && curl -sS --fail http://127.0.0.1:3000 | grep -q '^ok-A$'"
green "A:3000 is serving index.html"

echo "[5/8] Verify isolation inside container (B cannot reach A's 3000)"
set +e
docker exec "$CONTAINER" bash -lc "cd /root/$WS_B && curl -sS -m 2 http://127.0.0.1:3000 >/dev/null"
status=$?
set -e
if [ $status -eq 0 ]; then
  red "Isolation failed: curl from $WS_B to 127.0.0.1:3000 succeeded (should fail)"
  exit 1
fi
green "Isolation inside container OK (B cannot reach A:3000)."

echo "[6/8] Validate proxy from host using headers"
body=$(curl -sS -H "X-Cmux-Workspace-Internal: $WS_A" -H "X-Cmux-Port-Internal: 3000" "http://127.0.0.1:${PORT}/")
test "$body" = "ok-A" || { red "Expected 'ok-A' via headers (A), got: $body"; exit 1; }
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "X-Cmux-Workspace-Internal: $WS_B" -H "X-Cmux-Port-Internal: 3000" "http://127.0.0.1:${PORT}/")
test "$code" = "502" || { red "Expected 502 via headers (B w/o server), got: $code"; exit 1; }
green "Header routing OK (A success, B 502)."

echo "[7/8] Validate proxy from host using subdomain Host header"
body=$(curl -sS -H "Host: ${WS_A}-3000.localhost" "http://127.0.0.1:${PORT}/")
test "$body" = "ok-A" || { red "Expected 'ok-A' via subdomain (A), got: $body"; exit 1; }
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Host: ${WS_B}-3000.localhost" "http://127.0.0.1:${PORT}/")
test "$code" = "502" || { red "Expected 502 via subdomain (B w/o server), got: $code"; exit 1; }
green "Subdomain routing OK (A success, B 502)."

echo "Starting server in $WS_B on port 3000"
docker exec "$CONTAINER" bash -lc "cd /root/$WS_B && echo ok-B > index.html && nohup python3 -m http.server 3000 --bind 127.0.0.1 >/tmp/b.log 2>&1 & echo \$! > /tmp/b.pid"
echo "Waiting for B:3000 inside container"
for i in $(seq 1 50); do
  if docker exec "$CONTAINER" bash -lc "cd /root/$WS_B && curl -sS --fail http://127.0.0.1:3000 >/dev/null"; then
    break
  fi
  sleep 0.1
done

echo "[8/8] Re-validate proxy for B now that server is up"
body=$(curl -sS -H "X-Cmux-Workspace-Internal: $WS_B" -H "X-Cmux-Port-Internal: 3000" "http://127.0.0.1:${PORT}/")
test "$body" = "ok-B" || { red "Expected 'ok-B' via headers (B), got: $body"; exit 1; }
body=$(curl -sS -H "Host: ${WS_B}-3000.localhost" "http://127.0.0.1:${PORT}/")
test "$body" = "ok-B" || { red "Expected 'ok-B' via subdomain (B), got: $body"; exit 1; }

# Additional validations
echo "[9/9] Validate two servers on same port in different workspaces"
docker exec "$CONTAINER" bash -lc "cd /root/$WS_A && curl -sS --fail http://127.0.0.1:3000 | grep -q '^ok-A$'"
docker exec "$CONTAINER" bash -lc "cd /root/$WS_B && curl -sS --fail http://127.0.0.1:3000 | grep -q '^ok-B$'"
green "A:3000 and B:3000 both serve their own content (no conflict)."

echo "[9/9] Validate two servers on same port in the SAME workspace fail"
docker exec "$CONTAINER" bash -lc "mkdir -p /root/workspace-c && echo ok-C > /root/workspace-c/index.html && cd /root/workspace-c && nohup python3 -m http.server 3000 --bind 127.0.0.1 >/tmp/c1.log 2>&1 & echo \$! > /tmp/c1.pid"
for i in $(seq 1 50); do
  if docker exec "$CONTAINER" bash -lc "cd /root/workspace-c && curl -sS --fail http://127.0.0.1:3000 >/dev/null"; then
    break
  fi
  sleep 0.1
done

set +e
out=$(docker exec "$CONTAINER" bash -lc "cd /root/workspace-c && python3 -m http.server 3000 --bind 127.0.0.1" 2>&1)
rc=$?
set -e
if [ $rc -eq 0 ]; then
  red "Second server in same workspace unexpectedly succeeded"
  echo "$out"
  exit 1
fi
echo "$out" | grep -qi "address already in use" || { red "Expected 'address already in use' in error, got:\n$out"; exit 1; }
green "Same-workspace second bind failed with 'address already in use' as expected."

# Stress test: launch many workspaces with same port and validate isolation via proxy
STRESS_N="${STRESS_N:-32}"
STRESS_PORT="${STRESS_PORT:-3200}"
STRESS_CONC="${STRESS_CONC:-16}"
echo "[stress] Launching $STRESS_N servers on port $STRESS_PORT across distinct workspaces (parallel=$STRESS_CONC)"

# Start servers in parallel to reduce exec overhead
seq 1 "$STRESS_N" | xargs -n1 -P "$STRESS_CONC" -I{} \
  docker exec "$CONTAINER" bash -lc \
    "mkdir -p /root/workspace-{} && echo ok-{} > /root/workspace-{}/index.html && cd /root/workspace-{} && nohup python3 -m http.server $STRESS_PORT --bind 127.0.0.1 >/tmp/ws{}.log 2>&1 &"

echo "[stress] Waiting for readiness inside container (parallel=$STRESS_CONC)"
seq 1 "$STRESS_N" | xargs -n1 -P "$STRESS_CONC" -I{} \
  docker exec "$CONTAINER" bash -lc \
    "cd /root/workspace-{} && for t in \$(seq 1 100); do if curl -sS --fail http://127.0.0.1:$STRESS_PORT | grep -q '^ok-{}$'; then exit 0; fi; sleep 0.05; done; echo 'workspace-{} not ready' >&2; exit 1"

green "All $STRESS_N servers inside container are serving distinct content."

# Validate via proxy from host using headers for all workspaces (parallel)
echo "[stress] Verifying header routing for $STRESS_N workspaces via proxy (parallel=$STRESS_CONC)"
seq 1 "$STRESS_N" | xargs -n1 -P "$STRESS_CONC" -I{} bash -lc \
  'body=$(curl -sS -H "X-Cmux-Workspace-Internal: workspace-{}" -H "X-Cmux-Port-Internal: '$STRESS_PORT'" "http://127.0.0.1:'"$PORT"'/"); test "$body" = "ok-{}" || { echo "Header routing mismatch for workspace-{}: $body" >&2; exit 1; }'
green "Header routing verified for $STRESS_N workspaces."

# Spot-check subdomain routing for a few workspaces
for i in 1 "$STRESS_N" 5 10 15; do
  if [ "$i" -gt "$STRESS_N" ]; then continue; fi
  body=$(curl -sS -H "Host: workspace-$i-$STRESS_PORT.localhost" "http://127.0.0.1:${PORT}/")
  if [ "$body" != "ok-$i" ]; then
    red "Subdomain routing mismatch for workspace-$i: expected ok-$i, got: $body"
    exit 1
  fi
done
green "Subdomain routing spot-checks passed."

# Postgres in-container test using LD_PRELOAD workspace isolation
echo "[pg] Setting up PostgreSQL in $WS_A and verifying connectivity"

# Initialize a dedicated data directory owned by postgres
docker exec "$CONTAINER" bash -lc "install -d -o postgres -g postgres -m 700 /var/lib/postgresql/ws-a"

# Initialize cluster with trust auth to simplify testing
docker exec "$CONTAINER" bash -lc "PGBIN=\"/usr/lib/postgresql/15/bin\"; su -s /bin/bash postgres -c \"env LD_PRELOAD=/usr/local/lib/libworkspace_net.so CMUX_WORKSPACE_INTERNAL=$WS_A \$PGBIN/initdb -D /var/lib/postgresql/ws-a --no-locale -A trust\""
# Allow connections from any 127/8 address (workspace IPs)
docker exec "$CONTAINER" bash -lc "echo 'host all all 127.0.0.0/8 trust' >> /var/lib/postgresql/ws-a/pg_hba.conf"

# Start postgres bound to 127.0.0.1 (shim rewrites to workspace IP for the server); separate unix_socket dir to avoid conflicts
docker exec "$CONTAINER" bash -lc "install -d -o postgres -g postgres -m 755 /tmp/pg-a; PGBIN=\"/usr/lib/postgresql/15/bin\"; su -s /bin/bash postgres -c \"env LD_PRELOAD=/usr/local/lib/libworkspace_net.so CMUX_WORKSPACE_INTERNAL=$WS_A \$PGBIN/postgres -D /var/lib/postgresql/ws-a -h 127.0.0.1 -p 5432 -k /tmp/pg-a >/tmp/pg-a.log 2>&1 &\""

echo "Waiting for PostgreSQL to become ready in $WS_A"
docker exec "$CONTAINER" bash -lc 'for i in $(seq 1 100); do CMUX_WORKSPACE_INTERNAL='"$WS_A"' PGHOST=127.0.0.1 PGPORT=5432 psql -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1 && exit 0; sleep 0.1; done; echo "postgres not ready" >&2; tail -n +1 /tmp/pg-a.log 2>/dev/null || true; exit 1'

# Inside workspace A, connecting to 127.0.0.1 should hit workspace IP and succeed
docker exec "$CONTAINER" bash -lc "cd /root/$WS_A && PGHOST=127.0.0.1 PGPORT=5432 psql -U postgres -d postgres -tAc 'SELECT 42' | grep -q '^42$'"
green "psql inside $WS_A connected successfully via 127.0.0.1 (remapped)."

# Start a second isolated PostgreSQL instance in workspace B on the same port
echo "[pg] Setting up PostgreSQL in $WS_B as an independent instance on the same port"
docker exec "$CONTAINER" bash -lc "install -d -o postgres -g postgres -m 700 /var/lib/postgresql/ws-b"
docker exec "$CONTAINER" bash -lc "PGBIN=\"/usr/lib/postgresql/15/bin\"; su -s /bin/bash postgres -c \"env LD_PRELOAD=/usr/local/lib/libworkspace_net.so CMUX_WORKSPACE_INTERNAL=$WS_B \$PGBIN/initdb -D /var/lib/postgresql/ws-b --no-locale -A trust\""
docker exec "$CONTAINER" bash -lc "echo 'host all all 127.0.0.0/8 trust' >> /var/lib/postgresql/ws-b/pg_hba.conf"
docker exec "$CONTAINER" bash -lc "install -d -o postgres -g postgres -m 755 /tmp/pg-b; PGBIN=\"/usr/lib/postgresql/15/bin\"; su -s /bin/bash postgres -c \"env LD_PRELOAD=/usr/local/lib/libworkspace_net.so CMUX_WORKSPACE_INTERNAL=$WS_B \$PGBIN/postgres -D /var/lib/postgresql/ws-b -h 127.0.0.1 -p 5432 -k /tmp/pg-b >/tmp/pg-b.log 2>&1 &\""

echo "Waiting for PostgreSQL to become ready in $WS_B"
docker exec "$CONTAINER" bash -lc 'for i in $(seq 1 100); do CMUX_WORKSPACE_INTERNAL='"$WS_B"' PGHOST=127.0.0.1 PGPORT=5432 psql -U postgres -d postgres -tAc "SELECT 1" >/dev/null 2>&1 && exit 0; sleep 0.1; done; echo "postgres B not ready" >&2; tail -n +1 /tmp/pg-b.log 2>/dev/null || true; exit 1'

# Now validate isolation by writing distinct data in each and verifying no cross-contamination
echo "[pg] Creating tables and inserting data in each isolated instance"
docker exec "$CONTAINER" bash -lc "cd /root/$WS_A && PGHOST=127.0.0.1 PGPORT=5432 psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'CREATE TABLE IF NOT EXISTS iso(k text);' -c \"INSERT INTO iso(k) VALUES('A');\""
docker exec "$CONTAINER" bash -lc "cd /root/$WS_B && PGHOST=127.0.0.1 PGPORT=5432 psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'CREATE TABLE IF NOT EXISTS iso(k text);' -c \"INSERT INTO iso(k) VALUES('B');\""

# Verify A sees only 'A'
docker exec "$CONTAINER" bash -lc "cd /root/$WS_A && PGHOST=127.0.0.1 PGPORT=5432 psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM iso WHERE k='A'\" | grep -q '^1$'"
docker exec "$CONTAINER" bash -lc "cd /root/$WS_A && PGHOST=127.0.0.1 PGPORT=5432 psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM iso WHERE k='B'\" | grep -q '^0$'"

# Verify B sees only 'B'
docker exec "$CONTAINER" bash -lc "cd /root/$WS_B && PGHOST=127.0.0.1 PGPORT=5432 psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM iso WHERE k='B'\" | grep -q '^1$'"
docker exec "$CONTAINER" bash -lc "cd /root/$WS_B && PGHOST=127.0.0.1 PGPORT=5432 psql -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM iso WHERE k='A'\" | grep -q '^0$'"

green "Postgres isolation verified: two instances on same port without cross-contamination."

green "All e2e tests passed."
