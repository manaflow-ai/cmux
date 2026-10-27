#!/usr/bin/env bash
# A/B of ThinLTO and Swift cross-module optimization (CMO) for the cmux-next Release
# build, at one commit (p08-startup task 110; plans/cmux-next/startup-DESIGN.md section 9).
#
# Variants (all `reload.sh --config bench`: the Release configuration, -O whole module,
# plus -DCMUX_BENCH_HOOKS so the benches can drive the app):
#   base     the shipped flags
#   thinlto  LLVM_LTO=YES_THIN (C and the link) and Swift -lto=llvm-thin
#   cmo      Swift -cross-module-optimization
# Chrome ships its Mac official builds with ThinLTO (build/config/compiler/compiler.gni
# `use_thin_lto`, build/config/compiler/BUILD.gn `-flto=thin` and the `-cache_path_lto`
# link cache) and chooses such flags by A/B on the perf bots; this does the same for Swift.
#
# Each variant's flags come from an xcconfig named by XCODE_XCCONFIG_FILE, so reload.sh
# and the project stay unchanged. Every setting in it is `[config=Release]`, so a Debug
# build sees nothing; the Debug leaf-edit step proves it (no flag in the Debug log, the
# same Swift compile count as base). The Release log must show the variant's flags on
# the CmuxNext modules (and ThinLTO's on the app executable's own link command),
# otherwise the row says the flags were not applied.
#
# Per variant: clean build time, link time (the app's per-arch linker outputs and the
# LTO cache removed, one more build, and its Ld seconds from xcodebuild's Build Timing
# Summary), executable and __TEXT bytes, app size, cold and warm first frame
# (bench-startup.py, the variants interleaved run by run), typing key-to-frame p95
# (bench-typing.py, rounds interleaved), and the Debug leaf-edit rebuild time. Writes
# OUT/results.json and OUT/table.md, prints the table.
#
# Usage (a fleet step; the build modes refuse a laptop):
#   cmux-ci run --class isolated --script scripts/cmux-next/pgo/lto-ab.sh --ref SHA
#   lto-ab.sh [--out DIR] [--variants base,thinlto,cmo] [--runs N] [--typing-rounds N]
#             [--typing-samples N] [--leaf FILE] [--skip-runtime] [--skip-debug]
#   lto-ab.sh --print-xcconfig VARIANT   the variant's xcconfig (no build)
#   lto-ab.sh --table DIR                render DIR/table.md again from saved results (no build)
#   lto-ab.sh --check-flags VARIANT LOG EXE   applied|missing F|leaked F for a saved Release log
#   lto-ab.sh --link-seconds RELINK_LOG NOOP_LOG EXE   link seconds from saved logs (exit 1: why not)
#
# Exit: 0 every requested variant built with its flags, linked again, benched, and Debug
# is unchanged (with --skip-debug, Debug is not checked and no variant is adopted);
# 1 a variant failed, its flags were missing, the relink did not link the app, a bench
# failed, a Debug build failed, or Debug changed;
# 2 usage, or a build mode outside the fleet.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
known_variants=(base thinlto cmo)

usage() {
  sed -n '/^# Usage/,/^# 2 usage/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# The flags each variant adds. Release only, so Debug builds read the same settings.
# $(inherited) is Xcode's, not the shell's.
# shellcheck disable=SC2016
xcconfig_for() {
  case "$1" in
    base)
      printf '// lto-ab base: the shipped Release flags, nothing added.\n'
      ;;
    thinlto)
      printf '// lto-ab thinlto: ThinLTO for clang, Swift and the link (Release only).\n'
      printf 'LLVM_LTO[config=Release] = YES_THIN\n'
      printf 'OTHER_SWIFT_FLAGS[config=Release] = $(inherited) -lto=llvm-thin\n'
      ;;
    cmo)
      printf '// lto-ab cmo: Swift cross-module optimization (Release only).\n'
      printf 'OTHER_SWIFT_FLAGS[config=Release] = $(inherited) -cross-module-optimization\n'
      ;;
    *)
      echo "lto-ab: unknown variant '$1' (known: ${known_variants[*]})" >&2
      return 2
      ;;
  esac
}

