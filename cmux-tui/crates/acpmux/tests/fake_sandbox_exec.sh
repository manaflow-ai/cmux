#!/bin/sh
# A stand-in for sandbox-exec that applies no sandbox: it drops the profile
# (-p PROFILE, -f FILE) and parameters (-D KEY=VALUE) and runs the command.
# The spawn canary must see through it (tests/remote_sandbox_canary.rs).
while [ $# -gt 0 ]; do
  case "$1" in
    -p|-f|-D) shift 2 ;;
    *) break ;;
  esac
done
exec "$@"
