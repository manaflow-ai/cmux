#!/usr/bin/env bash
# Prints the static memory machine queues of plans/cmux-next/memory-DESIGN.md
# (section "Machine queues" of plans/cmux-next/chrome-parity/p07-memory.md):
# for each queue, its hits and then one "<QUEUE> count: N" line. Each hit is
# one task or one line in a batch task.
#
# Read-only and local only: never wire this into CI or a git hook (CLAUDE.md,
# "Never add CI gates"). Searches stay inside Packages/macOS/CmuxNext/Sources,
# the listed Packages/Shared/*/Sources folders and cmux-tui/crates.
#
# Usage: scripts/cmux-next/memory-queues.sh [QUEUE...]
#   QUEUE: caches pressure observe pages content browsertab caps rust-caps
#          rust-cache phys stream pageview (no QUEUE, or "all": every queue)
set -euo pipefail

queues=(caches pressure observe pages content browsertab caps rust-caps rust-cache phys stream pageview)

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root"

command -v rg >/dev/null || { echo "memory-queues: ripgrep (rg) is required" >&2; exit 2; }

app=Packages/macOS/CmuxNext/Sources
rust=cmux-tui/crates
# P of MQ-CACHE and MQ-CAPS: the app sources plus the Shared packages that keep
# images, rendered rows or frames.
P=("$app")
for pkg in CmuxHomeRender CmuxHomeCore CmuxMessagesLab CmuxVNC CmuxScreenKit; do
  [[ -d "Packages/Shared/$pkg/Sources" ]] && P+=("Packages/Shared/$pkg/Sources")
done

# rg exits 1 when nothing matches; an empty queue is a result, not an error.
search() { rg "$@" || [[ $? -eq 1 ]]; }

# Prints the hits on stdin, then the count line for queue $1 (unit $2). With
# unit "sites" the count is of distinct files, since one file is one task.
report() {
  local name="$1" unit="$2" hits lines
  hits="$(cat)"
  echo "== $name =="
  [[ -n "$hits" ]] && printf '%s\n' "$hits"
  lines="$(printf '%s' "$hits" | grep -c '' || true)"
  if [[ "$unit" == sites ]]; then
    echo "$name count: $(printf '%s' "$hits" | cut -d: -f1 | sort -u | grep -c '' || true) sites ($lines lines)"
  else
    echo "$name count: $lines $unit"
  fi
}

q_caches() {
  {
    search -l --pcre2 '(var|let)\s+\w+\s*(:\s*)?[^=\n]*\[[^\]\n]+:\s*\(?(CGImage|NSImage|UIImage|Data|TabImage|IOSurface|CTLine|NSAttributedString|CALayer|CGPath|MTLTexture|CVPixelBuffer|\w*Image|\w*Bitmap|Rendered)\b[^\]\n]*\]' "${P[@]}" -g '!**/Tests/**' -g '!**/Mock*' -g '!**/*Fixture*'
    search -l --pcre2 '(class|struct|actor|enum) \w*(Cache|LRU|Memo)\b' "${P[@]}" -g '!**/Tests/**'
    search -l --pcre2 '^\s{4}(@\w+\s+)*(private(\(set\))?\s+|fileprivate\s+)?(static\s+)?var\s+\w+\s*:\s*\[[^\]]+:\s*(CGImage|NSImage|Data|TabImage|\[CGImage\]|IOSurface|CGRect)\b[^\]]*\]' "$app"
  } | sort -u | tr '\n' '\0' \
    | { xargs -0 -r rg --files-without-match 'MemoryConsumer|memory: fixed|memory: consumer via' || [[ $? -eq 1 ]]; } \
    | sort | report MQ-CACHE files
}

q_pressure() {
  # Doc and line comments are excluded.
  search -n --pcre2 '^(?!\s*//).*(makeMemoryPressureSource|_dispatch_source_type_memorypressure|DISPATCH_SOURCE_TYPE_MEMORYPRESSURE)' "$app" "$rust" \
    | sort | report MQ-PRESSURE sites
}

q_observe() {
  search -n --pcre2 '^(?!\s*///).*memoryPressure\.observe' "$app" --type swift | sort | report MQ-OBSERVE hits
}

q_pages() {
  search -n 'static let \w+ *= *InternalPageID\(' "$app" | sort | report MQ-PAGES hits
}

q_content() {
  search -n '^    case \w+\(' "$app/CmuxNextApp/TabContent.swift" | report MQ-CONTENT cases
}

q_browsertab() {
  search -n 'final class \w+: BrowserTab\b|class \w+: (\w+, )*BrowserTab[ ,{]' "$app" | sort | report MQ-BROWSERTAB conformers
}

q_caps() {
  search -n --pcre2 '(capacityBytes|maxBytes|byteBudget|terminalCostBytes|ImageStorageBytes)[^\n]*(\d+\s*<<\s*20|\d+_000_000)|capacity\s*=\s*\d{2,}|pagesPerProcess: Int = \d+' "${P[@]}" \
    | sort | report MQ-CAPS hits
}

q_rust_caps() {
  search -n 'MAX_KITTY_IMAGE_BYTES|DEFAULT_SCROLLBACK_LIMIT_BYTES|RING_BYTES|LINK_QUEUE_BYTES' "$rust" --type rust \
    | sort | report MQ-RUST-CAPS hits
}

q_rust_cache() {
  search -n --pcre2 '\w*cache\w*\s*:\s*(HashMap|BTreeMap|IndexMap)<|struct \w*(Cache|Lru)\w*\((HashMap|BTreeMap)' "$rust" --type rust -g '!*test*' \
    | sort | report MQ-RUST-CACHE hits
}

q_phys() {
  search -n 'physicalMemory' "$app" | sort | report MQ-PHYS hits
}

q_stream() {
  search -n 'bufferingPolicy:\s*\.unbounded' "$app" | sort | report MQ-STREAM hits
}

q_pageview() {
  search -n 'PageWebView\(' "$app" | sort | report MQ-PAGEVIEW hits
}

selected=("$@")
if [[ ${#selected[@]} -eq 0 || "${selected[0]}" == all ]]; then
  selected=("${queues[@]}")
fi
for q in "${selected[@]}"; do
  case " ${queues[*]} " in
    *" $q "*) "q_${q//-/_}" ;;
    *)
      [[ "$q" == -h || "$q" == --help ]] && { usage; exit 0; }
      echo "memory-queues: unknown queue '$q'" >&2
      usage >&2
      exit 2
      ;;
  esac
done
