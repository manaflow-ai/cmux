#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "usage: $0 <before-list> <after-list> <workflow> <job> <branch-ref> <evidence-directory>" >&2
  exit 64
fi

before_list="$1"
after_list="$2"
workflow="$3"
job="$4"
branch_ref="$5"
evidence_dir="$6"
for path in "$before_list" "$after_list"; do
  if [[ ! -f "$path" ]]; then
    echo "inventory file is missing: $path" >&2
    exit 65
  fi
done
mkdir -p "$evidence_dir"
decision_log="$evidence_dir/warmup-recovery.log"

set +e
candidate="$(python3 - "$before_list" "$after_list" "$workflow" "$job" "$branch_ref" <<'PY'
import re
import sys

before_path, after_path, workflow, job, branch_ref = sys.argv[1:]
id_pattern = re.compile(r"tbx_[A-Za-z0-9_-]+$")

def matching(path):
    result = set()
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            fields = line.split()
            # list --all is a whitespace table: ID STATUS IP WORKFLOW JOB REF ...
            if len(fields) >= 6 and id_pattern.fullmatch(fields[0]):
                if fields[3] == workflow and fields[4] == job and fields[5] == branch_ref:
                    result.add(fields[0])
    return result

before = matching(before_path)
after = matching(after_path)
new = sorted(after - before)
if len(new) != 1:
    print(
        f"warmup recovery found {len(new)} uniquely matching new Testbox IDs "
        f"(before={sorted(before)}, after={sorted(after)})",
        file=sys.stderr,
    )
    raise SystemExit(1)
print(new[0])
PY
)"
parse_status=$?
set -e
if (( parse_status != 0 )); then
  {
    echo "No Testbox was stopped: warmup recovery was ambiguous or had no matching new ID."
    echo "before=$before_list"
    echo "after=$after_list"
  } >"$decision_log"
  cat "$decision_log" >&2
  exit "$parse_status"
fi

printf 'warmup recovery selected uniquely new Testbox %s\n' "$candidate" | tee "$decision_log"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/blacksmith-testbox-cleanup.sh" "$candidate" "$evidence_dir"
