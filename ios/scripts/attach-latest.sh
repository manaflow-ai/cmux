#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CMX_RUST_PROFILE="${CMX_RUST_PROFILE:-release}"
CMX_BIN="$REPO_ROOT/rust/cmux-cli/target/$CMX_RUST_PROFILE/cmx"

usage() {
    cat <<'EOF'
Usage:
  ios/scripts/attach-latest.sh [tag]
  ios/scripts/attach-latest.sh --tag <tag>
  ios/scripts/attach-latest.sh --socket <path>
  ios/scripts/attach-latest.sh --list
  ios/scripts/attach-latest.sh --dry-run -- [cmx attach args...]

Defaults to the newest /tmp/cmx-ios-*.sock and attaches with this worktree's
optimized rust/cmux-cli/target/release/cmx binary.

Examples:
  ios/scripts/attach-latest.sh
  ios/scripts/attach-latest.sh edge19
  ios/scripts/attach-latest.sh --socket /tmp/cmx-ios-edge19.sock
EOF
}

socket_for_tag() {
    local tag="$1"
    tag="${tag#/tmp/cmx-ios-}"
    tag="${tag%.sock}"
    printf '/tmp/cmx-ios-%s.sock\n' "$tag"
}

list_sockets() {
    local sockets=()
    local socket_path
    for socket_path in /tmp/cmx-ios-*.sock; do
        if [ -S "$socket_path" ]; then
            sockets+=("$socket_path")
        fi
    done
    if [ "${#sockets[@]}" -gt 0 ]; then
        ls -lt "${sockets[@]}"
    fi
}

latest_socket() {
    list_sockets | awk 'NR == 1 { print $NF }'
}

SOCKET_PATH=""
TAG=""
LIST=0
DRY_RUN=0
ATTACH_ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --list)
            LIST=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --socket)
            SOCKET_PATH="${2:-}"
            if [ -z "$SOCKET_PATH" ]; then
                echo "error: --socket requires a path" >&2
                exit 2
            fi
            shift 2
            ;;
        --socket=*)
            SOCKET_PATH="${1#--socket=}"
            shift
            ;;
        --tag)
            TAG="${2:-}"
            if [ -z "$TAG" ]; then
                echo "error: --tag requires a tag" >&2
                exit 2
            fi
            shift 2
            ;;
        --tag=*)
            TAG="${1#--tag=}"
            shift
            ;;
        --)
            shift
            ATTACH_ARGS+=("$@")
            break
            ;;
        -*)
            ATTACH_ARGS+=("$1")
            shift
            ;;
        *)
            if [ -z "$TAG" ] && [ -z "$SOCKET_PATH" ]; then
                TAG="$1"
            else
                ATTACH_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

if [ "$LIST" -eq 1 ]; then
    list_sockets
    exit 0
fi

if [ -n "$TAG" ]; then
    SOCKET_PATH="$(socket_for_tag "$TAG")"
fi

if [ -z "$SOCKET_PATH" ]; then
    SOCKET_PATH="$(latest_socket)"
fi

if [ -z "$SOCKET_PATH" ]; then
    echo "error: no /tmp/cmx-ios-*.sock sockets found" >&2
    echo "hint: start a cmx iroh bridge, then rerun this script" >&2
    exit 1
fi

if [ ! -S "$SOCKET_PATH" ]; then
    echo "error: socket does not exist: $SOCKET_PATH" >&2
    exit 1
fi

if [ ! -x "$CMX_BIN" ]; then
    echo "error: cmx binary is missing: $CMX_BIN" >&2
    echo "hint: cd $REPO_ROOT/rust/cmux-cli && cargo build --release -p cmx" >&2
    exit 1
fi

echo "Attaching to $SOCKET_PATH"
echo "Using $CMX_BIN"
if [ "$DRY_RUN" -eq 1 ]; then
    printf 'CMX_SOCKET_PATH=%q %q attach' "$SOCKET_PATH" "$CMX_BIN"
    if [ "${#ATTACH_ARGS[@]}" -gt 0 ]; then
        printf ' %q' "${ATTACH_ARGS[@]}"
    fi
    printf '\n'
    exit 0
fi

exec env CMX_SOCKET_PATH="$SOCKET_PATH" "$CMX_BIN" attach "${ATTACH_ARGS[@]}"
