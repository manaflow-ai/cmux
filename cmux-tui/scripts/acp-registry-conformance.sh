#!/usr/bin/env bash
# The ACP conformance cases against every agent in the ACP Registry (hub/acp_registry_live_tests.rs), one row per
# (agent, agent version, case) at this checkout's commit, written to OUT/matrix.json (acp-registry-matrix/v1).
#
#   cmux-tui/scripts/acp-registry-conformance.sh OUT [AGENT_ID...]
#
# No ids: every agent the registry lists. The registry is the CDN copy, fetched once (ACP_CONFORMANCE_REGISTRY
# names a file instead). An agent that starts through `npx` or `uvx` starts the way cmux starts it; one that ships
# only a binary archive is installed the way a person installs it (the archive for this platform, its sha256 checked
# when the registry names one, its program put on PATH), and cmux then finds it on PATH. Nothing here needs an
# account or a model. Exit 1 when any case failed.
set -uo pipefail

out=${1:?usage: acp-registry-conformance.sh OUT [AGENT_ID...]}
shift
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
registry=${ACP_CONFORMANCE_REGISTRY:-$out/registry.json}
if [ -z "${ACP_CONFORMANCE_REGISTRY:-}" ]; then
  curl -fsS --max-time 30 --max-filesize 1048576 -A acp-registry-conformance -o "$registry" \
    https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json || { echo "registry unread" >&2; exit 2; }
fi
per_agent=${ACP_CONFORMANCE_AGENT_TIMEOUT:-600}
commit=$(git -C "$here" rev-parse HEAD)

if [ "$#" -eq 0 ]; then
  mapfile -t ids < <(python3 -I -c 'import json,sys; print("\n".join(a["id"] for a in json.load(open(sys.argv[1]))["agents"]))' "$registry")
else
  ids=("$@")
fi

matrix() {
  python3 -I "$here/scripts/acp_registry_matrix.py" "$out" "$registry" "$commit" "${ids[@]}" >"$out/matrix.json.tmp" \
    && mv "$out/matrix.json.tmp" "$out/matrix.json"
}

# A `uvx` agent starts only where uvx is on PATH; a host without it gets uv in a venv here, so the row measures
# the agent rather than this host.
if ! command -v uvx >/dev/null 2>&1; then
  python3 -m venv "$out/uv" && "$out/uv/bin/pip" install --quiet uv >"$out/uv.log" 2>&1 && PATH="$out/uv/bin:$PATH"
fi

# Build once; each agent's run then reuses it.
(cd "$here" && cargo test --locked -p acpmux --lib --no-run) >"$out/build.log" 2>&1
build=$?

for id in "${ids[@]}"; do
  log="$out/$id.log"
  : >"$log"
  if [ "$build" -ne 0 ]; then
    echo "acp-build-failed" >>"$log"
    continue
  fi
  bin="$out/bin/$id"
  mkdir -p "$bin"
  # A binary-only agent: install its archive for this platform (helper prints the folder to put on PATH, or nothing).
  extra=$(python3 -I "$here/scripts/acp_registry_install.py" "$registry" "$id" "$bin" 2>>"$log")
  path=$PATH
  [ -n "$extra" ] && path="$extra:$PATH"
  (cd "$here" && PATH="$path" ACP_CONFORMANCE_REGISTRY="$registry" ACP_CONFORMANCE_AGENT="$id" \
    timeout --kill-after=10 "$per_agent" \
    cargo test --locked -p acpmux --lib registry_live -- --ignored --nocapture) >>"$log" 2>&1
  echo "acp-exit $?" >>"$log"
  # After each agent, so a run cut short still leaves the agents it reached (the rest read "no run").
  matrix
done

matrix
# One line per row on stdout, so a CI log shows the matrix; exit 1 when any case failed.
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["rows"]:
    print("\t".join((r["agent"], r["version"], r["case"], r["result"], r["detail"])))
print("%d of %d cases failed at %s" % (d["failed_cases"], len(d["rows"]), d["commit"][:12]))
sys.exit(1 if d["failed_cases"] else 0)' "$out/matrix.json"
