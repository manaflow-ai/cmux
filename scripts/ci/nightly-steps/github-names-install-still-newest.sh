#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github-names: "Install the feed order check". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the job's and step's env: still set every input.
#
# The step's notes, moved from nightly.yml:
# still-newest: exit 0 while no build above this one is on the live feed. Every mutable
# write below (rolling name, feed copy, body, tag) runs it just before writing, so an
# older run whose uploads waited out a rate limit never writes over a newer build's.
set -euo pipefail
cat > "$RUNNER_TEMP/still-newest" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
live="$(mktemp)"
curl -fsSL --retry 5 --retry-all-errors -A "cmux-nightly-next-github/1" -H "Cache-Control: no-cache" \
  -o "$live" "${NIGHTLY_NEXT_FEED_BASE}/appcast-arm64.xml?github=${GITHUB_RUN_ID}-$RANDOM"
newest="$(python3 -I -c 'import re,sys; print(max([int(v) for v in re.findall(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>", open(sys.argv[1]).read())] or [0]))' "$live")"
rm -f "$live"
if (( newest != NIGHTLY_BUILD )); then
  echo "The feed serves build $newest, not this run's build $NIGHTLY_BUILD: its release state stays as that run writes it."
  exit 1
fi
SH
chmod +x "$RUNNER_TEMP/still-newest"