# The flags a Release log must show for the variant: "swift:<flag>" on a CmuxNext module's
# compile, "link:<flag>" on the app executable's own link command.
expected_flags() {
  case "$1" in
    base) ;;
    thinlto) printf 'swift:-lto=llvm-thin\nlink:-flto=thin\n' ;;
    cmo) printf 'swift:-cross-module-optimization\n' ;;
  esac
}
all_flags=(-lto=llvm-thin -flto=thin -cross-module-optimization)

# The command lines under the per-arch `Ld .../Objects-normal/<arch>/Binary/EXE normal <arch>`
# headers in LOG: the app executable's link, not a clang compile that also says `-o`.
exe_link_commands() { # LOG EXE
  awk -v exe="$2" '
    /^Ld / { inld = index($0, "/Binary/" exe " normal ") > 0; next }
    /^$/ || /^[^ \t]/ { inld = 0; next }
    inld { print }
  ' "$1"
}

flag_hits() { # LOG KIND FLAG EXE: lines of that kind in LOG that carry FLAG
  local log=$1 kind=$2 flag=$3 exe=$4
  case "$kind" in
    swift) { grep -F -e '-module-name CmuxNext' "$log" || true; } | grep -c -F -e "$flag" || true ;;
    link) exe_link_commands "$log" "$exe" | grep -c -F -e "$flag" || true ;;
    any) grep -c -F -e "$flag" "$log" || true ;;
  esac
}

# applied, "missing FLAG" or "leaked FLAG" for VARIANT's Release LOG: base shows none of
# the flags, a variant shows each of its own where expected_flags says.
flags_verdict() { # VARIANT LOG EXE
  local variant=$1 log=$2 exe=$3 kind flag verdict=applied
  if [[ "$variant" == base ]]; then
    for flag in "${all_flags[@]}"; do
      [[ "$(flag_hits "$log" any "$flag" "$exe")" == 0 ]] || verdict="leaked $flag"
    done
  else
    while IFS=: read -r kind flag; do
      [[ "$(flag_hits "$log" "$kind" "$flag" "$exe")" != 0 ]] || verdict="missing $flag"
    done < <(expected_flags "$variant")
  fi
  printf '%s\n' "$verdict"
}

exe_ld_tasks() { # LOG EXE: the number of `Ld .../Binary/EXE normal <arch>` tasks in LOG
  awk -v exe="$2" '/^Ld / && index($0, "/Binary/" exe " normal ") { n++ } END { print n + 0 }' "$1"
}

