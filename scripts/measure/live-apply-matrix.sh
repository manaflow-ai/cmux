#!/usr/bin/env bash
# Live code correctness matrix (manaflow-ai/cmuxterm-hq#7111, track 3): for each row, one seeded
# minimal change is applied two ways to the same tree, and the pixels are compared.
#   - prebuilt + patch: the seeded base's Debug view shell (built once, the "prebuilt"), running
#     headless, takes the change through Prototypes/ViewShell/inject.sh;
#   - full build: the changed tree built from scratch into its own folder and drawn fresh.
# A row is `match` when both draw the badge at the same width, `refused` or `inject_failed` when
# the patch path detects it and falls back, and `MISMATCH` when the patch applied but drew other
# pixels than the full build (a silent wrong result). Each row's change moves one mechanism's term
# from 0 to 16 pt, so the badge is 64 px wider at 2x when the new code runs and unchanged when the
# old code still runs.
#   scripts/measure/live-apply-matrix.sh OUT [ROW...]   (OUT: logs, PNGs, diffs, rows.jsonl, result.json)
# LIVE_APPLY_MATRIX_DIFFS_ONLY=1 writes each row's change.diff and stops: no build, any host.
set -euo pipefail
out="${1:?usage: live-apply-matrix.sh OUT [ROW...]}"; shift
mkdir -p "$out"; out="$(cd "$out" && pwd)"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package="$root/Prototypes/ViewShell"
src="$package/Sources/ViewShell"
fixture="$src/MatrixFixture.swift"
badge="$src/Badge.swift"
main_swift="$src/main.swift"
if [[ -e "$fixture" || -L "$fixture" ]]; then
  echo "live-apply-matrix: $fixture already exists; this measurement writes and deletes it" >&2; exit 1
fi
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
# Base provenance: the commit every row's prebuilt and full build come from, and a clean view shell
# at that commit (an edited source would make the "base" something other than the commit).
base_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ "$base_sha" == unknown ]]; then
  echo "live-apply-matrix: $root is not a git checkout; the base commit cannot be checked" >&2; exit 1
fi
if [[ -n "$(git -C "$root" status --porcelain -- Prototypes/ViewShell)" ]]; then
  echo "live-apply-matrix: Prototypes/ViewShell differs from $base_sha; refusing to call that the base" >&2
  git -C "$root" status --porcelain -- Prototypes/ViewShell >&2; exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/live-apply-matrix.XXXXXX")"
mkdir -p "$work/orig"
cp "$badge" "$main_swift" "$work/orig/"
shell=""
restore_all() {
  [[ -n "$shell" ]] && kill "$shell" 2>/dev/null || true
  cp "$work/orig/Badge.swift" "$badge"; cp "$work/orig/main.swift" "$main_swift"
  rm -f "$fixture"
  rm -rf "$work"
}
trap restore_all EXIT

# The seeded base: one fixture file, one term per mechanism, all 0; the badge's padding adds them.
cat >"$work/MatrixFixture.swift" <<'SWIFT'
import AppKit
import SwiftUI

// Written by scripts/measure/live-apply-matrix.sh and removed when it ends. Each declaration is
// one row's mechanism; a row's change makes its term 16.
func matrixPad() -> CGFloat {
    0 // pad
}

struct MatrixBox {
    var a: CGFloat = 0
    func total() -> CGFloat {
        a // box
    }
}

final class MatrixFinal {
    var a: CGFloat = 0
    func total() -> CGFloat {
        a // final
    }
}

class MatrixBase {
    func extra() -> CGFloat {
        0 // base
    }
}

final class MatrixSub: MatrixBase {
    override func extra() -> CGFloat {
        0 // sub
    }
}

protocol MatrixPadding {
    func extra() -> CGFloat
}

struct MatrixWitness: MatrixPadding {
    func extra() -> CGFloat {
        0 // witness
    }
}

final class MatrixObjC: NSObject {
    @objc dynamic func extra() -> CGFloat {
        0 // objc
    }
}

enum MatrixTone {
    case plain
    case loud
}

func matrixTonePad(_ tone: MatrixTone) -> CGFloat {
    switch tone {
    case .plain: 0
    case .loud: 0
    }
}

enum MatrixStatics {
    static func pad() -> CGFloat {
        0 // statics
    }
}

func matrixGeneric<T>(_ value: T) -> CGFloat {
    0 // generic
}

func matrixDefault(_ x: CGFloat = 0) -> CGFloat {
    x
}

@_transparent func matrixInline() -> CGFloat {
    0 // inline
}

let matrixGlobal: CGFloat = 0
SWIFT
cat >"$work/Badge.extra.swift" <<'SWIFT'

