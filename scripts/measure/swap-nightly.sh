# shellcheck shell=bash
# launch-ready.sh dmg=swap: each arm is an APFS clone of ONE signed nightly with only the app's executable and its
# packages' resource bundles replaced by a Release build at that arm's commit (scripts/cmux-next/swap-binary.sh build,
# the nightly's Swift settings), and every arm re-sealed ad hoc the same way, so the arms differ only by the change.
# Sourced by launch-ready.sh; its main calls
#
#   swap_nightly OUT NIGHTLY SIDE=SHA...
#
# NIGHTLY: empty (the newest DMG the NIGHTLY feed offers), an https URL, or sha256:HEX (a DMG this host downloaded
# before, kept by its hash under $CMUX_SWAP_BINARY_ROOT/nightly). Leaves OUT/swap-SIDE/<app>.app for each side, where
# launch-ready's DMG path takes its copies from. SHA `nightly` is the nightly's own binary, only re-sealed (an arm
# with no change, sealed as the others are). Prints
#   LR nightly <url> sha256=<hex> version=<v> commit=<sha>
#   LR swap side=<side> sha=<sha> nightly_version=<v> build_s=<s> replaced=<files>
#   LR swap-sig side=<side> <codesign's signature kind and flags>
#   LR swap-diff side=<side> <changed|added|removed> <path>   (every file the arm's copy differs in from the nightly)
# and returns 3 with `LR swap refused: <why>` when a commit's diff from the nightly's touches what a swap cannot carry
# (swap-binary.sh check: Info.plist, entitlements, the project, helpers, web bundles...) or a build fails. It never
# falls back to a full build.
swap_nightly() {
  local out="$1" nightly="$2" tool cache url="" dmg hex mnt found commit version side sha arg
  shift 2
  tool="${SWAP_NIGHTLY_TOOL:-$PWD/scripts/cmux-next/swap-binary.sh}" # a stand-in in tests/swap-nightly.test.sh
  cache="${CMUX_SWAP_BINARY_ROOT:-$HOME/Library/Caches/cmux-next/swap-binary}/nightly"
  mkdir -p "$cache"
  case "$nightly" in
    sha256:*)
      hex="${nightly#sha256:}"
      [[ "$hex" =~ ^[0-9a-f]{64}$ && -f "$cache/$hex.dmg" ]] || { echo "LR swap refused: no nightly DMG $nightly on this host (pass nightly=URL)"; return 3; }
      url="$(cat "$cache/$hex.url" 2>/dev/null || echo "$nightly")"
      ;;
    https://*|"")
      url="$nightly"
      if [[ -z "$url" ]]; then
        url="$(curl -fsSL --proto '=https' --retry 3 --retry-all-errors -H "Cache-Control: no-cache" https://files-next.cmux.com/nightly-next/appcast-arm64.xml \
          | grep -oE 'url="https://[^"]+-macos-arm64-[0-9]+\.dmg"' | head -1 | cut -d'"' -f2)"
      fi
      [[ "$url" == https://* ]] || { echo "LR swap refused: no nightly DMG in the feed"; return 3; }
      curl -fsSL --proto '=https' --retry 3 --retry-all-errors -A cmux-launch-ready/1 -o "$cache/dl.dmg" "$url" \
        || { echo "LR swap refused: download of $url failed"; return 3; }
      hex="$(shasum -a 256 "$cache/dl.dmg" | cut -d' ' -f1)"
      mv -f "$cache/dl.dmg" "$cache/$hex.dmg"; echo "$url" >"$cache/$hex.url"
      # The host keeps its three newest nightlies (about 250 MB each) for sha256: reruns.
      local old
      # shellcheck disable=SC2012 # the cache names are sha256 hex
      for old in $(ls -t "$cache"/*.dmg 2>/dev/null | tail -n +4); do rm -f "$old" "${old%.dmg}.url"; done
      ;;
    *) echo "LR swap refused: nightly= takes https://... or sha256:HEX"; return 3 ;;
  esac
  dmg="$cache/$hex.dmg"
  mnt="$out/mnt-nightly"; mkdir -p "$mnt" "$out/nightly"
  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null || { echo "LR swap refused: attach failed"; return 3; }
  found="$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)"
  ditto "$found" "$out/nightly/$(basename "$found")" || return 3
  hdiutil detach "$mnt" >/dev/null || hdiutil detach -force "$mnt" >/dev/null
  found="$out/nightly/$(basename "$found")"
  commit="$(plutil -extract CMUXCommit raw -o - "$found/Contents/Info.plist" 2>/dev/null || true)"
  version="$(plutil -extract CFBundleVersion raw -o - "$found/Contents/Info.plist" 2>/dev/null || true)"
  # Nightlies stamp the commit's first 7 hex (nightly.yml SHORT_SHA): this checkout resolves it, else GitHub's commit API.
  if [[ "$commit" =~ ^[0-9a-f]{7,39}$ ]]; then
    local short="$commit"
    commit="$(git rev-parse -q --verify "$short^{commit}" 2>/dev/null \
      || curl -fsSL --retry 3 --retry-all-errors -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/manaflow-ai/cmux/commits/$short" 2>/dev/null || true)"
    [[ "$commit" == "$short"* ]] || commit=""
  fi
  echo "LR nightly $url sha256=$hex version=$version commit=$commit"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "LR swap refused: the nightly names no CMUXCommit"; return 3; }
  # Every commit is checked before any builds: a refusal costs no build.
  for arg in "$@"; do
    side="${arg%%=*}" sha="${arg#*=}"
    [[ "$sha" != nightly ]] || continue
    local why
    why="$("$tool" check "$commit" "$sha" 2>&1 >/dev/null)" || { echo "LR swap refused: side=$side sha=$sha ${why#swap-binary: }"; return 3; }
  done
  for arg in "$@"; do
    side="${arg%%=*}" sha="${arg#*=}"
    local copy placed="" build_s=0
    copy="$out/swap-$side/$(basename "$found")"
    mkdir -p "$out/swap-$side"; rm -rf "$copy"
    cp -cR "$found" "$copy" 2>/dev/null || { rm -rf "$copy"; ditto "$found" "$copy"; } || return 3
    if [[ "$sha" != nightly ]]; then
      "$tool" build "$sha" "$out/swapbuild-$side" --like "$found" >"$out/swapbuild-$side.log" 2>&1 \
        || { tail -30 "$out/swapbuild-$side.log"; echo "LR swap refused: side=$side sha=$sha the Release build failed (swapbuild-$side.log)"; return 3; }
      build_s="$(sed -n 's/.*"build_s": \([0-9]*\).*/\1/p' "$out/swapbuild-$side/build.json")"
      placed="$("$tool" place "$copy" "$out/swapbuild-$side")" || { echo "LR swap refused: side=$side place failed"; return 3; }
      # The overlay is in the copy now; report.tgz keeps the build's log and build.json, not its binaries.
      rm -rf "$out/swapbuild-$side/app" "$out/swapbuild-$side/cmux.unstripped"
    fi
    "$tool" seal "$copy" "$found" >"$out/swap-$side.seal" || { echo "LR swap refused: side=$side the sealed copy does not verify"; return 3; }
    echo "LR swap side=$side sha=$sha nightly_version=$version build_s=$build_s replaced=$(echo "$placed" | sed -n 's/.* replaced=\([^ ]*\).*/\1/p')"
    echo "LR swap-sig side=$side $(sed -n 's/^SB-SEAL .* signature=//p' "$out/swap-$side.seal")"
    "$tool" diff "$found" "$copy" >"$out/swap-diff-$side.txt"
    # One line per bundle item (Contents/MacOS/cmux, Contents/Resources/X.bundle, Contents/_CodeSignature): the kind
    # and how many of its files; every file is in swap-diff-SIDE.txt.
    awk -v side="$side" '{ n = split($2, p, "/"); k = p[1]; for (i = 2; i <= 3 && i <= n; i++) k = k "/" p[i]; c[$1 " " k]++ }
      END { for (x in c) print "LR swap-diff side=" side " " x " files=" c[x] }' "$out/swap-diff-$side.txt" | sort
  done
}
