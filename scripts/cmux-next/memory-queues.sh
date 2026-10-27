#!/usr/bin/env bash
# Prints the static memory machine queues of section 6 ("Machine queues") of
# plans/cmux-next/chrome-parity/p07-memory.md: for each queue, its hits and
# then one "<QUEUE> count: N" line. Each hit is one task or one line in a
# batch task. A queue whose search fails prints "<QUEUE> error: ..." on stderr
# and no count line; the other queues still run and the exit status is 2.
#
# Read-only and local only: never wire this into CI or a git hook (CLAUDE.md,
# "Never add CI gates"). Searches stay inside Packages/macOS/CmuxNext/Sources,
# the listed Packages/Shared/*/Sources folders and cmux-tui/crates.
#
# Usage: scripts/cmux-next/memory-queues.sh [QUEUE...]
#   QUEUE: caches pressure observe pages content browsertab caps rust-caps
#          rust-cache phys stream pageview (no QUEUE, or "all": every queue)

# The q_* functions and search run through "q_${q//-/_}".
# shellcheck disable=SC2317
set -euo pipefail

queues=(caches pressure observe pages content browsertab caps rust-caps rust-cache phys stream pageview)

# Prints "<count line name> <unit>" of queue $1; fails for an unknown queue.
# A case, not an associative array: macOS /bin/bash is 3.2.
meta() {
  case "$1" in
    caches) echo "MQ-CACHE files" ;;
    pressure) echo "MQ-PRESSURE sites" ;;
    observe) echo "MQ-OBSERVE hits" ;;
    pages) echo "MQ-PAGES hits" ;;
    content) echo "MQ-CONTENT cases" ;;
    browsertab) echo "MQ-BROWSERTAB conformers" ;;
    caps) echo "MQ-CAPS hits" ;;
    rust-caps) echo "MQ-RUST-CAPS hits" ;;
    rust-cache) echo "MQ-RUST-CACHE hits" ;;
    phys) echo "MQ-PHYS hits" ;;
    stream) echo "MQ-STREAM hits" ;;
    pageview) echo "MQ-PAGEVIEW hits" ;;
    *) return 1 ;;
  esac
}

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

# Every argument is checked before any queue runs, so a bad one never leaves
# partial output behind.
selected=()
for arg in "$@"; do
  case "$arg" in
    -h | --help) usage; exit 0 ;;
    all) selected+=("${queues[@]}") ;;
    *)
      if ! meta "$arg" >/dev/null; then
        echo "memory-queues: unknown queue '$arg'" >&2
        usage >&2
        exit 2
      fi
      selected+=("$arg")
      ;;
  esac