// Seeded by scripts/measure/live-apply-matrix.sh: the caller of every fixture term.
func matrixExtra() -> CGFloat {
    let base: MatrixBase = MatrixSub()
    let witness: any MatrixPadding = MatrixWitness()
    var total: CGFloat = matrixPad()
    total += MatrixBox().total()
    total += MatrixFinal().total()
    total += base.extra()
    total += witness.extra()
    total += MatrixObjC().extra()
    total += matrixTonePad(.plain)
    total += MatrixStatics.pad()
    total += matrixGeneric(1)
    total += matrixDefault()
    total += matrixInline()
    total += matrixGlobal
    return total
}
SWIFT

# FILE OLD NEW: replace one exact occurrence, or fail the row (the seed drifted).
subst() {
  python3 - "$@" <<'PY'
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
if text.count(old) != 1:
    sys.exit(f"subst: {old!r} occurs {text.count(old)} times in {path}")
open(path, "w").write(text.replace(old, new))
PY
}
seed() {
  cp "$work/MatrixFixture.swift" "$fixture"
  cp "$work/orig/Badge.swift" "$badge"; cp "$work/orig/main.swift" "$main_swift"
  subst "$badge" ".padding(.horizontal, 8)" ".padding(.horizontal, 8 + matrixExtra())"
  cat "$work/Badge.extra.swift" >>"$badge"
  # Older than the prebuilt executable, so inject.sh never takes a file as "changed since the build"
  # only because the matrix rewrote it.
  touch -t 202001010000 "$fixture" "$badge" "$main_swift"
}

# Each row: NAME|CATEGORY|FILES TO NAME TO inject.sh|EDIT (a shell function)
edit_control()         { subst "$badge" ".foregroundStyle(.secondary)" ".foregroundStyle(.red).padding(.leading, 16)"; }
edit_callee_body()     { subst "$fixture" "    0 // pad" "    16 // pad"; }
edit_callee_sig()      { subst "$fixture" $'func matrixPad() -> CGFloat {\n    0 // pad' $'func matrixPad(scale: CGFloat = 1) -> CGFloat {\n    16 * scale // pad'; }
edit_struct_stored()   { subst "$fixture" $'    var a: CGFloat = 0\n    func total() -> CGFloat {\n        a // box' $'    var a: CGFloat = 0\n    var b: CGFloat = 16\n    func total() -> CGFloat {\n        a + b // box'; }
edit_class_stored()    { subst "$fixture" $'    var a: CGFloat = 0\n    func total() -> CGFloat {\n        a // final' $'    var a: CGFloat = 0\n    var b: CGFloat = 16\n    func total() -> CGFloat {\n        a + b // final'; }
edit_vtable_body()     { subst "$fixture" "        0 // sub" "        16 // sub"; }
edit_witness_body()    { subst "$fixture" "        0 // witness" "        16 // witness"; }
edit_objc_body()       { subst "$fixture" "        0 // objc" "        16 // objc"; }
edit_enum_case()       { subst "$fixture" $'    case plain\n    case loud\n' $'    case plain\n    case loud\n    case huge\n'
                         subst "$fixture" "    case .loud: 0" $'    case .loud: 0\n    case .huge: 16'
                         subst "$badge" "matrixTonePad(.plain)" "matrixTonePad(.huge)"; }
edit_static_stored()   { subst "$fixture" $'enum MatrixStatics {\n    static func pad() -> CGFloat {\n        0 // statics' $'enum MatrixStatics {\n    static let extra: CGFloat = 16\n    static func pad() -> CGFloat {\n        extra // statics'; }
edit_generic_body()    { subst "$fixture" "    0 // generic" "    16 // generic"; }
edit_default_arg()     { subst "$fixture" "func matrixDefault(_ x: CGFloat = 0) -> CGFloat {" "func matrixDefault(_ x: CGFloat = 16) -> CGFloat {"; }
edit_transparent()     { subst "$fixture" "    0 // inline" "    16 // inline"; }
edit_global_value()    { subst "$fixture" "let matrixGlobal: CGFloat = 0" "let matrixGlobal: CGFloat = 16"; }
edit_view_state()      { subst "$badge" "    let text: String" $'    let text: String\n    @State private var extra: CGFloat = 16'
                         subst "$badge" ".padding(.horizontal, 8 + matrixExtra())" ".padding(.horizontal, 8 + matrixExtra() + extra)"; }
