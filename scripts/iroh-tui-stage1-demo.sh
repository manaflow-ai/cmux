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
build_cache_root="${CMUX_STAGE1_BUILD_CACHE_ROOT:-$demo_root/build-cache}"
image="cmux-iroh-stage1-sol:$(date +%s)-$$"
builder_image="cmux-iroh-stage1-sol-builder:$(date +%s)-$$"
container="cmux-iroh-stage1-sol-$$"
volume="cmux-iroh-stage1-sol-state-$$"
zig_cache_volume="${CMUX_STAGE1_ZIG_CACHE_VOLUME:-cmux-iroh-stage1-sol-zig-cache-$$}"
zig_pkg_volume="${CMUX_STAGE1_ZIG_PKG_VOLUME:-cmux-iroh-stage1-sol-zig-pkg-$$}"
remove_zig_cache_volume=1
remove_zig_pkg_volume=1
if [ -n "${CMUX_STAGE1_ZIG_CACHE_VOLUME:-}" ]; then
    remove_zig_cache_volume=0
fi
if [ -n "${CMUX_STAGE1_ZIG_PKG_VOLUME:-}" ]; then
    remove_zig_pkg_volume=0
fi
case "$zig_cache_volume" in
    "" | *[!a-zA-Z0-9_.-]*)
        echo "invalid Docker volume name" >&2
        exit 1
        ;;
esac
case "$zig_pkg_volume" in
    "" | *[!a-zA-Z0-9_.-]*)
        echo "invalid Docker volume name" >&2
        exit 1
        ;;
esac
provider_socket="$demo_root/provider.sock"
provider_log="$demo_root/provider.log"
server_token_file="$demo_root/server-provisioning-token"
transcript="$demo_root/transcript.txt"
host_target="$build_cache_root/host-target"
host_binary="$host_target/debug/cmux-tui-iroh"
linux_target="$build_cache_root/linux-target"
linux_cargo_home="$build_cache_root/linux-cargo-home"
linux_resolv_conf="$demo_root/linux-resolv.conf"
runtime_context="$demo_root/runtime-context"
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
    if [ "$remove_zig_cache_volume" -eq 1 ]; then
        docker volume rm "$zig_cache_volume" >/dev/null 2>&1 || true
    fi
    if [ "$remove_zig_pkg_volume" -eq 1 ]; then
        docker volume rm "$zig_pkg_volume" >/dev/null 2>&1 || true
    fi
    docker image rm "$image" >/dev/null 2>&1 || true
    docker image rm "$builder_image" >/dev/null 2>&1 || true
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

mkdir -p \
    "$EVIDENCE_DIR" \
    "$linux_target" \
    "$linux_cargo_home" \
    "$runtime_context/bin" \
    "$runtime_context/lib"
record "iroh TUI Stage 1 acceptance"
record "broker=$CMUX_BROKER_URL relay_environment=$CMUX_RELAY_ENVIRONMENT"
record "source=$build_commit"
record "build_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

docker build \
    --progress plain \
    --file "$REPO_ROOT/scripts/iroh-tui-stage1/Dockerfile" \
    --tag "$builder_image" \
    "$REPO_ROOT"

docker run --rm "$builder_image" \
    awk '/^nameserver[[:space:]]/ { print "nameserver " $2; exit }' /etc/resolv.conf \
    > "$linux_resolv_conf"
if ! grep -Eq '^nameserver [0-9a-fA-F:.]+$' "$linux_resolv_conf"; then
    echo "failed to derive a clean Docker resolver configuration" >&2
    exit 1
fi

docker volume create "$zig_cache_volume" >/dev/null
docker volume create "$zig_pkg_volume" >/dev/null
docker run --rm \
    --env "CARGO_HOME=/build/cargo-home" \
    --env "CARGO_PROFILE_RELEASE_LTO=false" \
    --env "CARGO_TARGET_DIR=/build/target" \
    --env "CMUX_TUI_BUILD_COMMIT=$build_commit" \
    --env "ZIG_GLOBAL_CACHE_DIR=/build/zig-cache/global" \
    --env "ZIG_LOCAL_CACHE_DIR=/build/zig-cache/local" \
    --mount "type=bind,source=$REPO_ROOT,target=/source,readonly" \
    --mount "type=bind,source=$linux_cargo_home,target=/build/cargo-home" \
    --mount "type=bind,source=$linux_resolv_conf,target=/etc/resolv.conf,readonly" \
    --mount "type=bind,source=$linux_target,target=/build/target" \
    --mount "type=volume,source=$zig_cache_volume,target=/build/zig-cache" \
    --mount "type=volume,source=$zig_pkg_volume,target=/source/ghostty/zig-pkg" \
    --workdir /source \
    "$builder_image" \
    cargo build \
        --manifest-path /source/cmux-tui/Cargo.toml \
        --locked \
        --release \
        -p cmux-tui \
        -p cmux-tui-iroh

