#!/usr/bin/env bash
# The composer-typing bench, this pull request's head against its own base, interleaved on one runner
# (composer-typing.bench.ts --arms, with a fix' noise floor). A `cmux-ci test` job has only the head commit, so
# the base arm is the head plus the reverse of the change, given as a patch (no fetch of the base needed):
#   git diff HEAD BASE -- webviews > /tmp/rev.patch
#   P=$(base64 -w0 /tmp/rev.patch); cmux-ci test --setup webviews -- bash -c \
#     'echo "$0" | base64 -d > /tmp/rev.patch; scripts/measure/composer-typing-ab.sh /tmp/rev.patch \
#        --engine webkit --mode L0 --lengths 60 --keys 500 --gap 20 --rounds 4' "$P"
# Flags after the patch go to the bench as given (the nightly's are in scripts/ci/nightly_interaction_latency.py).
# The base arm shares this checkout's node_modules (the patch must not touch package.json): a second fresh
# install in the job crashed vite's build.
set -euo pipefail
patch="${1:?usage: composer-typing-ab.sh REVERSE_PATCH [bench flags]}"
shift
root="$(git rev-parse --show-toplevel)"
base="$(mktemp -d)/base"
trap 'git -C "$root" worktree remove --force "$base" >/dev/null 2>&1 || true' EXIT
git -C "$root" worktree add -q --detach "$base" HEAD
git -C "$base" apply "$patch"
git -C "$base" diff --stat
ln -s "$root/webviews/node_modules" "$base/webviews/node_modules"
(cd "$base/webviews" && bun scripts/pages/gen-strings.mjs >/dev/null)
cd "$root/webviews"
./node_modules/.bin/playwright install webkit >/dev/null 2>&1 || true
uptime
bun bench/composer-typing.bench.ts "$@" --arms fix=.,base="$base/webviews"
uptime
