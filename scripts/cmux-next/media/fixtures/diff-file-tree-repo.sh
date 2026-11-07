#!/usr/bin/env bash
# A git repository with the uncommitted diff of the files-tree report (Nov 4, "lots of buggy stuff
# here"): edits to tracked files in docs/, src/ and src/server/, an added file in test/workers/, and
# new files in src/server/machines/, src/server/mcp/, test/fixtures/ and test/node/, so the diff
# lists tracked edits before the new files in the same folders. tours/diff-file-tree.json opens it.
# usage: diff-file-tree-repo.sh DIR   (DIR is replaced)
set -euo pipefail
dir=${1:?usage: diff-file-tree-repo.sh DIR}
rm -rf "$dir"
mkdir -p "$dir"
cd "$dir"
git init -q
lines() { for i in $(seq 1 "$1"); do echo "line $i of $2"; done; }
drop_first() { tail -n +"$(($2 + 1))" "$1" >"$1.tmp" && mv "$1.tmp" "$1"; }
mkdir -p docs src/server test/workers
lines 40 hosted >docs/hosted-mcp.md
lines 20 plan >docs/port-cloud-worker-plan.md
lines 5 llms >llms.txt
lines 60 mcp >src/server/Mcp.ts
lines 50 worker >src/worker.ts
git add -A
git -c user.email=tour@cmux.dev -c user.name=tour commit -qm base
drop_first docs/hosted-mcp.md 1 && lines 320 added >>docs/hosted-mcp.md
drop_first docs/port-cloud-worker-plan.md 1 && lines 6 added >>docs/port-cloud-worker-plan.md
drop_first llms.txt 1
drop_first src/server/Mcp.ts 9 && lines 82 added >>src/server/Mcp.ts
drop_first src/worker.ts 3 && lines 68 added >>src/worker.ts
mkdir -p src/server/machines src/server/mcp test/fixtures test/node
lines 25 test >test/workers/worker.test.ts
git add -N test/workers/worker.test.ts
lines 256 new >src/server/machines/CapabilityDescriptor.ts
lines 320 new >src/server/machines/E2b.ts
lines 316 new >src/server/mcp/MachineTools.ts
lines 588 new >src/server/mcp/SessionPromptLimits.ts
lines 335 new >src/server/mcp/SessionTools.ts
lines 54 new >test/fixtures/mcp-prompt-grants.ts
for name in machines-e2b mcp-machines mcp-session-prompts mcp-sessions mcp-team-bindings; do
  lines 300 new >"test/node/$name.test.ts"
done