done
((${#selected[@]})) || selected=("${queues[@]}")

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
# Any other status is an error, so the queue gets no count line.
search() {
  local rc=0
  rg "$@" || rc=$?
  if ((rc > 1)); then
    echo "memory-queues: rg exit $rc" >&2
    return 2
  fi
}

# Prints the hits in $3, then the count line for queue $1 (unit $2). With unit
# "sites" the count is of distinct files, since one file is one task.
report() {
  local name="$1" unit="$2" hits="$3" lines
  echo "== $name =="
  [[ -n "$hits" ]] && printf '%s\n' "$hits"
  lines="$(printf '%s' "$hits" | grep -c '' || true)"
  if [[ "$unit" == sites ]]; then
    echo "$name count: $(printf '%s' "$hits" | cut -d: -f1 | sort -u | grep -c '' || true) sites ($lines lines)"
  else
    echo "$name count: $lines $unit"
  fi
}

# Each q_<queue> prints its hits and returns non-zero when a search failed. It
# runs as an `if` condition, where set -e is off, so each search status is
# checked by `|| return` or by pipefail on the function's last pipeline.
q_caches() {
  local typed named stored
  typed="$(search -l --pcre2 '(var|let)\s+\w+\s*(:\s*)?[^=\n]*\[[^\]\n]+:\s*\(?(CGImage|NSImage|UIImage|Data|TabImage|IOSurface|CTLine|NSAttributedString|CALayer|CGPath|MTLTexture|CVPixelBuffer|\w*Image|\w*Bitmap|Rendered)\b[^\]\n]*\]' "${P[@]}" -g '!**/Tests/**' -g '!**/Mock*' -g '!**/*Fixture*')" || return
  named="$(search -l --pcre2 '(class|struct|actor|enum) \w*(Cache|LRU|Memo)\b' "${P[@]}" -g '!**/Tests/**')" || return
  stored="$(search -l --pcre2 '^\s{4}(@\w+\s+)*(private(\(set\))?\s+|fileprivate\s+)?(static\s+)?var\s+\w+\s*:\s*\[[^\]]+:\s*(CGImage|NSImage|Data|TabImage|\[CGImage\]|IOSurface|CGRect)\b[^\]]*\]' "$app")" || return
  # A candidate leaves the queue once it carries a mark, so "every file marked"
  # (rg exit 1) is the drained queue. rg's status is tested inside each xargs
  # batch because GNU xargs reports any non-zero child status as 123.
  # shellcheck disable=SC2016 # $0, $@ and $? belong to the inner sh.
  printf '%s\n' "$typed" "$named" "$stored" | sed '/^$/d' | sort -u | tr '\n' '\0' \
    | xargs -0 -r sh -c 'rg --files-without-match "$0" "$@"; [ $? -le 1 ]' 'MemoryConsumer|memory: fixed|memory: consumer via' \
    | sort
}

q_pressure() {
  # Doc and line comments are excluded.
  search -n --pcre2 '^(?!\s*//).*(makeMemoryPressureSource|_dispatch_source_type_memorypressure|DISPATCH_SOURCE_TYPE_MEMORYPRESSURE)' "$app" "$rust" | sort
}

q_observe() {
  search -n --pcre2 '^(?!\s*///).*memoryPressure\.observe' "$app" --type swift | sort
}

q_pages() {
  search -n 'static let \w+ *= *InternalPageID\(' "$app" | sort
}

q_content() {
  search -n '^    case \w+\(' "$app/CmuxNextApp/TabContent.swift"
}

q_browsertab() {
  search -n 'final class \w+: BrowserTab\b|class \w+: (\w+, )*BrowserTab[ ,{]' "$app" | sort
}

q_caps() {
  search -n --pcre2 '(capacityBytes|maxBytes|byteBudget|terminalCostBytes|ImageStorageBytes)[^\n]*(\d+\s*<<\s*20|\d+_000_000)|capacity\s*=\s*\d{2,}|pagesPerProcess: Int = \d+' "${P[@]}" | sort
}

q_rust_caps() {
  search -n 'MAX_KITTY_IMAGE_BYTES|DEFAULT_SCROLLBACK_LIMIT_BYTES|RING_BYTES|LINK_QUEUE_BYTES' "$rust" --type rust | sort
}

q_rust_cache() {
  search -n --pcre2 '\w*cache\w*\s*:\s*(HashMap|BTreeMap|IndexMap)<|struct \w*(Cache|Lru)\w*\((HashMap|BTreeMap)' "$rust" --type rust -g '!*test*' | sort
}

q_phys() {
  search -n 'physicalMemory' "$app" | sort
}

# A hit leaves MQ-STREAM once its line, or the comment block right above it,
# says `memory: bounded-by <limit>` (the byte bound or credit that holds it).
q_stream() {
  local hits
  hits="$(search -n 'bufferingPolicy:\s*\.unbounded' "$app")" || return
  [[ -n "$hits" ]] || return 0
  # shellcheck disable=SC2016 # the awk program is single-quoted on purpose.
  printf '%s\n' "$hits" | awk -F: '
    {
      file = $1; line = $2 + 0; marked = 0; above = ""
      n = 0
      while ((getline text < file) > 0) {
        n++
        if (n < line) {
          if (text ~ /^[[:space:]]*\/\//) above = above text "\n"; else above = ""
        } else {
          marked = ((above text) ~ /memory: bounded-by /)
          break
        }
      }
      close(file)
      if (!marked) print
    }' | sort
}

q_pageview() {
  search -n 'PageWebView\(' "$app" | sort
}

status=0
for q in "${selected[@]}"; do
  read -r name unit <<<"$(meta "$q")"
  if hits="$("q_${q//-/_}")"; then
    report "$name" "$unit" "$hits"
  else
    echo "$name error: search failed, no count" >&2
    status=2
  fi
done
exit "$status"
