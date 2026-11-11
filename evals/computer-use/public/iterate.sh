#!/bin/bash
# iterate.sh NAME [extra macos_bench.py run args]: one full iteration on this
# host, both public macOS suites, both arms, 2 VMs at a time. Resumable: run it
# again with the same NAME to finish missing attempts.
set -uo pipefail
name=$1; shift
here=$(cd "$(dirname "$0")" && pwd)
export PATH=$HOME/cu-bench/bin:/opt/homebrew/bin:$PATH
py=$HOME/cu-bench/venv/bin/python
out=$HOME/cu-bench/runs/$name
mkdir -p "$out"
"$py" -u "$here/macos_bench.py" run --suite macosworld --mow "$HOME/cu-bench/macosworld" \
  --jobs ${CUBENCH_JOBS:-2} --timeout 900 --screenshot --out "$out/macosworld" "$@"
"$py" -u "$here/macos_bench.py" run --suite macagentbench --mab "$HOME/cu-bench/MacAgentBench" \
  --jobs ${CUBENCH_JOBS:-2} --timeout 900 --screenshot --out "$out/macagentbench" "$@"
"$py" "$here/macos_bench.py" report --out "$out/macosworld,$out/macagentbench"
echo "iteration $name finished"
