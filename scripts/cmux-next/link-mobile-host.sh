#!/usr/bin/env bash
# Replaces a bundled bin/cmux-mobile-host copy with a relative link to bin/cmux
# when bin/cmux runs the iPhone connection host by argv[0] (cmux_tui::main
# FOLDED_HOSTS, CMUX-570) and was built from the same host source as the copy:
# one Mach-O instead of two, about 10 MB less.
#
#   scripts/cmux-next/link-mobile-host.sh <bin dir> [<bin/cmux commit>]
#
# The app (MobileHostSupervisor) starts Resources/bin/cmux-mobile-host by that
# path, so argv[0] names the host and bin/cmux runs it. Unlike the daemon's
# hosts it is the app's helper, built from the app's own tree
# (build-mobile-host.sh), so the link is made only when it runs that same
# host: the copy's source key (bin/cmux-mobile-host.version key=) must be the
# key of bin/cmux's commit (build-mobile-host.sh --source-key-at). Otherwise,
# or when bin/cmux does not list the host, or the commit is unknown, the copy
# stays. With no copy (a build that bundles no iPhone host) nothing is made:
# the link never turns on iPhone connections in a build that had none.
# <bin/cmux commit> defaults to bin/cmux-tui.version's commit=.
# CMUX_NEXT_MOBILE_HOST_KEEP_COPY=1 keeps the copy.
#
# Prints what it did; exits 0 unless the arguments are wrong.
set -euo pipefail

bin_dir="${1:?usage: link-mobile-host.sh <bin dir> [<bin/cmux commit>]}"
commit="${2:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host="$bin_dir/cmux-mobile-host"
note() { echo "note: link-mobile-host: $*; keeping bin/cmux-mobile-host"; exit 0; }

[[ -e "$host" || -L "$host" ]] || exit 0
[[ -L "$host" && "$(readlink "$host")" == cmux ]] && { echo "folded cmux-mobile-host (already a link)"; exit 0; }
[[ "${CMUX_NEXT_MOBILE_HOST_KEEP_COPY:-}" != 1 ]] || note "CMUX_NEXT_MOBILE_HOST_KEEP_COPY=1"
[[ -f "$bin_dir/cmux" && ! -L "$bin_dir/cmux" ]] || note "no bin/cmux yet"
"$here/link-folded-hosts.sh" --list "$bin_dir/cmux" | grep -qx cmux-mobile-host || note "bin/cmux does not run it"
if [[ -z "$commit" && -f "$bin_dir/cmux-tui.version" ]]; then
  commit="$(sed -n 's/^commit=//p' "$bin_dir/cmux-tui.version" | head -n 1)"
fi
[[ -n "$commit" && "$commit" != unknown ]] || note "bin/cmux's commit is unknown"
copy_key="$(sed -n 's/^key=//p' "$host.version" 2>/dev/null | head -n 1 || true)"
[[ -n "$copy_key" ]] || note "the copy has no source key (no bin/cmux-mobile-host.version)"
cmux_key="$("$here/build-mobile-host.sh" --source-key-at "$commit" 2>/dev/null || true)"
[[ "$cmux_key" == "$copy_key" ]] ||
  note "bin/cmux (${commit:0:12}, host source ${cmux_key:-unknown}) is not the copy's host source $copy_key"
"$here/link-folded-hosts.sh" "$bin_dir" cmux-mobile-host
# The copy's record stays, as the source the link runs (its sha256= is the copy's).
