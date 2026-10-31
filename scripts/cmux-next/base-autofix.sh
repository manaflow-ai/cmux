#!/usr/bin/env bash
# Repairs the mechanical reds of a feat-cmux-next checkout in place, without
# committing or pushing (cmux-next-base-autofix.yml does that):
#   - generated files: copies DIR's files (the cmux-next generated files job's
#     cmux-next-generated-patch artifact, or the base autofix's action-exports
#     artifact: the action contracts, the CI target graph and the settings
#     exports, regenerated on a Mac by
#     regenerate-action-exports.sh and regenerate-settings-exports.sh, at their
#     repository paths) over the checkout;
#   - the CI target graph: rewrites Packages/macOS/CmuxNext/ci-target-graph.json
#     from FILE, the package's `swift package dump-package` output (Swift 6.2
#     on Linux dumps the same manifest as the Mac);
#   - SDK wire layers: every language binding's generated files from
#     cmux-tui/spec/sdk-schema.json (cmux-tui/bindings/codegen/generate.py; with --sdk);
#   - the daemon capability export: plans/cmux-next/daemon-capabilities.json from
#     DaemonEndpoint.swift (scripts/cmux-next/check-daemon-capabilities-fresh.py; with --capabilities);
#   - the docs shortcuts: web/data/cmux-shortcuts.generated.json from the
#     committed action catalog export (web/scripts/export-docs-shortcuts.ts;
#     with --docs-shortcuts);
#   - the app-host generated files: cmux-tui/crates/cmux-app-host/generated
#     (the typed cmux global, scopes and ops) from the operation catalogs, the
#     action catalog export and the first-party apps' fragments
#     (cmux-tui/crates/cmux-app-host/tools/gen-cmux-global.ts; with --app-host);
#   - the defaults snapshot: schemas/defaults/cmux-next.json from the action
#     and settings exports (scripts/ci/defaults_guard.py snapshot), after
#     --generated copied the regenerated exports in;
#   - the namespace ratchet: drops the rows of scripts/lint-namespace-types-ratchet.txt
#     whose type is fixed or gone (shrink only; with --ratchets), and the
#     namespace lint's safe rewrites of new findings (--namespace-fix; with
#     --ratchets);
#   - the cloud wire clients: the TypeScript and Rust clients from the committed
#     cloud catalog (backend/packages/protocol/scripts/export-client.ts and
#     export-rust-client.ts; with --cloud-clients);
#   - webviews formatting: applies PATCH, the `vp fmt` output of the
#     workflow's read-only webviews-fmt job (it installs webviews' packages,
#     which never run next to the push token); a patch reaching outside
#     webviews/, or into its package.json or lockfile, is not applied
#     (with --webviews-fmt-patch PATCH). The base autofix's job also rebuilds the Chief memory
#     inspector page (build-optchat-inspector-web.sh, which bundles webviews
#     sources), so the patch may also carry
#     Native/OptChat/optchat-chief/inspector/index.html (a stale page left after
#     #22839 broke every webviews bundle build);
#   - cmux-tui tree inputs: reports each embed check_cmux_tui_tree_inputs.py
#     finds missing;
#   - the app FFI pin: reports a stale pin (Package.swift is frozen; the
#     app-ffi-repin pull request carries it);
#   - formatting: cargo fmt over the cmux-tui workspace and each OptChat crate
#     (Native/OptChat; unless --no-fmt).
# Dependency order: the docs shortcuts and app-host files are rewritten from
# action-surfaces.json, so they run after --generated copied the regenerated
# exports in. With --unverified-exports (the exports' inputs changed but their
# Mac job did not regenerate them on this tree) both are left and reported,
# never rewritten from a possibly stale export. --unverified-exports and
# --unverified-settings-exports (the settings exports' inputs changed but the
# Mac job did not regenerate them) also leave the defaults snapshot, which
# reads both exports.
# A path matching base-autofix-frozen.txt is never written; it is reported.
# Prints one line per change ("fixed: ..."), skip ("skipped (frozen): ...") or
# repair left to a person ("left: ...").
#
# Usage: scripts/cmux-next/base-autofix.sh [--generated DIR] [--package-dump FILE] [--strings] [--sdk] [--capabilities] [--docs-shortcuts] [--app-host] [--unverified-exports] [--unverified-settings-exports] [--ratchets] [--cloud-clients] [--webviews-fmt-patch PATCH] [--no-fmt] REPO
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
generated="" package_dump="" sdk=0 capabilities=0 docs_shortcuts=0 app_host=0 unverified_exports=0 unverified_settings=0 ratchets=0 cloud_clients=0 webviews_patch="" fmt=1
while (( $# > 1 )); do
  case "$1" in
    --generated) generated="$2"; shift 2 ;;
    --package-dump) package_dump="$2"; shift 2 ;;
    --strings) shift ;; # a no-op since #21946 (page strings are build output)
    --sdk) sdk=1; shift ;;
    --capabilities) capabilities=1; shift ;;
    --docs-shortcuts) docs_shortcuts=1; shift ;;
    --app-host) app_host=1; shift ;;
    --unverified-exports) unverified_exports=1; shift ;;
    --unverified-settings-exports) unverified_settings=1; shift ;;
    --ratchets) ratchets=1; shift ;;
    --cloud-clients) cloud_clients=1; shift ;;
    --webviews-fmt-patch) webviews_patch="$2"; shift 2 ;;
    --no-fmt) fmt=0; shift ;;
    *) echo "usage: $0 [--generated DIR] [--package-dump FILE] [--strings] [--sdk] [--capabilities] [--docs-shortcuts] [--app-host] [--unverified-exports] [--unverified-settings-exports] [--ratchets] [--cloud-clients] [--webviews-fmt-patch PATCH] [--no-fmt] REPO" >&2; exit 2 ;;
  esac
