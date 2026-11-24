#!/bin/bash
# The demo on any Linux machine you can ssh to. Nothing else is needed: no cmux app, no open
# port. The store and the model relay are reached through `ssh -L`.
#
#   ./remote.sh install TARGET [MODEL]   copy the demo there and start its store, machine loop
#                                        and relay in tmux (needs python3, tmux, claude there)
#   ./remote.sh up TARGET                hold the port forwards and this side of the model relay,
#                                        and `auto login` to the store (keep it running)
#   ./remote.sh logs TARGET [N]          the machine's log
#   ./remote.sh stop TARGET              stop the demo there
#
# TARGET is user@host. With AUTO_SSH set, that program is run instead of `ssh TARGET`: it gets
# ssh's options, then the remote command, and knows the host itself (freestyle/vmssh is one,
# for a Freestyle VM; TARGET is then only a name for the state folder).
#
# The lease is 45 s there (AUTO_LEASE), the product's value: a link through ssh can stand still
# for 25 s, and with a 15 s lease the store then gives a working laptop's chat to the machine.
#
# The remote agent gets its model route through `up` on this side (autodemo/relay.py), with
# this shell's ANTHROPIC_* settings: no credential is put on the remote machine. Tokens for the
# store and the relay are made once and kept, mode 600, in ~/.cmux-auto-demo/remote/TARGET.
set -euo pipefail

cmd=${1:-}; target=${2:-}
[ -n "$cmd" ] && [ -n "$target" ] || { sed -n '2,20p' "$0"; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
state=${AUTO_REMOTE_STATE:-$HOME/.cmux-auto-demo/remote/$(printf %s "$target" | tr -c 'A-Za-z0-9._@-' _)}
dir=${AUTO_REMOTE_DIR:-auto-demo}          # where the demo goes there, under the remote home
store_port=${AUTO_LOCAL_STORE_PORT:-27717}; relay_port=${AUTO_LOCAL_RELAY_PORT:-27791}
umask 077; mkdir -p "$state"

rsh() {  # [ssh options...] 'remote command'
    if [ -n "${AUTO_SSH:-}" ]; then "$AUTO_SSH" "$@"; else
        local n=$#; ssh -o ServerAliveInterval=15 "${@:1:$((n - 1))}" "$target" "${@:$n}"
    fi
}

token() {  # NAME: a token kept in the state folder
    [ -s "$state/$1.token" ] || python3 -c 'import secrets; print(secrets.token_urlsafe(18))' > "$state/$1.token"
    cat "$state/$1.token"
}

case "$cmd" in
install)
    model=${3:-}
    COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude __pycache__ -C "$here" -czf - auto autodemo \
        | rsh "mkdir -p ~/$dir ~/$dir-home && tar -xzf - -C ~/$dir"
    printf 'export AUTO_STORE_TOKEN=%s\nexport AUTO_RELAY_TOKEN=%s\nexport AUTO_HOME=$HOME/%s-home\nexport AUTO_CLAUDE_CONFIG_DIR=$HOME/%s-home/claude\nexport ANTHROPIC_BASE_URL=http://127.0.0.1:7790\nexport ANTHROPIC_AUTH_TOKEN=relay\nexport PYTHONUNBUFFERED=1\n' \
        "$(token store)" "$(token relay)" "$dir" "$dir" | rsh "umask 077; cat > ~/$dir/env"
    rsh "cd ~/$dir; tmux kill-session -t auto-relay 2>/dev/null; tmux kill-session -t auto-cloud 2>/dev/null; \
      tmux new-session -d -s auto-relay '. ./env; python3 auto relay in --tunnel-host 127.0.0.1 --token \$AUTO_RELAY_TOKEN >> relay.log 2>&1'; \
      tmux new-session -d -s auto-cloud '. ./env; python3 auto cloud --host 127.0.0.1 --name \$(hostname -s) --token \$AUTO_STORE_TOKEN --lease ${AUTO_LEASE:-45} ${model:+--model $model} >> cloud.log 2>&1'; \
      sleep 2; curl -s localhost:7717/health; echo; command -v claude > /dev/null || echo 'warning: no claude on PATH there'"
    echo "next: ./remote.sh up $target   (keep it running), then in another terminal: ./auto chat"
    ;;
up)
    # The forward is held in a loop: an ssh that ends (a dropped network, a sleeping laptop) is
    # started again, and both sides of the demo take up where they were.
    forward() {
        while :; do
            rsh -N -o ExitOnForwardFailure=yes -L "127.0.0.1:$store_port:127.0.0.1:7717" -L "127.0.0.1:$relay_port:127.0.0.1:7791" "" || true
            echo "$(date +%H:%M:%S) the ssh forward ended; starting it again" >&2
            python3 -c 'import time; time.sleep(1)'
        done
    }
    forward &
    forward=$!
    trap 'pkill -P $forward 2>/dev/null; kill $forward 2>/dev/null' EXIT
    for _ in $(seq 1 40); do
        python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', $store_port), 1)" 2>/dev/null && break
        python3 -c 'import time; time.sleep(0.5)'
    done
    "$here/auto" login "http://127.0.0.1:$store_port" "$(token store)"
    "$here/auto" relay out "127.0.0.1:$relay_port" --token "$(token relay)"
    ;;
logs)
    rsh "tail -n ${3:-40} ~/$dir/cloud.log"
    ;;
stop)
    rsh "tmux kill-session -t auto-relay 2>/dev/null; tmux kill-session -t auto-cloud 2>/dev/null; echo stopped"
    ;;
*)
    sed -n '2,20p' "$0"; exit 2
    ;;
esac
