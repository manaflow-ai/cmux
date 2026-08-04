#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${CMUX_BROKER_URL:?Set CMUX_BROKER_URL to the broker origin}"
: "${CMUX_BROKER_ACCESS_TOKEN:?Set CMUX_BROKER_ACCESS_TOKEN for enrollment-token minting}"
: "${CMUX_BROKER_REFRESH_TOKEN:?Set CMUX_BROKER_REFRESH_TOKEN for enrollment-token minting}"

CMUX_RELAY_ENVIRONMENT="${CMUX_RELAY_ENVIRONMENT:-production}"
CMUX_CONTAINER_BROKER_URL="${CMUX_CONTAINER_BROKER_URL:-$CMUX_BROKER_URL}"
CMUX_CONTAINER_BROKER_FORWARD="${CMUX_CONTAINER_BROKER_FORWARD:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/docs/evidence/iroh-tui-stage1-sol}"
demo_root="$(mktemp -d "${TMPDIR:-/tmp}/cmux-iroh-stage1-sol.XXXXXX")"
image="cmux-iroh-stage1-sol:$(date +%s)-$$"
container="cmux-iroh-stage1-sol-$$"
volume="cmux-iroh-stage1-sol-state-$$"
provider_socket="$demo_root/provider.sock"
provider_log="$demo_root/provider.log"
transcript="$demo_root/transcript.txt"
host_target="$demo_root/target"
host_binary="$host_target/debug/cmux-tui-iroh"
build_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]; then
    build_commit="${build_commit}-dirty"
fi

provider_pid=""
cleanup() {
    if [ -n "$provider_pid" ]; then
        kill "$provider_pid" 2>/dev/null || true
        wait "$provider_pid" 2>/dev/null || true
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
    docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf "$demo_root"
}
trap cleanup EXIT

record() {
    printf '%s\n' "$*" | tee -a "$transcript"
}

mint_enrollment_token() {
    printf 'header = "Authorization: Bearer %s"\nheader = "X-Stack-Refresh-Token: %s"\n' \
        "$CMUX_BROKER_ACCESS_TOKEN" "$CMUX_BROKER_REFRESH_TOKEN" \
    | curl --config - --fail --silent --show-error \
        --request POST \
        --header 'Content-Type: application/json' \
        --data '{}' \
        "$CMUX_BROKER_URL/api/devices/iroh/enrollment-tokens" \
        | jq --exit-status --raw-output '.token'
}

wait_for_file() {
    local path="$1"
    local _
    for _ in $(seq 1 240); do
        if [ -S "$path" ] || [ -f "$path" ]; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

wait_for_container_ready_count() {
    local expected="$1"
    local _ count
    for _ in $(seq 1 240); do
        count="$(docker logs "$container" 2>&1 | grep -c 'server ready' || true)"
        if [ "$count" -ge "$expected" ]; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

mkdir -p "$EVIDENCE_DIR"
record "iroh TUI Stage 1 acceptance"
record "broker=$CMUX_BROKER_URL relay_environment=$CMUX_RELAY_ENVIRONMENT"
record "source=$build_commit"
record "build_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

docker build \
    --progress plain \
    --file "$REPO_ROOT/scripts/iroh-tui-stage1/Dockerfile" \
    --build-arg "CMUX_TUI_BUILD_COMMIT=$build_commit" \
    --tag "$image" \
    "$REPO_ROOT"

cargo build \
    --manifest-path "$REPO_ROOT/cmux-tui/Cargo.toml" \
    --target-dir "$host_target" \
    --locked \
    -p cmux-tui \
    -p cmux-tui-iroh

server_token="$(mint_enrollment_token)"
provider_token="$(mint_enrollment_token)"
unset CMUX_BROKER_ACCESS_TOKEN CMUX_BROKER_REFRESH_TOKEN
printf '%s\n' "$provider_token" \
    | "$host_binary" enroll \
        --state-root "$demo_root/provider-state" \
        --identity provider \
        --broker "$CMUX_BROKER_URL" \
        --token-stdin \
    | tee -a "$transcript"
unset provider_token

docker volume create "$volume" >/dev/null
docker_args=(
    --detach
    --interactive
    --name "$container"
    --env "CMUX_BROKER_URL=$CMUX_CONTAINER_BROKER_URL"
    --env "CMUX_RELAY_ENVIRONMENT=$CMUX_RELAY_ENVIRONMENT"
    --mount "type=volume,source=$volume,target=/state"
)
if [ -n "$CMUX_CONTAINER_BROKER_FORWARD" ]; then
    docker_args+=(
        --add-host host.docker.internal:host-gateway
        --env "CMUX_BROKER_FORWARD=$CMUX_CONTAINER_BROKER_FORWARD"
    )
fi
printf '%s\n' "$server_token" \
    | docker run "${docker_args[@]}" "$image" >/dev/null
unset server_token

wait_for_container_ready_count 1
first_ready="$(docker logs "$container" 2>&1 | grep 'server ready' | head -n 1)"
port_bindings="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$container")"
published_ports="$(docker port "$container")"
record "container_port_bindings=$port_bindings"
if [ -n "$published_ports" ]; then
    record "FAIL published_ports=$published_ports"
    exit 1
fi
record "container_published_ports=none"
record "container_network_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$container")"
record "first_$first_ready"

"$host_binary" provider \
    --state-root "$demo_root/provider-state" \
    --identity provider \
    --broker "$CMUX_BROKER_URL" \
    --relay-environment "$CMUX_RELAY_ENVIRONMENT" \
    --display-name mac-stage1 \
    --socket "$provider_socket" >"$provider_log" 2>&1 &
provider_pid=$!
wait_for_file "$provider_socket"
grep 'provider ready' "$provider_log" | tee -a "$transcript"

"$host_binary" probe \
    --socket "$provider_socket" | tee -a "$transcript"
record "detach_reattach_before_restart=ok"

docker restart "$container" >/dev/null
wait_for_container_ready_count 2
second_ready="$(docker logs "$container" 2>&1 | grep 'server ready' | tail -n 1)"
record "second_$second_ready"
if [ "$first_ready" != "$second_ready" ]; then
    record "FAIL server identity or binding changed across restart"
    exit 1
fi
record "container_endpoint_device_tag_and_binding_stable=ok"

"$host_binary" probe \
    --socket "$provider_socket" | tee -a "$transcript"
record "reattach_after_restart=ok"
grep -E 'connected machine=.*path=relay' "$provider_log" | tail -n 3 | tee -a "$transcript"
record "acceptance=pass completed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cp "$transcript" "$EVIDENCE_DIR/transcript.txt"
{
    printf '{"version":2,"width":120,"height":30,"timestamp":%s,"env":{"TERM":"xterm-256color","SHELL":"bash"}}\n' "$(date +%s)"
    awk '{
        gsub(/\\/, "\\\\");
        gsub(/\"/, "\\\"");
        gsub(/\r/, "");
        printf "[%0.2f,\"o\",\"%s\\r\\n\"]\n", NR * 0.15, $0
    }' "$transcript"
} > "$EVIDENCE_DIR/demo.cast"
record "evidence=$EVIDENCE_DIR/transcript.txt"
record "recording=$EVIDENCE_DIR/demo.cast"
