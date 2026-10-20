#!/usr/bin/env bash
# Laptop-side shim: run fv.py commands on the rig mini. usage: fvr.sh CMD ARGS... ; fvr.sh sh 'shell on mini'
host=${FV_HOST:-mini-cmuxs-mac-mini-2}
if [[ "$1" == sh ]]; then shift; exec ssh -o BatchMode=yes "$host" "cd ~/cnx-fv && export PATH=\$HOME/cnx-fv/bin:/opt/homebrew/bin:\$PATH DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; $*"; fi
q=$(printf '%q ' "$@")
exec ssh -o BatchMode=yes "$host" "cd ~/cnx-fv && python3 fv.py $q"