cp "$linux_target/release/cmux-tui" "$runtime_context/bin/"
cp "$linux_target/release/cmux-tui-iroh" "$runtime_context/bin/"
find "$linux_target/release/build" -path '*/out/ghostty-vt/lib/libghostty-vt.so*' \
    -exec cp {} "$runtime_context/lib/" \;
cp "$REPO_ROOT/scripts/iroh-tui-stage1/container-entrypoint.sh" \
    "$runtime_context/container-entrypoint.sh"

docker build \
    --progress plain \
    --file "$REPO_ROOT/scripts/iroh-tui-stage1/Dockerfile.runtime" \
    --build-arg "CMUX_TUI_BUILD_COMMIT=$build_commit" \
    --tag "$image" \
    "$runtime_context"

cargo build \
    --manifest-path "$REPO_ROOT/cmux-tui/Cargo.toml" \
    --target-dir "$host_target" \
    --locked \
    -p cmux-tui \
    -p cmux-tui-iroh

server_token="$(mint_enrollment_token)"
(umask 022; printf '%s\n' "$server_token" > "$server_token_file")
unset server_token
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
    --name "$container"
    --env "CMUX_BROKER_URL=$CMUX_CONTAINER_BROKER_URL"
    --env "CMUX_PROVISIONING_TOKEN_FILE=/run/cmux/provisioning-token"
    --env "CMUX_RELAY_ENVIRONMENT=$CMUX_RELAY_ENVIRONMENT"
    --mount "type=bind,source=$server_token_file,target=/run/cmux/provisioning-token,readonly"
    --mount "type=volume,source=$volume,target=/state"
)
if [ -n "$CMUX_CONTAINER_BROKER_FORWARD" ]; then
    docker_args+=(
        --add-host host.docker.internal:host-gateway
        --env "CMUX_BROKER_FORWARD=$CMUX_CONTAINER_BROKER_FORWARD"
    )
fi
if ! docker run "${docker_args[@]}" "$image" >/dev/null; then
    docker logs "$container" >&2 || true
    exit 1
fi

if ! wait_for_container_ready_count 1; then
    docker logs "$container" >&2 || true
    exit 1
fi
chmod 0600 "$server_token_file"
: > "$server_token_file"
first_ready="$(docker logs "$container" 2>&1 | grep 'server ready' | head -n 1)"
server_binding="${first_ready#* binding=}"
server_binding="${server_binding%% *}"
if [[ ! "$server_binding" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
    record "FAIL server binding is invalid"
    exit 1
fi
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
if ! wait_for_file "$provider_socket"; then
    cat "$provider_log" >&2
    exit 1
fi
grep 'provider ready' "$provider_log" | tee -a "$transcript"

if ! "$host_binary" probe \
    --socket "$provider_socket" \
    --machine-id "$server_binding" | tee -a "$transcript"; then
    cat "$provider_log" >&2
    docker logs "$container" >&2 || true
    exit 1
fi
record "detach_reattach_before_restart=ok"

docker restart "$container" >/dev/null
if ! wait_for_container_ready_count 2; then
    docker logs "$container" >&2 || true
    exit 1
fi
second_ready="$(docker logs "$container" 2>&1 | grep 'server ready' | tail -n 1)"
record "second_$second_ready"
if [ "$first_ready" != "$second_ready" ]; then
    record "FAIL server identity or binding changed across restart"
    exit 1
fi
record "container_endpoint_device_tag_and_binding_stable=ok"

if ! "$host_binary" probe \
    --socket "$provider_socket" \
    --machine-id "$server_binding" | tee -a "$transcript"; then
    cat "$provider_log" >&2
    docker logs "$container" >&2 || true
    exit 1
fi
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