edit_entry_point()     { subst "$main_swift" "    var live: URL?" $'    var live: URL?\n    var matrixUnused = 0'; }
ROWS=(
  "control_view_body|body-only (caller file)|Badge.swift|edit_control"
  "callee_body|caller/linking: callee body, caller unpatched|MatrixFixture.swift|edit_callee_body"
  "callee_signature|caller/linking: callee signature, callee only|MatrixFixture.swift|edit_callee_sig"
  "callee_signature_with_callers|caller/linking: callee signature, callee + callers|MatrixFixture.swift Badge.swift|edit_callee_sig"
  "struct_stored_property|ABI/layout: struct stored property|MatrixFixture.swift|edit_struct_stored"
  "class_stored_property|ABI/layout: final class stored property|MatrixFixture.swift|edit_class_stored"
  "view_state_property|ABI/layout: SwiftUI @State on the view|Badge.swift|edit_view_state"
  "enum_case_added|ABI/layout: enum case (same size) + caller|MatrixFixture.swift Badge.swift|edit_enum_case"
  "vtable_override_body|dispatch: non-final class override body|MatrixFixture.swift|edit_vtable_body"
  "protocol_witness_body|dispatch: protocol witness body via existential|MatrixFixture.swift|edit_witness_body"
  "objc_dynamic_body|dispatch: @objc dynamic method body|MatrixFixture.swift|edit_objc_body"
  "static_stored_added|stored: new static let|MatrixFixture.swift|edit_static_stored"
  "global_let_value|stored: global let initial value|MatrixFixture.swift|edit_global_value"
  "generic_body|generics: unspecialized generic body|MatrixFixture.swift|edit_generic_body"
  "default_argument_value|caller/linking: default argument value|MatrixFixture.swift|edit_default_arg"
  "transparent_body|caller/linking: @_transparent (inlined into caller)|MatrixFixture.swift|edit_transparent"
  "entry_point_file|native shell: main.swift (the loop and its options)|main.swift|edit_entry_point"
)
want=("$@")

# The badge's rendered width for generation N in LOG (empty when it was not drawn).
width_of() { grep "rendered .*generation-$2\.png" "$1" 2>/dev/null | sed -n 's/.*width=\([0-9]*\).*/\1/p' | tail -1; }
wait_log() { # LOG PATTERN SECONDS
  for _ in $(seq 1 $(( $3 * 10 ))); do grep -q "$2" "$1" && return 0; sleep 0.1; done; return 1
}
start_shell() { # BIN LIVE RENDER LOG
  "$1" --headless --live "$2" --live-render "$3" >"$4" 2>&1 &
  shell=$!
}
stop_shell() { [[ -n "$shell" ]] && { kill "$shell" 2>/dev/null || true; wait "$shell" 2>/dev/null || true; }; shell=""; }

