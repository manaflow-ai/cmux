# shellcheck shell=bash
# The live code build's two passes around any app build (scripts/live-code/build.sh; the NIGHTLY
# live code variant): build and link, list what may be repointed, link again with the list, check.
# Source it, then:
#   live_code_list BIN OUT    OUT/interposable.txt: the CmuxNext Swift symbols BIN exports
#   live_code_check BIN OUT   after the relink: OUT/fixups-2.txt, binds-2.txt, exports-2.txt,
#                             missing-2.txt and cost.json. Returns 1 when BIN binds a CmuxNext
#                             symbol it does not export (dyld would stop the launch), or when no
#                             bind line was read; prints the fixups of the names that are only a
#                             rebase's target, which needs no export
#
# The list comes from the export trie dyld binds from, not the symbol table: nm -g also lists a
# file's private symbols (a private type's deinit, say), and a bind to one of those fails at launch.
# It holds the Swift symbols that name a CmuxNext module: their functions, and their extensions of
# other modules' types.

live_code_ours() { grep -oE '_\$s[^ ]*' | grep -E '[0-9]CmuxNext' | sort -u; }

live_code_list() { # BIN OUT
  local bin="$1" out="$2"
  xcrun dyld_info -exports "$bin" | live_code_ours > "$out/interposable.txt" || true
  echo "live-code build: $(wc -l < "$out/interposable.txt" | tr -d ' ') CmuxNext Swift symbols in the export trie" >&2
  [[ -s "$out/interposable.txt" ]] || { echo "live-code build: the app exports no CmuxNext symbol (LD_EXPORT_SYMBOLS?)" >&2; return 1; }
}

live_code_check() { # BIN OUT
  local bin="$1" out="$2" failed=0
  xcrun dyld_info -exports "$bin" | live_code_ours > "$out/exports-2.txt" || true
  xcrun dyld_info -fixups "$bin" > "$out/fixups-2.txt" || true
  # Only bind lines need an export; dyld_info -fixups also names the target of a rebase.
  grep -E '[[:space:]]((weak|lazy)-)?bind[[:space:]]' "$out/fixups-2.txt" | live_code_ours > "$out/binds-2.txt" || true
  live_code_ours < "$out/fixups-2.txt" > "$out/named-2.txt" || true
  echo "live-code build: relinked: $(wc -l < "$out/binds-2.txt" | tr -d ' ') CmuxNext binds, $(wc -l < "$out/named-2.txt" | tr -d ' ') named by any fixup, $(wc -l < "$out/exports-2.txt" | tr -d ' ') exported" >&2
  comm -23 "$out/named-2.txt" "$out/exports-2.txt" | comm -23 - "$out/binds-2.txt" > "$out/unexported-rebases-2.txt"
  if [[ -s "$out/unexported-rebases-2.txt" ]]; then
    echo "live-code build: $(wc -l < "$out/unexported-rebases-2.txt" | tr -d ' ') unexported CmuxNext symbols are rebase targets only (no export needed); their fixups:" >&2
    grep -F -f <(sed -n 1,5p "$out/unexported-rebases-2.txt") "$out/fixups-2.txt" | head -n 10 >&2 || true
  fi
  comm -23 "$out/binds-2.txt" "$out/exports-2.txt" > "$out/missing-2.txt"
  if [[ ! -s "$out/binds-2.txt" ]]; then
    # The interposable list makes the modules' calls bind through the app; none read means the bind
    # lines were not recognized, and the check would pass blind.
    echo "live-code build: no CmuxNext bind found in dyld_info -fixups (its format?); first lines:" >&2
    sed -n 1,5p "$out/fixups-2.txt" >&2
    failed=1
  elif [[ -s "$out/missing-2.txt" ]]; then
    echo "live-code build: the relinked app binds $(wc -l < "$out/missing-2.txt" | tr -d ' ') CmuxNext symbols it does not export; their fixups:" >&2
    grep -F -f <(sed -n 1,5p "$out/missing-2.txt") "$out/fixups-2.txt" | head -n 10 >&2 || true
    failed=1
  fi
  python3 - "$bin" "$out" <<'PY'
import json, os, sys
bin, out = sys.argv[1], sys.argv[2]
count = lambda name: sum(1 for _ in open(os.path.join(out, name)))
cost = {"binary_bytes": os.path.getsize(bin), "interposable_symbols": count("interposable.txt"),
        "fixup_symbols": count("binds-2.txt"), "unexported_fixup_symbols": count("missing-2.txt")}
json.dump(cost, open(os.path.join(out, "cost.json"), "w"), indent=2)
print("live-code build: cost " + json.dumps(cost), file=sys.stderr)
PY
  return "$failed"
}
