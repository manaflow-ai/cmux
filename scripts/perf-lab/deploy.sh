#!/usr/bin/env bash
# Deploys labd (the perf lab service) at one pinned, reviewed commit on cmux-lawrence.
#
#   deploy.sh --sha SHA --controller NODE [--lab-host NODE ...] [--submit-command PATH]
#             [--branch feat-cmux-next] [--remote origin] [--data-dir DIR] [--repo DIR] [--python PATH] [--dry-run]
#
# --sha is required and must be a full commit on REMOTE/BRANCH (merged, so reviewed); labd never runs a
# working tree or a moving ref. The commit is checked out as a detached worktree of the lab checkout
# (--repo, default DATA_DIR/repo) at DATA_DIR/releases/SHA, the launchd job is rendered from that
# release's com.cmux.perf-lab.plist, and the job is booted out and bootstrapped again. Roll back by
# deploying the previous sha. --dry-run prints the rendered job and changes no launchd state.
# DATA_DIR defaults to ~/Library/Application Support/cmux-perf-lab.
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
die() { echo "deploy.sh: $*" >&2; exit 2; }

sha=""; branch="feat-cmux-next"; remote="origin"; repo=""; python=""; dry_run=0
data_dir="$HOME/Library/Application Support/cmux-perf-lab"
nodes=()
while (( $# )); do
  case "$1" in
    --sha) sha="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;;
    --remote) remote="${2:-}"; shift 2 ;;
    --data-dir) data_dir="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --python) python="${2:-}"; shift 2 ;;
    --controller|--lab-host|--submit-command) [[ -n "${2:-}" ]] || die "$1 takes a value"; nodes+=("$1" "$2"); shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "deploy.sh: unknown argument $1" >&2; usage ;;
  esac
done

[[ -n "$sha" ]] || die "--sha SHA is required: labd runs only a pinned, reviewed commit"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "--sha takes a full 40-character commit sha, not '$sha'"
[[ " ${nodes[*]-} " == *" --controller "* ]] || die "--controller NODE is required: it is who may write to labd"
if (( ! dry_run )) && [[ "$(uname -s)" != Darwin ]]; then
  die "labd deploys to a Mac under launchd (use --dry-run elsewhere)"
fi

repo="${repo:-$data_dir/repo}"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
  || die "no lab checkout at $repo (git clone https://github.com/manaflow-ai/cmux.git \"$repo\")"
git -C "$repo" fetch --no-tags --quiet "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch"
git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || die "$sha is not a commit of $remote"
git -C "$repo" merge-base --is-ancestor "$sha" "$remote/$branch" \
  || die "$sha is not on $remote/$branch: deploy only reviewed, merged commits"

if [[ -z "$python" ]]; then
  python="$(command -v python3)" || die "no python3 on PATH (--python PATH)"
fi
"$python" -I -c 'import sys; sys.exit(sys.version_info < (3, 10))' || die "$python is older than Python 3.10"

release="$data_dir/releases/$sha"
if [[ ! -e "$release" ]]; then
  mkdir -p "$data_dir/releases"
  git -C "$repo" worktree add --quiet --detach "$release" "$sha"
fi
[[ "$(git -C "$release" rev-parse HEAD)" == "$sha" ]] || die "$release is not a checkout of $sha"
[[ -z "$(git -C "$release" status --porcelain)" ]] || die "$release has local changes; remove it and deploy again"

label="com.cmux.perf-lab"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$python" -I "$release/scripts/perf-lab/labd.py" render-plist --sha "$sha" --release "$release" \
  --data-dir "$data_dir" --repo "$repo" --branch "$branch" --python "$python" "${nodes[@]}" > "$work/$label.plist"
if command -v plutil >/dev/null; then
  plutil -lint -s "$work/$label.plist"
fi
if (( dry_run )); then
  cat "$work/$label.plist"
  exit 0
fi

plist="$HOME/Library/LaunchAgents/$label.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
domain="gui/$(id -u)"
launchctl print "$domain" >/dev/null 2>&1 || domain="user/$(id -u)"
launchctl bootout "$domain/$label" 2>/dev/null || true
# bootout returns while the old labd may still be exiting, and a bootstrap then fails with "5: Input/output error".
for _ in {1..50}; do
  launchctl print "$domain/$label" >/dev/null 2>&1 || break
  sleep 0.2
done
mv "$work/$label.plist" "$plist"
for attempt in 1 2 3 4 5; do
  if launchctl bootstrap "$domain" "$plist"; then
    echo "deployed labd $sha ($domain/$label)"
    exit 0
  fi
  echo "deploy.sh: launchctl bootstrap failed (attempt $attempt of 5)" >&2
  sleep 2
done
die "labd is DOWN: the old job is booted out and $plist did not bootstrap; run: launchctl bootstrap $domain \"$plist\""
