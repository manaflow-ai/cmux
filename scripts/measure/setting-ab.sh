#!/usr/bin/env bash
# A default-off setting's off/on A/B in ONE measure step on whichever measure Mac is free (scratch, goal instant-splits).
# Same commit, same app (built once via --app-cache), interleaved rounds off, on, off, on, ... on one host:
#   cmux-ci run --class exclusive --measurement --label measure --display --script scripts/measure/setting-ab.sh \
#     --ref <sha> --arg=kind=NAME [--arg=rounds=2] --arg=--suite=split-scale ... --artifact .build/setting-ab/report.tgz
# kind=NAME is passed as --motion-kind=NAME=off|on to scripts/measure/split-spring.sh; other args go to both arms.
# Leo, 2026-11-28: "Ok well we can't be letting important rfds like that take breaks unless I put in fleet wide
# pauses, esp when this is stuff that materially improves the app".
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
kind="" rounds=2 args=()
for a in "$@"; do case "$a" in kind=*) kind="${a#kind=}" ;; rounds=*) rounds="${a#rounds=}" ;; *) args+=("$a") ;; esac; done
[[ -n "$kind" ]] || { echo "setting-ab: kind= is required" >&2; exit 2; }
out="$PWD/.build/setting-ab"; rm -rf "$out"; mkdir -p "$out"
echo "SETTING-AB host $(hostname -s) kind $kind rounds $rounds args ${args[*]-}"
ok=0
for ((r=1; r<=rounds; r++)); do
  for arm in off on; do
    rm -rf artifacts/split-spring
    scripts/measure/split-spring.sh "${args[@]}" "--motion-kind=$kind=$arm"; rc=$?
    echo "SETTING-AB round $arm $r rc $rc"
    [[ $rc == 0 ]] && ok=$((ok+1))
    mkdir -p "$out/$arm-r$r"; cp -R artifacts/split-spring/. "$out/$arm-r$r/" 2>/dev/null
  done
done
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz .
[[ $ok == $((rounds*2)) ]] && exit 0
[[ $ok == 0 ]] && exit 3
exit 1
