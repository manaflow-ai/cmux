#!/usr/bin/env bash
# Model-checks OwnershipConvergence.tla (plans/cmux-next/ownership.md section 7).
# Usage: plans/cmux-next/formal/run-ownership-tlc.sh [cfg] [--mutants]
#   cfg defaults to OwnershipConvergence.cfg (2 clients, 2 tabs, 2 panes, 1 op each,
#   1 fault, 1 retry). Larger: -faults2.cfg (~8 min), -2ops.cfg (longer, ~4 GB),
#   -live.cfg (liveness EventuallyConverged, no symmetry).
#   --mutants also checks seven broken variants and requires each to fail.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
jar="${TLA2TOOLS_JAR:-$HOME/.cache/cmux-tla/tla2tools-1.8.0.jar}"
sha="edee9330068fbb7be0bc9dc2bc928f5918a7635b5ee4da56dbb48556b7afa6a2"
if [[ ! -f "$jar" ]]; then
  mkdir -p "$(dirname "$jar")"
  curl -fsSL -o "$jar.tmp" https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
  mv "$jar.tmp" "$jar"
fi
echo "$sha  $jar" | shasum -a 256 -c - >/dev/null
cfg="$here/${1:-OwnershipConvergence.cfg}"
[[ "${1:-}" == --mutants ]] && cfg="$here/OwnershipConvergence.cfg"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$here/OwnershipConvergence.tla" "$work/"
tlc() { (cd "$work" && java -Xmx4g -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers 3 \
  -metadir "$work/meta-$1" "$1.tla" -config "$cfg" 2>&1); }
tlc OwnershipConvergence | grep -E "Error|violated|No error|states generated"
if [[ " $* " == *" --mutants "* ]]; then
  python3 - "$work" <<'PY'
import sys, pathlib
w = pathlib.Path(sys.argv[1]); s = (w / "OwnershipConvergence.tla").read_text()
def mutant(name, old, new):
    assert old in s, name
    (w / f"{name}.tla").write_text(s.replace("MODULE OwnershipConvergence", f"MODULE {name}").replace(old, new))
mutant("NoLedger", "IF m.op.id \\in Decided", "IF FALSE")
mutant("NoGapCheck", "IF msg.version = confirmed[c].version + 1", "IF msg.version > confirmed[c].version")
mutant("DropAtNextDelta", "/\\ UNCHANGED <<durable, staged, toOwner, connected, pending, held, settledOk, issued, faults, retries>>",
       "/\\ pending' = [pending EXCEPT ![c] = <<>>] /\\ UNCHANGED <<durable, staged, toOwner, connected, held, settledOk, issued, faults, retries>>")
mutant("SettleBeforeMirror", "IF msg.ok => confirmed[c].version >= msg.version", "IF TRUE")
mutant("PublishBeforeCommit", "/\\ UNCHANGED toClient\n",
       "/\\ toClient' = IF Valid(durable.state, m.op, m.from) THEN Reply(m.from, Settled(m.op.id, TRUE, durable.version + 1)) ELSE toClient\n")
mutant("TrustClaimedOwner", "IF op.kind = \"write\" THEN op.target = from ELSE", "IF op.kind = \"write\" THEN TRUE ELSE")
mutant("NoResendOnReconnect", "/\\ toOwner' = toOwner \\cup {[op |-> o, from |-> c] : o \\in Range(pending[c])}",
       "/\\ UNCHANGED toOwner")
PY
  for m in NoLedger NoGapCheck DropAtNextDelta SettleBeforeMirror PublishBeforeCommit TrustClaimedOwner NoResendOnReconnect; do
    if out="$(tlc "$m")"; grep -q "is violated" <<<"$out"; then
      echo "$m: fails as expected: $(grep -m1 'is violated' <<<"$out")"
    else
      echo "$m: expected a violation, got none" >&2; exit 1
    fi
  done
fi