diffs_only="${LIVE_APPLY_MATRIX_DIFFS_ONLY:-}"
if [[ -n "$diffs_only" ]]; then
  for spec in "${ROWS[@]}"; do
    IFS='|' read -r name category names edit <<<"$spec"
    dir="$out/$name"; mkdir -p "$dir"; : >"$dir/change.diff"
    seed
    cp "$fixture" "$dir/MatrixFixture.before.swift"; cp "$badge" "$dir/Badge.before.swift"; cp "$main_swift" "$dir/main.before.swift"
    "$edit"
    for f in MatrixFixture Badge main; do
      case $f in MatrixFixture) p="$fixture";; Badge) p="$badge";; main) p="$main_swift";; esac
      diff -u --label "a/Prototypes/ViewShell/Sources/ViewShell/$f.swift" --label "b/Prototypes/ViewShell/Sources/ViewShell/$f.swift" \
        "$dir/$f.before.swift" "$p" >>"$dir/change.diff" || true
    done
    rm -f "$dir"/*.before.swift
  done
  exit 0
fi
swift --version 2>&1 | head -1 >"$out/swift-version.txt"
sw_vers >"$out/sw_vers.txt" 2>&1 || true

# The prebuilt: the seeded base's Debug build, made once.
seed
seeded_digest="$(cat "$fixture" "$badge" "$main_swift" | shasum -a 256 | cut -d' ' -f1)"
b0=$(now)
swift build --package-path "$package" --scratch-path "$work/prebuilt" --product cmux-view-shell >"$out/prebuilt-build.log" 2>&1 \
  || { echo "live-apply-matrix: the seeded base does not build"; tail -40 "$out/prebuilt-build.log"; exit 1; }
b1=$(now)
prebuilt_bin="$(swift build --package-path "$package" --scratch-path "$work/prebuilt" --show-bin-path)/cmux-view-shell"
export CMUX_VIEW_SHELL_BUILD="$work/prebuilt/debug"

: >"$out/rows.jsonl"
for spec in "${ROWS[@]}"; do
  IFS='|' read -r name category names edit <<<"$spec"
  if (( ${#want[@]} )) && [[ " ${want[*]} " != *" $name "* ]]; then continue; fi
  dir="$out/$name"; mkdir -p "$dir"; : >"$dir/change.diff"
  seed
  # Every row starts from the very tree the prebuilt was built from.
  if [[ "$(cat "$fixture" "$badge" "$main_swift" | shasum -a 256 | cut -d' ' -f1)" != "$seeded_digest" ]]; then
    echo "live-apply-matrix: row $name: the seeded base drifted from the prebuilt's" >&2; exit 1
  fi
  cp "$fixture" "$dir/MatrixFixture.before.swift"; cp "$badge" "$dir/Badge.before.swift"; cp "$main_swift" "$dir/main.before.swift"
  edit_ok=yes; "$edit" 2>"$dir/edit.err" || edit_ok=no
  for f in MatrixFixture Badge main; do
    case $f in MatrixFixture) p="$fixture";; Badge) p="$badge";; main) p="$main_swift";; esac
    diff -u --label "a/Prototypes/ViewShell/Sources/ViewShell/$f.swift" --label "b/Prototypes/ViewShell/Sources/ViewShell/$f.swift" \
      "$dir/$f.before.swift" "$p" >>"$dir/change.diff" || true
  done
  rm -f "$dir"/*.before.swift
  # The edited files are newer than the prebuilt, as in a real checkout after a pull.
  touch "$fixture" "$badge" "$main_swift" 2>/dev/null || true
  touch -t 202001010000 "$main_swift"
  [[ "$name" == entry_point_file ]] && touch "$main_swift"
  [[ "$names" == *Badge.swift* || "$name" == view_state_property ]] || touch -t 202001010000 "$badge"
  [[ "$names" == *MatrixFixture.swift* ]] || touch -t 202001010000 "$fixture"

  # 1. prebuilt + patch
  live="$work/live-$name"; mkdir -p "$live"
  start_shell "$prebuilt_bin" "$live" "$dir/patch" "$dir/patch-shell.log"
  patch_outcome="" patch_width="" patch_base_width="" inject_s="" edit_to_pixels_s=""
  if ! wait_log "$dir/patch-shell.log" "redrawn generation=0" 30; then
    patch_outcome="shell_did_not_start"
  else
    patch_base_width="$(width_of "$dir/patch-shell.log" 0)"
    t0=$(now)
    args=(); for n in $names; do args+=("$src/$n"); done
    if [[ "$edit_ok" != yes ]]; then
      patch_outcome="edit_failed"
    elif ! "$package/inject.sh" --live "$live" "${args[@]}" >"$dir/inject.log" 2>&1; then
      patch_outcome="inject_failed"
    else
      t1=$(now); inject_s=$(python3 -c "print(round($t1-$t0,2))")
      for _ in $(seq 1 300); do
        grep -q "redrawn generation=1" "$dir/patch-shell.log" && { patch_outcome="applied"; break; }
        grep -q "refused" "$dir/patch-shell.log" && { patch_outcome="refused"; break; }
        kill -0 "$shell" 2>/dev/null || { patch_outcome="shell_exited"; break; }
        sleep 0.1
      done
      [[ -z "$patch_outcome" ]] && patch_outcome="no_redraw_30s"
      if [[ "$patch_outcome" == applied ]]; then
        sleep 0.5
        patch_width="$(width_of "$dir/patch-shell.log" 1)"
        drawn=$(grep "redrawn generation=1" "$dir/patch-shell.log" | sed 's/.*at=//' | tail -1)
        edit_to_pixels_s=$(python3 -c "print(round($drawn-$t0,2))")
      fi
    fi
  fi
  stale_ptrs="$(grep -o '[0-9]* symbol pointers stayed on the old code' "$dir/patch-shell.log" | head -1 || true)"
  stop_shell

  # 2. full build of the same tree
  # Each row's full build starts from a copy of the prebuilt's folder (warm, like an incremental CI
  # build of the base), so no row's build sees another row's objects.
  rm -rf "$work/full"; cp -R "$work/prebuilt" "$work/full"
  f0=$(now)
  compile_checked=pass
  swift build --package-path "$package" --scratch-path "$work/full" --product cmux-view-shell >"$dir/full-build.log" 2>&1 || compile_checked=fail
  f1=$(now)
  full_width=""; full_runtime=not_run
  if [[ "$compile_checked" == pass ]]; then
    full_bin="$(swift build --package-path "$package" --scratch-path "$work/full" --show-bin-path)/cmux-view-shell"
    mkdir -p "$work/live-full-$name"
    start_shell "$full_bin" "$work/live-full-$name" "$dir/full" "$dir/full-shell.log"
    if wait_log "$dir/full-shell.log" "redrawn generation=0" 30; then
      sleep 0.5; full_width="$(width_of "$dir/full-shell.log" 0)"; full_runtime=pass
    else
      full_runtime=fail
    fi
    stop_shell
  fi

  python3 - "$out/rows.jsonl" "$name" "$category" "$names" "$patch_outcome" "$patch_base_width" "$patch_width" \
    "$full_width" "$compile_checked" "$full_runtime" "$inject_s" "$edit_to_pixels_s" "$(python3 -c "print(round($f1-$f0,2))")" "$stale_ptrs" \
    "$(grep -m1 -E 'refused|error:' "$dir/patch-shell.log" "$dir/inject.log" 2>/dev/null | cut -c1-400 || true)" <<'PY'
import json, sys
(path, name, category, names, outcome, base_w, patch_w, full_w, compile_checked, full_runtime,
 inject_s, e2p, full_s, stale, why) = sys.argv[1:]
num = lambda s: int(s) if s else None
fl = lambda s: float(s) if s else None
base_w, patch_w, full_w = num(base_w), num(patch_w), num(full_w)
row_valid = (full_w is not None and base_w is not None and full_w != base_w) if compile_checked == "pass" else None
if outcome == "applied":
    runtime = "pass"
    if row_valid is False:
        verdict = "invalid_row"  # the change did not move the full build's pixels: proves nothing
    elif patch_w is not None and patch_w == full_w:
        verdict = "match"
    else:
        verdict = "MISMATCH"
elif outcome in ("refused", "inject_failed"):
    verdict = "detected_fallback"; runtime = "not_run"
else:
    verdict = "error"; runtime = "fail"
row = {
  "label": "IMPLEMENTED",
  "row": name, "category": category, "files_named_to_inject": names.split(),
  "patch": {"outcome": outcome, "runtime": runtime, "width_before_px": base_w, "width_after_px": patch_w,
            "inject_s": fl(inject_s), "edit_to_pixels_s": fl(e2p), "stale_symbol_pointers": stale or None,
            "detail": why or None},
  "full_build": {"compile_checked": compile_checked, "runtime": full_runtime, "width_px": full_w,
                 "incremental_build_s": fl(full_s)},
  "new_code_ran_in_patch": (patch_w != base_w) if outcome == "applied" and patch_w and base_w else None,
  # The change moved the full build's pixels: otherwise the row cannot tell old code from new.
  "row_valid": row_valid,
  # A mismatch, a detected fallback, an error or an invalid row all mean the PR still needs the
  # full build: only a valid match counts as covered by prebuilt + patch.
  "needs_full_build": verdict != "match",
  "verdict": verdict,
}
open(path, "a").write(json.dumps(row) + "\n")
print(json.dumps(row))
PY
done

base_sha="$base_sha" seeded_digest="$seeded_digest" python3 - "$out" "$(python3 -c "print(round($b1-$b0,2))")" <<'PY'
import json, os, sys
out, prebuilt_s = sys.argv[1:]
base_sha, seeded_digest = os.environ["base_sha"], os.environ["seeded_digest"]
rows = [json.loads(l) for l in open(f"{out}/rows.jsonl")]
summary = {}
for r in rows:
    summary[r["verdict"]] = summary.get(r["verdict"], 0) + 1
covered = sum(1 for r in rows if r["verdict"] == "match")
result = {"label": "IMPLEMENTED", "harness": "Prototypes/ViewShell headless, seeded base",
          "base_sha": base_sha, "seeded_base_sha256": seeded_digest,
          "covered_by_patch": covered, "needs_full_build": len(rows) - covered,
          "note": "needs_full_build counts MISMATCH, detected_fallback, error and invalid_row: every row stays in the denominator",
          "swift": open(f"{out}/swift-version.txt").read().strip(),
          "prebuilt_debug_build_s": float(prebuilt_s), "rows": len(rows), "verdicts": summary,
          "mismatch_rows": [r["row"] for r in rows if r["verdict"] == "MISMATCH"],
          "fallback_rows": [r["row"] for r in rows if r["verdict"] == "detected_fallback"],
          "error_rows": [r["row"] for r in rows if r["verdict"] == "error"]}
json.dump(result, open(f"{out}/result.json", "w"), indent=2)
print(json.dumps(result))
PY
# One file for the fleet's --artifact: the whole OUT folder.
tar -czf "$out.tgz" -C "$(dirname "$out")" "$(basename "$out")"
