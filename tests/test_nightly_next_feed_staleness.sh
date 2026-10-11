#!/usr/bin/env bash
# The nightly-next feed staleness alarm (nightly.yml job
# nightly-next-feed-staleness, cx-f58x) opens an issue when the feed's newest
# item is older than the limit while a newer commit is promoted, and closes it
# when the feed is fresh again. Runs the job's script under node with stubbed
# fetch, core and github. No network.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }

python3 - "$ROOT/.github/workflows/nightly.yml" "$TMP/script.js" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
job = re.search(r"\n  nightly-next-feed-staleness:\n(.*?)(?=\n  [A-Za-z0-9_-]+:\n)", text, re.S)
assert job, "no nightly-next-feed-staleness job"
script = re.search(r"\n          script: \|\n((?:            .*\n|\n)+)", job.group(1))
assert script, "no github-script body"
body = "\n".join(line[12:] for line in script.group(1).splitlines())
open(sys.argv[2], "w", encoding="utf-8").write(body)
PY

cat > "$TMP/harness.js" <<'JS'
const fs = require('fs');
const body = fs.readFileSync(process.argv[2], 'utf8');
const scenario = process.argv[3];
const hours = (h) => new Date(Date.now() - h * 3600e3).toUTCString();
const feedAge = { stale: 30, fresh: 2, published: 30 }[scenario];
const calls = [];
globalThis.fetch = async () => ({ ok: true, status: 200, text: async () =>
  `<rss><channel><item><pubDate>${hours(feedAge)}</pubDate></item><item><pubDate>${hours(feedAge + 50)}</pubDate></item></channel></rss>` });
const openIssues = scenario === 'fresh' ? [{ number: 7 }] : [];
const github = { rest: { issues: {
  listForRepo: async () => ({ data: openIssues }),
  getLabel: async () => ({}),
  createLabel: async () => calls.push('createLabel'),
  create: async (a) => calls.push(`create:${a.labels.join(',')}`),
  createComment: async (a) => calls.push(`comment:${a.issue_number}`),
  update: async (a) => calls.push(`update:${a.issue_number}:${a.state}`),
} } };
const core = { notice: () => {}, warning: () => {} };
const context = { repo: { owner: 'o', repo: 'r' }, serverUrl: 'https://github.com', runId: 1 };
process.env.FEED_URL = 'https://example.invalid/appcast-arm64.xml';
process.env.HEAD_SHA = 'a'.repeat(40);
process.env.PUBLISHED_SHA = scenario === 'published' ? 'a'.repeat(40) : 'b'.repeat(40);
process.env.MAX_LAG_HOURS = '24';
const fn = new Function('github', 'context', 'core', 'fetch', `return (async () => {\n${body}\n})();`);
fn(github, context, core, globalThis.fetch).then(() => console.log(calls.join(' '))).catch((e) => { console.error(e); process.exit(1); });
JS

out=$(node "$TMP/harness.js" "$TMP/script.js" stale)
[[ "$out" == "create:nightly-next-feed-stale" ]] || fail "a 30h-old feed with an unpublished promoted commit must open the issue (got '$out')"
out=$(node "$TMP/harness.js" "$TMP/script.js" fresh)
[[ "$out" == "comment:7 update:7:closed" ]] || fail "a fresh feed must close the open issue (got '$out')"
out=$(node "$TMP/harness.js" "$TMP/script.js" published)
[[ -z "$out" ]] || fail "an old feed whose newest item is the promoted commit is not stale (got '$out')"
echo "PASS: nightly-next feed staleness alarm opens on a >24h lag and closes when fresh"
