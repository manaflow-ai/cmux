#!/usr/bin/env bash
# Publish an already captured matrix using the runner's shared tailnet deploy path.
# With --pr, the same exact files are also posted to HQ through feed-post. The
# feed call is opt-in because CI cannot reach the tailnet feed server.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/gallery-deploy.sh --matrix RUN OUTPUT_DIR [--pr PR_URL]

Optional feed publication (requires --pr):
  --feed-post PATH     feed-post executable (or set CMUX_FEED_POST)
  --head SHA           exact source head (defaults to the current git HEAD)
  --source REPO        source repository (default: manaflow-ai/cmux)
  --preview URL        stable gallery preview (defaults to the matrix URL)
EOF
}

run=""
output_dir=""
pr=""
feed_post="${CMUX_FEED_POST:-}"
head="${CMUX_GALLERY_HEAD:-}"
source_repo="${CMUX_GALLERY_SOURCE:-manaflow-ai/cmux}"
preview=""

while (($#)); do
  case "$1" in
    --matrix)
      [[ $# -ge 3 ]] || { usage; exit 2; }
      run="$2"
      output_dir="$3"
      shift 3
      ;;
    --pr)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      pr="$2"
      shift 2
      ;;
    --feed-post)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      feed_post="$2"
      shift 2
      ;;
    --head)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      head="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      source_repo="$2"
      shift 2
      ;;
    --preview)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      preview="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$run" && -n "$output_dir" ]] || { usage; exit 2; }
[[ -f "$output_dir/index.html" && -f "$output_dir/results.json" ]] || {
  echo "Matrix output must contain index.html and results.json" >&2
  exit 1
}
[[ "$run" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "RUN must contain only letters, numbers, '.', '_' or '-'" >&2
  exit 2
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
matrix_url="$(bun --eval 'const { publishRun } = await import(process.argv[1]); console.log(publishRun(process.argv[2], process.argv[3]));' \
  "$script_dir/gallery-matrix/runner.ts" "$output_dir" "$run")"
echo "matrix: $matrix_url"

if [[ -z "$pr" ]]; then
  exit 0
fi

if [[ -z "$feed_post" || ! -x "$feed_post" ]]; then
  echo "--pr requires an executable feed-post; pass --feed-post or set CMUX_FEED_POST" >&2
  exit 1
fi

if [[ -z "$head" ]]; then
  head="$(git rev-parse HEAD 2>/dev/null || true)"
fi
[[ "$head" =~ ^[0-9a-fA-F]{40}$ ]] || {
  echo "--pr requires an exact 40-character --head (or a git checkout)" >&2
  exit 1
}

evidence_json="$(python3 - "$source_repo" "$head" "$run" <<'PY'
import json
import sys
source, head, run = sys.argv[1:]
print(json.dumps({
    "source": source,
    "head": head,
    "receipt_id": f"gallery-{run}-{head[:12]}",
}, separators=(",", ":")))
PY
)"

feed_args=(
  --pr "$pr"
  --preview "${preview:-$matrix_url}"
  --diff "$matrix_url"
  --matrix "$matrix_url"
  --build "$matrix_url"
  --evidence-json "$evidence_json"
)
for name in index.html results.json; do
  feed_args+=(--artifact "$output_dir/$name=${matrix_url}${name}")
done

echo "feed-post: $pr (head ${head:0:12}; artifacts index.html, results.json)"
"$feed_post" "${feed_args[@]}"