done
repo="$(cd "${1:?usage: $0 [--generated DIR] [--package-dump FILE] [--strings] [--sdk] [--capabilities] [--docs-shortcuts] [--app-host] [--unverified-exports] [--unverified-settings-exports] [--ratchets] [--cloud-clients] [--webviews-fmt-patch PATCH] [--no-fmt] REPO}" && pwd)"
frozen_list="$script_dir/base-autofix-frozen.txt"

frozen() { # repository-relative path -> 0 when frozen; a "!" line exempts a path
  local pattern hit=1
  while IFS= read -r pattern; do
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    # shellcheck disable=SC2053 # the pattern is a glob
    if [[ "$pattern" == !* ]]; then [[ "$1" == ${pattern#!} ]] && return 1
    elif [[ "$1" == $pattern ]]; then hit=0
    fi
  done < "$frozen_list"
  return "$hit"
}

# 1. Generated files.
if [[ -n "$generated" && -d "$generated" ]]; then
  while IFS= read -r -d '' file; do
    rel="${file#"$generated"/}"
    [[ "$rel" == .paths ]] && continue  # the generated-files job's path list, not a repository file
    if cmp -s "$file" "$repo/$rel"; then continue; fi
    if frozen "$rel"; then echo "skipped (frozen): $rel"; continue; fi
    mkdir -p "$(dirname "$repo/$rel")"
    cp "$file" "$repo/$rel"
    echo "fixed: regenerated $rel"
  done < <(find "$generated" -type f -print0 | sort -z)
fi

# 1b. The CI target graph, from the checkout's own generator.
graph=Packages/macOS/CmuxNext/ci-target-graph.json
if [[ -n "$package_dump" ]]; then
  if frozen "$graph"; then
    echo "skipped (frozen): $graph"
  else
    before="$(cksum < "$repo/$graph" 2>/dev/null || true)"
    python3 -I "$repo/scripts/cmux-next/ci-target-graph.py" --dump "$package_dump" >/dev/null
    [[ "$before" == "$(cksum < "$repo/$graph")" ]] || echo "fixed: regenerated $graph"
  fi
fi

# 1c. (Page strings: build output since #21946, never committed. --strings is
# still accepted, as a no-op, for callers that pass it.)

# 1d. SDK wire layers. A frozen one is put back as it was and reported.
if (( sdk )) && [[ -f "$repo/cmux-tui/bindings/codegen/generate.py" ]]; then
  if ! python3 -I "$repo/cmux-tui/bindings/codegen/generate.py" --check >/dev/null 2>&1; then
    python3 -I "$repo/cmux-tui/bindings/codegen/generate.py" --write >/dev/null
    changed="$(git -C "$repo" ls-files --modified --others --exclude-standard -- cmux-tui/bindings)"
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      if frozen "$rel"; then
        git -C "$repo" checkout --quiet -- "$rel" 2>/dev/null || rm -f "$repo/$rel"
        echo "skipped (frozen): $rel (stale; python3 cmux-tui/bindings/codegen/generate.py --write)"
      else
        echo "fixed: regenerated $rel"
      fi
    done <<<"$changed"
  fi
fi

# 1d2. Daemon capability export. The source parser is the same check used by
# cmux-next checks; write mode keeps the base bot from leaving a stale catalog
# after a Swift-only capability change.
if (( capabilities )) && [[ -f "$repo/scripts/cmux-next/check-daemon-capabilities-fresh.py" ]]; then
  before="$(cksum < "$repo/plans/cmux-next/daemon-capabilities.json" 2>/dev/null || true)"
  python3 -I "$repo/scripts/cmux-next/check-daemon-capabilities-fresh.py" --repo "$repo" --write >/dev/null
  if [[ "$before" != "$(cksum < "$repo/plans/cmux-next/daemon-capabilities.json")" ]]; then
    echo "fixed: regenerated plans/cmux-next/daemon-capabilities.json"
  fi
fi

# 1e. The docs shortcuts copy of the catalog export.
shortcuts=web/data/cmux-shortcuts.generated.json
if (( unverified_exports )); then
  (( docs_shortcuts )) && echo "left: $shortcuts (waits for the action exports; their Mac job did not regenerate them)"
  (( app_host )) && echo "left: cmux-tui/crates/cmux-app-host/generated (waits for the action exports; their Mac job did not regenerate them)"
  docs_shortcuts=0 app_host=0
fi
if (( docs_shortcuts )) && [[ -f "$repo/web/scripts/export-docs-shortcuts.ts" ]]; then
  before="$(cksum < "$repo/$shortcuts" 2>/dev/null || true)"
  (cd "$repo" && bun web/scripts/export-docs-shortcuts.ts >/dev/null)
  if [[ "$before" != "$(cksum < "$repo/$shortcuts")" ]]; then
    if frozen "$shortcuts"; then
      git -C "$repo" checkout --quiet -- "$shortcuts"
      echo "skipped (frozen): $shortcuts (stale; bun web/scripts/export-docs-shortcuts.ts)"
    else
      echo "fixed: regenerated $shortcuts"
    fi
  fi
fi

# 1e1. The cmux-next docs reference pages (web/data/next-docs), from the same
# export and the settings schema (plans/cmux-next/docs-DESIGN.md).
if (( docs_shortcuts )) && [[ -f "$repo/web/scripts/export-next-docs.ts" ]]; then
  (cd "$repo" && bun web/scripts/export-next-docs.ts >/dev/null)
  changed="$(git -C "$repo" status --porcelain -- web/data/next-docs | cut -c4-)"
  if [[ -n "$changed" ]]; then
    while IFS= read -r rel; do
      if frozen "$rel"; then
        git -C "$repo" checkout --quiet -- "$rel" 2>/dev/null || rm -f "$repo/$rel"
        echo "skipped (frozen): $rel (stale; bun web/scripts/export-next-docs.ts)"
      else
        echo "fixed: regenerated $rel"
      fi
    done <<<"$changed"
  fi
fi

# 1e2. The app-host generated files, from the same export and the operation catalogs.
app_host_gen=cmux-tui/crates/cmux-app-host/tools/gen-cmux-global.ts
if (( app_host )) && [[ -f "$repo/$app_host_gen" ]]; then
  (cd "$repo" && bun "$app_host_gen" >/dev/null)
  changed="$(git -C "$repo" status --porcelain -- cmux-tui/crates/cmux-app-host/generated | cut -c4-)"
  if [[ -n "$changed" ]]; then
    while IFS= read -r rel; do
      if frozen "$rel"; then
        git -C "$repo" checkout --quiet -- "$rel" 2>/dev/null || rm -f "$repo/$rel"
        echo "skipped (frozen): $rel (stale; bun $app_host_gen)"
      else
        echo "fixed: regenerated $rel"
      fi
    done <<<"$changed"
  fi
fi

# 1e3. The defaults snapshot, from the action and settings exports
# (scripts/ci/defaults_guard.py). Rewriting it never passes the defaults guard:
# a changed default still needs a SHIP review receipt or a call owner's approval on the pull request.
defaults_snapshot=schemas/defaults/cmux-next.json
if (( unverified_exports || unverified_settings )); then
  waits=()
  (( unverified_exports )) && waits+=("action")
  (( unverified_settings )) && waits+=("settings")
  echo "left: $defaults_snapshot (waits for the ${waits[*]} exports; their Mac job did not regenerate them)"
elif [[ -f "$repo/scripts/ci/defaults_guard.py" ]]; then
  before="$(cksum < "$repo/$defaults_snapshot" 2>/dev/null || true)"
  (cd "$repo" && python3 scripts/ci/defaults_guard.py snapshot >/dev/null)
  if [[ "$before" != "$(cksum < "$repo/$defaults_snapshot")" ]]; then
    if frozen "$defaults_snapshot"; then
      git -C "$repo" checkout --quiet -- "$defaults_snapshot" 2>/dev/null || rm -f "$repo/$defaults_snapshot"
      echo "skipped (frozen): $defaults_snapshot (stale; python3 scripts/ci/defaults_guard.py snapshot)"
    else
      echo "fixed: regenerated $defaults_snapshot"
    fi
  fi
fi

# 1f. Stale namespace ratchet rows. The update only drops fixed or gone
# entries, never adds one; the lint's other findings are left to their PRs.
ratchet=scripts/lint-namespace-types-ratchet.txt
if (( ratchets )) && [[ -f "$repo/$ratchet" ]]; then
  if frozen "$ratchet"; then
    echo "skipped (frozen): $ratchet"
  else
    before="$(cksum < "$repo/$ratchet")"
    (cd "$repo" && NAMESPACE_RATCHET_UPDATE=1 bash scripts/lint-ios-package-conventions.sh >/dev/null 2>&1) || true
    [[ "$before" == "$(cksum < "$repo/$ratchet")" ]] || echo "fixed: dropped stale rows from $ratchet"
  fi
fi

# 1f'. The namespace lint's safe rewrites (an all-static enum or type becomes a
# struct with an init, as --namespace-fix writes). A pull request into
# feat-cmux-next only warns on them and its namespace autofix may have no write
# token, so one that lands with a new finding turns package-conventions-lint red
# on every later base push (#28989, #28136). The fixer only rewrites reported
# findings, never a baselined or ratcheted type; a frozen file is put back.
if (( ratchets )) && [[ -f "$repo/scripts/lint-ios-package-conventions.sh" ]]; then
  # Swift files an earlier step already changed keep their contents from before the fixer, so a
  # frozen one is put back to them and a rewrite in the rest is still reported.
  before_dir="$(mktemp -d "${TMPDIR:-/tmp}/base-autofix-namespace.XXXXXX")"
  while IFS= read -r path; do
    [[ "$path" == *.swift && -f "$repo/$path" ]] || continue
    mkdir -p "$before_dir/$(dirname "$path")" && cp "$repo/$path" "$before_dir/$path"
  done < <(git -C "$repo" diff --name-only -- 'Packages/*' 'ios/cmux/*')
  (cd "$repo" && bash scripts/lint-ios-package-conventions.sh --namespace-fix >/dev/null 2>&1) || true
  while IFS= read -r path; do
    [[ "$path" == *.swift ]] || continue
    if [[ -f "$before_dir/$path" ]]; then
      cmp -s "$before_dir/$path" "$repo/$path" && continue
      frozen "$path" && cp "$before_dir/$path" "$repo/$path"
    elif frozen "$path"; then
      git -C "$repo" checkout --quiet -- "$path"
    fi
    if frozen "$path"; then
      echo "skipped (frozen): $path (./scripts/lint-ios-package-conventions.sh --namespace-fix)"
    else
      echo "fixed: namespace rewrite in $path"
    fi
  done < <(git -C "$repo" diff --name-only -- 'Packages/*' 'ios/cmux/*')
  rm -rf "$before_dir"
fi

# 1g. The cloud wire clients. The generators need no installed packages.
protocol=backend/packages/protocol
if (( cloud_clients )) && [[ -f "$repo/$protocol/scripts/export-rust-client.ts" ]]; then
  (cd "$repo/$protocol" && bun scripts/export-client.ts >/dev/null && bun scripts/export-rust-client.ts >/dev/null)
  changed="$(git -C "$repo" ls-files --modified --deleted --others --exclude-standard -- clients/ts/cloud cmux-tui/crates/cmux-cloud-wire/src/generated)"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if frozen "$rel"; then
      git -C "$repo" checkout --quiet -- "$rel" 2>/dev/null || rm -f "$repo/$rel"
      echo "skipped (frozen): $rel (stale; bun run catalog:client and catalog:rust in $protocol)"
    else
      echo "fixed: regenerated $rel"
    fi
  done <<<"$(sort -u <<<"$changed")"
fi

# 1h. Webviews formatting and the inspector page, from the read-only job's patch.
inspector_page=Native/OptChat/optchat-chief/inspector/index.html
if [[ -n "$webviews_patch" && -s "$webviews_patch" ]]; then
  outside="" include=()
  while IFS=$'\t' read -r _ _ rel; do
    if [[ "$rel" == "$inspector_page" ]]; then
      if frozen "$rel"; then
        echo "skipped (frozen): $rel (stale; scripts/cmux-next/build-optchat-inspector-web.sh)"
      else
        include+=("--include=$rel")
      fi
    elif [[ "$rel" != webviews/* || "$rel" == webviews/package.json || "$rel" == webviews/bun.lock || "$rel" == */node_modules/* ]]; then
      outside+="$rel "
    elif frozen "$rel"; then
      echo "skipped (frozen): $rel (unformatted; vp fmt in webviews)"
    else
      include+=("--include=$rel")
    fi
  done < <(git -C "$repo" apply --numstat "$webviews_patch")
  if [[ -n "$outside" ]]; then
    echo "left: the webviews formatting patch reaches $outside; nothing applied (vp fmt in webviews by hand)"
  elif (( ${#include[@]} )); then
    git -C "$repo" apply "${include[@]}" "$webviews_patch"
    for arg in "${include[@]}"; do
      if [[ "${arg#--include=}" == "$inspector_page" ]]; then
        echo "fixed: rebuilt $inspector_page"
      else
        echo "fixed: vp fmt ${arg#--include=}"
      fi
    done
  fi
fi

# 2. cmux-tui tree inputs: reported only; a person adds them by hand.
missing="$(python3 -I "$script_dir/../ci/check_cmux_tui_tree_inputs.py" --root "$repo" 2>&1 >/dev/null | grep -E '^(blob|tree) ' || true)"
while IFS= read -r entry; do
  [[ -n "$entry" ]] && echo "left: cmux-tui tree input $entry (add it to scripts/cmux-next/cmux-tui-tree-inputs.txt by hand)"
done <<<"$missing"

# 3. The app FFI pin (reported only: Package.swift is frozen).
if [[ -f "$repo/Packages/macOS/CmuxNext/Package.swift" && -x "$repo/scripts/cmux-next/check-app-ffi-pin.sh" ]]; then
  if ! (cd "$repo" && scripts/cmux-next/check-app-ffi-pin.sh >/dev/null 2>&1); then
    if frozen Packages/macOS/CmuxNext/Package.swift; then
      echo "skipped (frozen): Packages/macOS/CmuxNext/Package.swift (stale app FFI pin; the app-ffi-repin pull request carries it)"
    else
      echo "left: stale app FFI pin; repin with scripts/cmux-next/repin-app-ffi.sh once its release is published"
    fi
  fi
fi

# 4. Formatting. Each OptChat crate is its own package; plain cargo fmt keeps
# to it (--all would also format its path dependencies).
if (( fmt )) && [[ -f "$repo/cmux-tui/Cargo.toml" ]]; then
  before="$(git -C "$repo" status --porcelain -- cmux-tui)"
  (cd "$repo/cmux-tui" && cargo fmt --all)
  after="$(git -C "$repo" status --porcelain -- cmux-tui)"
  [[ "$before" == "$after" ]] || echo "fixed: cargo fmt in cmux-tui"
fi
if (( fmt )); then
  for manifest in "$repo"/Native/OptChat/*/Cargo.toml; do
    [[ -f "$manifest" ]] || continue
    crate="${manifest%/Cargo.toml}"; crate="${crate#"$repo"/}"
    before="$(git -C "$repo" status --porcelain -- "$crate")"
    # A crate rustfmt cannot parse is reported; it never stops the other repairs.
    if ! (cd "$repo/$crate" && cargo fmt 2>/dev/null); then
      echo "left: cargo fmt failed in $crate (run it there by hand)"
      continue
    fi
    after="$(git -C "$repo" status --porcelain -- "$crate")"
    [[ "$before" == "$after" ]] || echo "fixed: cargo fmt in $crate"
  done
fi
exit 0
