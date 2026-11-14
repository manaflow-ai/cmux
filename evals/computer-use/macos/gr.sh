#!/bin/bash
# gr.sh [-t SECONDS] [-b] CMD... : run CMD in the guest console user's Aqua session
# (launchd gui/<uid>) so it sees the WindowServer, and wait for it (bounded).
# Prints its combined output and exits with its status. -b: start and return.
timeout=1800; bg=0
while [[ $1 == -* ]]; do
  case $1 in -t) timeout=$2; shift 2;; -b) bg=1; shift;; *) break;; esac
done
uid=$(id -u)
label=dev.cmux.cuev.$$.$RANDOM
d=$HOME/cuev-gr; mkdir -p "$d"
out=$d/$label.out; rc=$d/$label.rc; plist=$d/$label.plist
cmd=$(printf '%q ' "$@")
/usr/bin/python3 - "$plist" "$label" "cd $HOME/cu; $cmd > $out 2>&1; echo \$? > $rc" <<'PY'
import plistlib, sys, os
p, label, script = sys.argv[1:]
plistlib.dump({"Label": label, "ProgramArguments": ["/bin/bash", "-c", script], "RunAtLoad": True,
               "ProcessType": "Interactive",
               "EnvironmentVariables": {"PATH": os.path.expanduser("~/.local/bin") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                        "HOME": os.path.expanduser("~"), "LANG": "en_US.UTF-8"}},
              open(p, "wb"))
PY
launchctl bootstrap "gui/$uid" "$plist"
if (( bg )); then echo "$label $out $rc"; exit 0; fi
start=$(date +%s)
while [[ ! -f $rc ]]; do
  (( $(date +%s) - start > timeout )) && { echo "gr.sh: timeout after ${timeout}s" >&2; launchctl bootout "gui/$uid/$label" 2>/dev/null; cat "$out"; exit 124; }
  /bin/sleep 1
done
launchctl bootout "gui/$uid/$label" 2>/dev/null
cat "$out"
exit "$(cat "$rc")"
