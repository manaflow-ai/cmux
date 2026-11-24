#!/bin/bash
# The demo on a cmux Cloud machine, from a Mac with the cmux app signed in.
#
#   ./vm.sh install VM_ID [MODEL]   copy the demo there, start its store, machine loop and relay,
#                                   forward its ports to this Mac, and `auto login` to it
#   ./vm.sh relay VM_ID             this Mac's side of the model relay (keep it running)
#   ./vm.sh logs VM_ID              the machine's log
#   ./vm.sh stop VM_ID              stop the demo there and close the forwards
#
# A machine made with `cmux vm new --name auto-demo` works. Its agent has no model route of its
# own here, so its calls go through `relay` on this Mac (autodemo/relay.py): no credential is
# put on the machine. Tokens for the store and the relay are made once and kept, mode 600, in
# $AUTO_VM_STATE (default ~/.cmux-auto-demo/vm/VM_ID).
set -euo pipefail

cmd=${1:-}; vm=${2:-}
[ -n "$cmd" ] && [ -n "$vm" ] || { sed -n '2,13p' "$0"; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
state=${AUTO_VM_STATE:-$HOME/.cmux-auto-demo/vm/$vm}
umask 077; mkdir -p "$state"

token() {  # NAME: a token kept in the state folder
    [ -s "$state/$1.token" ] || python3 -c 'import secrets; print(secrets.token_urlsafe(18))' > "$state/$1.token"
    cat "$state/$1.token"
}

run() { cmux vm exec "$vm" -- "$1"; }  # killed after 25 s there: start long things in tmux

forward() {  # PORT: forwards it and prints the local port (it changes every time)
    cmux vm port-close --target "vm:$vm" --port "$1" > /dev/null 2>&1 || true
    cmux vm port-forward --target "vm:$vm" --port "$1" --json | python3 -c '
import json, sys
def find(o):
    if isinstance(o, dict):
        if "local_port" in o:
            return o["local_port"]
        o = list(o.values())
    for v in o if isinstance(o, list) else []:
        r = find(v)
        if r:
            return r
print(find(json.load(sys.stdin)))'
}

case "$cmd" in
install)
    model=${3:-}
    cmux vm set-idle-pause --target "vm:$vm" --minutes off > /dev/null   # a paused machine runs nothing
    payload=$(COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --exclude __pycache__ -C "$here" -czf - auto autodemo | base64 | tr -d '\n')
    run "mkdir -p ~/auto-demo ~/auto-demo-home && echo $payload | base64 -d | tar -xzf - -C ~/auto-demo"
    env=$(printf 'export AUTO_STORE_TOKEN=%s\nexport AUTO_RELAY_TOKEN=%s\nexport AUTO_HOME=$HOME/auto-demo-home\nexport AUTO_CLAUDE_CONFIG_DIR=$HOME/auto-demo-home/claude\nexport AUTO_AGENT_CMD=$(command -v claude || echo /opt/cmux/current/bin/claude)\nexport ANTHROPIC_BASE_URL=http://127.0.0.1:7790\nexport ANTHROPIC_AUTH_TOKEN=relay\nexport PYTHONUNBUFFERED=1\n' "$(token store)" "$(token relay)" | base64 | tr -d '\n')
    run "umask 077; echo $env | base64 -d > ~/auto-demo/env"
    run "tmux kill-session -t auto-relay 2>/dev/null; tmux kill-session -t auto-cloud 2>/dev/null; cd ~/auto-demo \
      && tmux new-session -d -s auto-relay '. ./env; python3 auto relay in --token \$AUTO_RELAY_TOKEN >> relay.log 2>&1' \
      && tmux new-session -d -s auto-cloud '. ./env; python3 auto cloud --name auto-demo --token \$AUTO_STORE_TOKEN ${model:+--model $model} >> cloud.log 2>&1' \
      && sleep 2 && curl -s localhost:7717/health"
    echo
    port=$(forward 7717)
    "$here/auto" login "http://127.0.0.1:$port" "$(token store)"
    echo "next: ./vm.sh relay $vm   (in another terminal), then: ./auto chat"
    ;;
relay)
    port=$(forward 7791)
    exec "$here/auto" relay out "127.0.0.1:$port" --token "$(token relay)"
    ;;
logs)
    run "tail -n ${3:-40} ~/auto-demo/cloud.log"
    ;;
stop)
    run "tmux kill-session -t auto-relay 2>/dev/null; tmux kill-session -t auto-cloud 2>/dev/null; echo stopped"
    cmux vm port-close --target "vm:$vm" --port 7717 > /dev/null 2>&1 || true
    cmux vm port-close --target "vm:$vm" --port 7791 > /dev/null 2>&1 || true
    ;;
*)
    sed -n '2,13p' "$0"; exit 2
    ;;
esac
