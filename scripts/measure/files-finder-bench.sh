#!/usr/bin/env bash
# Finder vs the cmux Files pane: folder open and name search, 10k and 100k files
# (plans/cmux-next/files-finder-parity-DESIGN.md, 4.3). Runs on a fleet Mac mini, never on a laptop:
#   cmux-ci run --class exclusive --script scripts/measure/files-finder-bench.sh --ref <sha>
# Finder's search field is a Spotlight query, so `mdfind -onlyin DIR -name Q` times the engine
# under Finder's search without its UI (a lower bound for Finder). Finder's folder open is timed
# through Apple Events (`count items`), which runs Finder's own enumeration; that needs a GUI
# session with Automation allowed, else the row says n/a.
set -euo pipefail
RUNS="${CMUX_FILES_BENCH_RUNS:-7}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/files-bench-build.XXXXXX")"
# Spotlight skips /tmp: the corpus lives under $HOME so Finder's search can see it.
corpus="$HOME/cmux-files-bench-$$"
cleanup() { rm -rf "$corpus" "$work"; }
trap cleanup EXIT

echo "== build (swiftc -O, CmuxNextFiles sources)"
swiftc -O -swift-version 6 -module-name FilesBench -o "$work/files-finder-bench" \
  "$repo"/Packages/macOS/CmuxNext/Sources/CmuxNextFiles/*.swift \
  "$repo/scripts/measure/files-finder-bench/main.swift"

echo "== corpus in $corpus"
/usr/bin/python3 - "$corpus" <<'PY'
import os, sys
root = sys.argv[1]
kinds = ["report-{}.txt", "IMG_{:05d}.jpg", "notes {}.md", "invoice_{}.pdf", "build-log-{}.log",
         "component{}.tsx", "Screenshot {}.png", "draft {}.docx", "data-{}.json", "song {}.mp3"]
def make(base, total, per_dir):
    for i in range(total):
        d = os.path.join(base, f"dir{i // per_dir:03d}", f"sub{(i // 100) % 10}") if per_dir else base
        os.makedirs(d, exist_ok=True)
        name = kinds[i % len(kinds)].format(i)
        if i % 9973 == 0: name = f"needle-quasar-{i}.txt"
        open(os.path.join(d, name), "w").close()
make(os.path.join(root, "flat10k"), 10_000, 0)
make(os.path.join(root, "flat100k"), 100_000, 0)
make(os.path.join(root, "tree10k"), 10_000, 1000)
make(os.path.join(root, "tree100k"), 100_000, 1000)
PY

echo "== waiting for Spotlight to index the corpus (up to 15 min)"
spotlight="ok"
for _ in $(seq 1 180); do
  n="$(mdfind -onlyin "$corpus/tree100k" -count 'kMDItemFSName == "*"' 2>/dev/null || echo 0)"
  [[ "$n" -ge 100000 ]] && break
  sleep 5
done
n="$(mdfind -onlyin "$corpus/tree100k" -count 'kMDItemFSName == "*"' 2>/dev/null || echo 0)"
echo "spotlight indexed tree100k items: $n"
[[ "$n" -ge 100000 ]] || spotlight="partial ($n of ~101100)"

timeit() { # median and p90 ms of a command, RUNS times
  /usr/bin/python3 - "$RUNS" "$@" <<'PY'
import subprocess, sys, time
runs = int(sys.argv[1]); cmd = sys.argv[2:]; times = []; out = ""
for _ in range(runs):
    t = time.perf_counter(); r = subprocess.run(cmd, capture_output=True, text=True); times.append((time.perf_counter() - t) * 1000)
    if r.returncode != 0: print(f"failed rc={r.returncode} {r.stderr.strip()[:200]}"); sys.exit(0)
    out = r.stdout.strip()
times.sort()
print(f"median_ms={times[len(times)//2]:.1f} p90_ms={times[min(len(times)-1, int(len(times)*0.9))]:.1f} out={out[:60]!r}")
PY
}

echo "== folder open"
for f in flat10k flat100k; do
  echo "finder count-items $f $(timeit osascript -e "tell application \"Finder\" to count items of folder (POSIX file \"$corpus/$f\" as alias)")"
  "$work/files-finder-bench" "$RUNS" list "$corpus/$f"
done

echo "== name search (spotlight: $spotlight)"
for t in tree10k tree100k; do
  for q in quasar report screenshot; do
    echo "spotlight mdfind-name $t q=$q $(timeit mdfind -onlyin "$corpus/$t" -count -name "$q")"
  done
  "$work/files-finder-bench" "$RUNS" index "$corpus/$t" quasar report screenshot
done
echo "== host: $(hostname -s) $(sw_vers -productVersion) $(sysctl -n machdep.cpu.brand_string) load: $(sysctl -n vm.loadavg)"
