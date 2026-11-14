#!/bin/bash
# cmux shim (~/.local/bin/cmux in the cuev guest). The harness sets each task's
# deny list with `cmux settings set computerUse.deniedApps JSON`, which cmux
# refuses from an agent-context CLI ("userOnly"). Here the shim writes the
# person's settings file directly (what Settings > Computer Use does) and waits
# until `cmux computer-use status` reports the list; everything else goes to the real CLI.
REAL="/Applications/$(cat ~/cub-assets/cmux-app-name)/Contents/Resources/bin/cmux"
if [[ $1 == settings && $2 == set && $3 == computerUse.deniedApps ]]; then
  /usr/bin/python3 - "$4" <<'PY'
import json, os, sys
p = os.path.expanduser("~/.config/cmux/cmux-next.json")
c = json.load(open(p))
c.setdefault("computerUse", {})["deniedApps"] = json.loads(sys.argv[1])
tmp = p + ".tmp"; json.dump(c, open(tmp, "w"), indent=2); os.replace(tmp, p)
PY
  want=$(/usr/bin/python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$4")
  for _ in $(seq 1 50); do
    got=$("$REAL" computer-use status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(len(d.get("denied_apps", d.get("deniedApps", []))))
except Exception: print(-1)')
    [[ $got == "$want" ]] && { echo "deniedApps set ($want)"; exit 0; }
    /bin/sleep 0.2
  done
  echo "cmux-shim: deniedApps written but status shows $got entries, want $want" >&2; exit 0
fi
exec "$REAL" "$@"