ld_summary_seconds() { # LOG: the Ld row of xcodebuild's Build Timing Summary, 0 without one
  awk '
    /^Build Timing Summary$/ { s = 1; next }
    s && /^Ld[ (]/ && $NF == "seconds" { v = $(NF - 1) }
    END { print (v == "" ? 0 : v) }' "$1"
}

# The app executable's link seconds: the relink's Ld task seconds (xcodebuild
# -showBuildTimingSummary, summed over the per-arch links) minus the no-op build's, so a
# target that links on every build cancels out. The relink must have linked EXE and the
# no-op must not have; otherwise prints why and returns 1.
link_seconds() { # RELINK_LOG NOOP_LOG EXE
  local relink=$1 noop=$2 exe=$3
  if ! grep -q '^Build Timing Summary$' "$relink" || ! grep -q '^Build Timing Summary$' "$noop"; then
    echo "a Build Timing Summary is missing from the no-op or relink log"
  elif [[ "$(exe_ld_tasks "$relink" "$exe")" == 0 ]]; then
    echo "the relink ran no Ld for $exe"
  elif [[ "$(exe_ld_tasks "$noop" "$exe")" != 0 ]]; then
    echo "the no-op build linked $exe too, so the relink measures nothing"
  else
    /usr/bin/env python3 -c 'import sys; print(f"{max(0.0, float(sys.argv[1]) - float(sys.argv[2])):.3f}")' \
      "$(ld_summary_seconds "$relink")" "$(ld_summary_seconds "$noop")"
    return 0
  fi
  return 1
}

summarize() {
  /usr/bin/env python3 -I - "$1" "$repo_root/scripts/perf-lab/perf_stats.py" <<'PY'
import importlib.util, json, os, statistics, sys

out, stats_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("perf_stats", stats_path)
perf_stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf_stats)

FIRST_FRAME = "first_window_frame_committed"
WIN_PCT = -3.0      # a first-frame p50 this much faster (and Pinpoint DIFFERENT) is a win
TYPING_PCT = 2.0    # a typing p95 more than this much slower is a regression

facts = {}
with open(os.path.join(out, "facts.tsv")) as f:
    for line in f:
        variant, key, value = line.rstrip("\n").split("\t", 2)
        facts.setdefault(variant, {})[key] = value
with open(os.path.join(out, "variants.txt")) as f:
    variants = f.read().split()
runtime = os.path.exists(os.path.join(out, "startup.json"))
startup = json.load(open(os.path.join(out, "startup.json"))) if runtime else {}


def num(variant, key):
    try:
        return float(facts.get(variant, {})[key])
    except (KeyError, ValueError):
        return None


def frames(variant, mode):
    runs = startup.get(f"ltoab-{variant}", {}).get(mode, [])
    return [r[FIRST_FRAME] for r in runs if isinstance(r.get(FIRST_FRAME), (int, float))]


def typing_p95(variant):
    """The median over rounds of each round's single-phase key_to_frame_ms p95."""
    root = os.path.join(out, "typing")
    values = []
    for name in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        if not name.startswith(variant + "-"):
            continue
        try:
            report = json.load(open(os.path.join(root, name, "report.json")))
            p95 = report["phases"]["single"]["stats"]["key_to_frame_ms"]["p95"]
        except (OSError, KeyError, TypeError, ValueError):
            continue
        if isinstance(p95, (int, float)):
            values.append(p95)
    return statistics.median(values) if values else None


def pct(new, old):
    return None if new is None or not old else (new - old) / old * 100.0


rows, problems = {}, []
for v in variants:
    row = {k: num(v, k) for k in ("build_s", "link_s", "exe_bytes", "text_bytes", "app_kb",
                                  "debug_leaf_s", "debug_swift_compiles", "debug_flag_hits")}
    row["status"] = facts.get(v, {}).get("status", "missing")
    row["flags"] = facts.get(v, {}).get("flags", "unchecked")
    for mode in ("cold", "warm"):
        samples = frames(v, mode)
        row[f"{mode}_samples"] = samples
        s = perf_stats.summary(samples)
        row[f"{mode}_p50"], row[f"{mode}_p95"], row[f"{mode}_n"] = s["p50"], s["p95"], s["n"]
    row["typing_p95"] = typing_p95(v)
    rows[v] = row
    if row["status"] != "ok":
        problems.append(f"{v}: build {row['status']}")
    elif row["flags"] != "applied":
        problems.append(f"{v}: flags {row['flags']}")
    elif row["link_s"] is None:
        problems.append(f"{v}: link time missing ({facts.get(v, {}).get('link_problem', 'no relink fact')})")
    if runtime and row["status"] == "ok" and (not row["cold_n"] or not row["warm_n"] or row["typing_p95"] is None):
        problems.append(f"{v}: bench samples missing")

base = rows.get("base")
# Debug is checked unless the run says --skip-debug; a failed or missing Debug step is a
# problem, never "unchanged".
run_facts = facts.get("run", {})
debug_skipped = run_facts.get("debug") == "skipped"
debug_ok = {}
if not debug_skipped:
    if "debug_failed" in run_facts:
        problems.append(f"Debug: {run_facts['debug_failed']}")
    for v, row in rows.items():
        failed = facts.get(v, {}).get("debug_failed")
        if failed:
            problems.append(f"{v}: Debug: {failed}")
        elif not run_facts.get("debug_failed") and (row["debug_leaf_s"] is None or row["debug_swift_compiles"] is None
                                                     or row["debug_flag_hits"] is None):
            problems.append(f"{v}: Debug leaf-edit numbers missing")
        debug_ok[v] = not failed and None not in (row["debug_leaf_s"], row["debug_swift_compiles"], row["debug_flag_hits"])
for v, row in rows.items():
    verdict = []
    if base is None or v == "base":
        row["verdict"] = "reference" if v == "base" else "no base"
        continue
    if debug_skipped:
        row["debug_unchanged"] = None
    elif debug_ok.get(v) and debug_ok.get("base"):
        same = row["debug_flag_hits"] == 0 and row["debug_swift_compiles"] == base["debug_swift_compiles"]
        row["debug_unchanged"] = same
        if not same:
            problems.append(f"{v}: Debug changed (flag hits {row['debug_flag_hits']}, Swift compiles "
                            f"{row['debug_swift_compiles']} vs base {base['debug_swift_compiles']})")
    else:
        row["debug_unchanged"] = None
    for mode in ("cold", "warm"):
        change = pct(row[f"{mode}_p50"], base[f"{mode}_p50"])
        row[f"{mode}_change_pct"] = change
        a, b = base[f"{mode}_samples"], row[f"{mode}_samples"]
        row[f"{mode}_pinpoint"] = perf_stats.compare(a, b).floored.result if a and b else None
    row["typing_change_pct"] = pct(row["typing_p95"], base["typing_p95"])
    if row["status"] != "ok" or row["flags"] != "applied":
        row["verdict"] = "incomplete"
        continue
    if not runtime:
        row["verdict"] = "no runtime numbers"
        continue
    wins = [m for m in ("cold", "warm") if row[f"{m}_change_pct"] is not None
            and row[f"{m}_change_pct"] <= WIN_PCT and row[f"{m}_pinpoint"] == perf_stats.DIFFERENT]
    losses = [m for m in ("cold", "warm") if row[f"{m}_change_pct"] is not None
              and row[f"{m}_change_pct"] > 0 and row[f"{m}_pinpoint"] == perf_stats.DIFFERENT]
    typing_bad = row["typing_change_pct"] is None or row["typing_change_pct"] > TYPING_PCT
    if losses:
        verdict.append("slower " + "/".join(losses) + " first frame")
    if typing_bad:
        verdict.append("typing p95 regressed or missing")
    if debug_skipped:
        verdict.append("Debug not checked (--skip-debug)")
    elif row["debug_unchanged"] is None:
        verdict.append("Debug not checked (a Debug build failed or gave no numbers)")
    elif not row["debug_unchanged"]:
        verdict.append("Debug changed")
    if verdict:
        row["verdict"] = "keep base: " + ", ".join(verdict)
    elif wins:
        row["verdict"] = "adopt (" + "/".join(wins) + " first frame faster)"
    else:
        row["verdict"] = "keep base: no first-frame win"


def cell(value, fmt="{:.0f}", change=None):
    if value is None:
        return "-"
    text = fmt.format(value)
    if change is not None:
        text += f" ({change:+.1f} %)"
    return text


header = ["variant", "build", "flags", "build s", "link s", "exe MB", "__TEXT MB", "app MB",
          "cold first frame p50/p95 ms", "warm first frame p50/p95 ms", "typing key-to-frame p95 ms",
          "Debug leaf-edit s", "verdict"]
lines = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
for v, r in rows.items():
    mb = lambda x: None if x is None else x / 1e6
    chg = lambda key: None if v == "base" or base is None else pct(r[key], base[key])
    debug = cell(r["debug_leaf_s"], "{:.1f}") + {True: " same", False: " CHANGED"}.get(r.get("debug_unchanged"), "")
    frame = lambda m: (cell(r[f"{m}_p50"], change=r.get(f"{m}_change_pct")) + " / " + cell(r[f"{m}_p95"])
                       + (f" n={r[f'{m}_n']}" if r[f"{m}_n"] else ""))
    lines.append("| " + " | ".join([
        v, r["status"], r["flags"], cell(r["build_s"], change=chg("build_s")),
        cell(r["link_s"], "{:.1f}", chg("link_s")),
        cell(mb(r["exe_bytes"]), "{:.1f}", chg("exe_bytes")), cell(mb(r["text_bytes"]), "{:.1f}", chg("text_bytes")),
        cell(None if r["app_kb"] is None else r["app_kb"] / 1024, "{:.0f}", chg("app_kb")),
        frame("cold"), frame("warm"),
        cell(r["typing_p95"], "{:.2f}", r.get("typing_change_pct")),
        debug, r["verdict"]]) + " |")
context = {k: facts.get("run", {}).get(k, "-") for k in ("sha", "xcode", "host", "cold")}
table = (f"Commit `{context['sha']}`, {context['xcode']}, host {context['host']}, cold launches: {context['cold']}.\n\n"
         + "\n".join(lines) + "\n")
with open(os.path.join(out, "table.md"), "w") as f:
    f.write(table)
for r in rows.values():
    r.pop("cold_samples", None), r.pop("warm_samples", None)
with open(os.path.join(out, "results.json"), "w") as f:
    json.dump({"context": context, "variants": rows, "problems": problems}, f, indent=1)
print(table)
for p in problems:
    print(f"lto-ab: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
}

out=""
variants_arg="base,thinlto,cmo"
runs=10
typing_rounds=3
typing_samples=200
leaf="Packages/macOS/CmuxNext/Sources/CmuxNextApp/ActionScope.swift"
skip_runtime=0
skip_debug=0
while (( $# )); do
  case "$1" in
    --print-xcconfig) [[ $# -ge 2 ]] || usage; xcconfig_for "$2"; exit $? ;;
    --table) [[ $# -ge 2 ]] || usage; summarize "$2"; exit $? ;;
    --check-flags) [[ $# -ge 4 ]] || usage; flags_verdict "$2" "$3" "$4"; exit 0 ;;
    --link-seconds) [[ $# -ge 4 ]] || usage; link_seconds "$2" "$3" "$4"; exit $? ;;
    --out) [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
    --variants) [[ $# -ge 2 ]] || usage; variants_arg="$2"; shift 2 ;;
    --runs) [[ $# -ge 2 ]] || usage; runs="$2"; shift 2 ;;
    --typing-rounds) [[ $# -ge 2 ]] || usage; typing_rounds="$2"; shift 2 ;;
    --typing-samples) [[ $# -ge 2 ]] || usage; typing_samples="$2"; shift 2 ;;
    --leaf) [[ $# -ge 2 ]] || usage; leaf="$2"; shift 2 ;;
    --skip-runtime) skip_runtime=1; shift ;;
    --skip-debug) skip_debug=1; shift ;;
    -h|--help) usage ;;
    *) echo "lto-ab: unknown argument '$1'" >&2; usage ;;
  esac
done
for n in "$runs" "$typing_rounds" "$typing_samples"; do
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "lto-ab: counts must be positive integers, got '$n'" >&2; exit 2; }
done
IFS=, read -r -a variants <<<"$variants_arg"
[[ " ${variants[*]} " == *" base "* ]] || { echo "lto-ab: --variants must include base (the reference)" >&2; exit 2; }
for v in "${variants[@]}"; do xcconfig_for "$v" >/dev/null || exit 2; done

# Builds the app with xcodebuild and launches it: fleet only.
# shellcheck source-path=SCRIPTDIR source=../lib/fleet-only.sh
source "$here/../lib/fleet-only.sh"
cmux_next_require_fleet lto-ab.sh "three Release builds, a Debug build and launch benches" "none (manual fleet A/B)" \
  "cmux-ci run --class isolated --script scripts/cmux-next/pgo/lto-ab.sh --ref SHA"

cd "$repo_root"
sha="$(git rev-parse HEAD)"
out="${out:-$repo_root/artifacts/lto-ab/$sha}"
mkdir -p "$out/logs" "$out/xcconfig" "$out/typing"
out="$(cd "$out" && pwd)"
dd_root="$out/dd"
: >"$out/facts.tsv"
printf '%s\n' "${variants[@]}" >"$out/variants.txt"

fact() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$out/facts.tsv"; }
now() { /usr/bin/env python3 -c 'import time; print(f"{time.time():.3f}")'; }
since() { /usr/bin/env python3 -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.3f}")' "$1" "$(now)"; }

for v in "${variants[@]}"; do xcconfig_for "$v" >"$out/xcconfig/$v.xcconfig"; done
fact run sha "$sha"
fact run xcode "$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
fact run host "$(scutil --get LocalHostName 2>/dev/null || hostname -s)"

# One reload into the variant's own DerivedData; the elapsed seconds land in $elapsed and
# the reload log in OUT/logs/STEP.log. TIMING=1 adds xcodebuild's Build Timing Summary.
# Returns reload's status.
elapsed=""
reload_step() { # STEP VARIANT CONFIG TAG DD [TIMING]
  local step=$1 variant=$2 config=$3 tag=$4 dd=$5 timing=${6:-0} t0 rc=0
  t0="$(now)"
  XCODE_XCCONFIG_FILE="$out/xcconfig/$variant.xcconfig" CMUX_DEV_BACKEND_MODE=local \
    CMUX_RELOAD_BUILD_TIMING_SUMMARY="$timing" \
    "$repo_root/scripts/reload.sh" --tag "$tag" --config "$config" --derived-data "$dd" --no-global-cli-links \
    >"$out/logs/$step.out" 2>&1 || rc=$?
  elapsed="$(since "$t0")"
  cp "/tmp/cmux-reload-$tag.log" "$out/logs/$step.log" 2>/dev/null || : >"$out/logs/$step.log"
  echo "lto-ab: $step: exit $rc in ${elapsed}s" >&2
  return "$rc"
}

apps=()
for v in "${variants[@]}"; do
  tag="ltoab-$v"
  dd="$dd_root/$v"
  rm -rf "$dd"
  if ! reload_step "release-$v" "$v" bench "$tag" "$dd"; then
    fact "$v" status failed
    continue
  fi
  fact "$v" build_s "$elapsed"
  app="$dd/Build/Products/Release/cmux DEV $tag.app"
  if [[ ! -d "$app" ]]; then
    echo "lto-ab: $v: no tagged app at $app" >&2
    fact "$v" status "no app"
    continue
  fi
  exe_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  exe="$app/Contents/MacOS/$exe_name"

  flags="$(flags_verdict "$v" "$out/logs/release-$v.log" "$exe_name")"
  fact "$v" flags "$flags"

  fact "$v" exe_bytes "$(stat -f %z "$exe")"
  fact "$v" text_bytes "$(size "$exe" | awk 'NR == 2 { print $1 }')"
  fact "$v" app_kb "$(du -sk "$app" | awk '{ print $1 }')"

  # Link time: a no-op rebuild, then the app's per-arch linker outputs and the LTO cache
  # removed so Ld must run, and one more build; both with the Build Timing Summary.
  # reload.sh replaces the product bundle on every build, so lipo, bundling and signing
  # run in both and only Ld differs.
  if reload_step "noop-$v" "$v" bench "$tag" "$dd" 1; then
    removed="$(find "$dd/Build/Intermediates.noindex" -type f -path "*/Objects-normal/*/Binary/$exe_name" -print -delete | wc -l | tr -d ' ')"
    find "$dd/Build/Intermediates.noindex" -type d -iname '*lto*cache*' -prune -exec rm -rf {} + 2>/dev/null || true
    if [[ "$removed" == 0 ]]; then
      fact "$v" link_problem "no per-arch Objects-normal/*/Binary/$exe_name to remove"
    elif reload_step "relink-$v" "$v" bench "$tag" "$dd" 1; then
      if link="$(link_seconds "$out/logs/relink-$v.log" "$out/logs/noop-$v.log" "$exe_name")"; then
        fact "$v" link_s "$link"
      else
        fact "$v" link_problem "$link"
      fi
    else
      fact "$v" link_problem "the relink build failed"
    fi
  else
    fact "$v" link_problem "the no-op build failed"
  fi
  fact "$v" status ok
  apps+=("$app")
done

# Debug: one cold build, a warm-up leaf edit, then one leaf edit per variant with that
# variant's xcconfig. Release-only settings leave the Debug build description as it was.
# A failed Debug step is a fact too, so the summary never reads it as "Debug unchanged".
if (( skip_debug )); then
  fact run debug skipped
else
  fact run debug ran
  leaf_backup="$(mktemp "${TMPDIR:-/tmp}/lto-ab-leaf.XXXXXX")"
  cp "$leaf" "$leaf_backup"
  trap 'cp "$leaf_backup" "$leaf"; rm -f "$leaf_backup"' EXIT
  debug_dd="$dd_root/debug"
  rm -rf "$debug_dd"
  if reload_step debug-cold base debug ltoab-debug "$debug_dd"; then
    printf '\n// lto-ab leaf edit warmup\n' >>"$leaf"
    reload_step debug-leaf-warmup base debug ltoab-debug "$debug_dd" || true
    for v in "${variants[@]}"; do
      printf '\n// lto-ab leaf edit %s\n' "$v" >>"$leaf"
      if reload_step "debug-leaf-$v" "$v" debug ltoab-debug "$debug_dd"; then
        fact "$v" debug_leaf_s "$elapsed"
        fact "$v" debug_swift_compiles "$(grep -c '^SwiftCompile ' "$out/logs/debug-leaf-$v.log" || true)"
        hits=0
        for flag in "${all_flags[@]}"; do
          hits=$(( hits + $(flag_hits "$out/logs/debug-leaf-$v.log" any "$flag" "") ))
        done
        fact "$v" debug_flag_hits "$hits"
      else
        fact "$v" debug_failed "debug-leaf-$v build failed (logs/debug-leaf-$v.out)"
      fi
    done
  else
    fact run debug_failed "debug-cold build failed (logs/debug-cold.out)"
  fi
fi

if (( ! skip_runtime )) && (( ${#apps[@]} )); then
  bench_apps=()
  for app in "${apps[@]}"; do bench_apps+=(--app "$app"); done
  purge=()
  if sudo -n -l /usr/sbin/purge >/dev/null 2>&1; then
    purge=(--purge)
    fact run cold "purged"
  else
    fact run cold "daemon stopped, file cache not purged (no sudo purge right)"
  fi
  /usr/bin/env python3 "$repo_root/scripts/cmux-next/bench-startup.py" "${bench_apps[@]}" \
    --mode cold --mode warm --runs "$runs" ${purge[@]+"${purge[@]}"} --json "$out/startup.json" \
    >"$out/logs/bench-startup.out" 2>&1 || echo "lto-ab: bench-startup failed (logs/bench-startup.out)" >&2
  [[ -f "$out/startup.json" ]] || echo '{}' >"$out/startup.json"
  for (( round = 1; round <= typing_rounds; round++ )); do
    for app in "${apps[@]}"; do
      name="$(basename "$app" .app)"
      tag="${name#cmux DEV }"
      /usr/bin/env python3 "$repo_root/scripts/cmux-next/bench-typing.py" --tag "$tag" --app "$app" \
        --samples "$typing_samples" --out "$out/typing/${tag#ltoab-}-$round" \
        >"$out/logs/typing-$tag-$round.out" 2>&1 || echo "lto-ab: bench-typing $tag round $round failed" >&2
    done
  done
fi

summarize "$out"
