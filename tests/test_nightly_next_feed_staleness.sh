#!/usr/bin/env bash
# The nightly-next feed staleness alarm (nightly.yml job
# nightly-next-feed-staleness, cx-f58x) keeps one open issue while the feed's
# newest item is older than the limit (4 h by default) and a newer commit is
# promoted, naming the last published commit and the latest failed run's job
# and step, and closes it when the feed is fresh again. Runs the job's script
# under node with stubbed fetch, core and github. No network.
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
lag = re.search(r"MAX_LAG_HOURS: \$\{\{ vars.NIGHTLY_NEXT_MAX_FEED_LAG_HOURS \|\| '([0-9.]+)' \}\}", job.group(1))
assert lag, "no MAX_LAG_HOURS default"
open(sys.argv[2] + ".lag", "w").write(lag.group(1))
PY
[[ "$(cat "$TMP/script.js.lag")" == 4 ]] || fail "the default feed lag limit must be 4 hours (feat push to feed takes 50-90 min), got $(cat "$TMP/script.js.lag")"

cat > "$TMP/harness.js" <<'JS'
const fs = require('fs');
const body = fs.readFileSync(process.argv[2], 'utf8');
const scenario = process.argv[3];
const hours = (h) => new Date(Date.now() - h * 3600e3).toUTCString();
const feedAge = { stale: 5, fresh: 2, published: 5, dupes: 5 }[scenario];
const calls = [];
let text = '';
globalThis.fetch = async () => ({ ok: true, status: 200, text: async () =>
  `<rss><channel><item><pubDate>${hours(feedAge)}</pubDate></item><item><pubDate>${hours(feedAge + 50)}</pubDate></item></channel></rss>` });
// GitHub lists the newest issue first.
const openIssues = { fresh: [{ number: 7 }], dupes: [{ number: 9 }, { number: 7 }] }[scenario] || [];
const github = { rest: {
  issues: {
    listForRepo: async () => ({ data: openIssues }),
    getLabel: async () => ({}),
    createLabel: async () => calls.push('createLabel'),
    create: async (a) => { calls.push(`create:${a.labels.join(',')}`); text = a.body; },
    createComment: async (a) => calls.push(`comment:${a.issue_number}`),
    update: async (a) => { calls.push(`update:${a.issue_number}:${a.state || 'body'}`); if (a.body) text = a.body; },
  },
  actions: {
    listWorkflowRuns: async () => ({ data: { workflow_runs: [
      { id: 42, head_sha: 'c'.repeat(40), html_url: 'https://github.com/o/r/actions/runs/42' } ] } }),
    listJobsForWorkflowRun: async () => ({ data: { jobs: [
      { name: 'decide', conclusion: 'success', steps: [] },
      { name: 'build-nightly-ghostty-cli-helper', conclusion: 'failure',
        steps: [{ name: 'Checkout', conclusion: 'success' }, { name: 'libghostty-vt Zig packages are covered by the notices', conclusion: 'failure' }] },
    ] } }),
  },
} };
const core = { notice: () => {}, warning: () => {} };
const context = { repo: { owner: 'o', repo: 'r' }, serverUrl: 'https://github.com', runId: 1 };
process.env.FEED_URL = 'https://example.invalid/appcast-arm64.xml';
process.env.HEAD_SHA = 'a'.repeat(40);
process.env.PUBLISHED_SHA = scenario === 'published' ? 'a'.repeat(40) : 'b'.repeat(40);
process.env.MAX_LAG_HOURS = fs.readFileSync(process.argv[2] + '.lag', 'utf8');
const fn = new Function('github', 'context', 'core', 'fetch', `return (async () => {\n${body}\n})();`);
fn(github, context, core, globalThis.fetch).then(() => { console.log(calls.join(' ')); fs.writeFileSync(process.argv[2] + '.body', text); })
  .catch((e) => { console.error(e); process.exit(1); });
JS

out=$(node "$TMP/harness.js" "$TMP/script.js" stale)
[[ "$out" == "create:nightly-next-feed-stale" ]] || fail "a 5h-old feed with an unpublished promoted commit must open the issue (got '$out')"
issue=$(cat "$TMP/script.js.body")
[[ "$issue" == *"$(printf 'b%.0s' {1..40})"* ]] || fail "the issue must name the last published commit" "$issue"
[[ "$issue" == *"build-nightly-ghostty-cli-helper"*"libghostty-vt Zig packages are covered by the notices"* ]] || fail "the issue must name the latest failed run's job and step" "$issue"
[[ "$issue" == *"actions/runs/42"* ]] || fail "the issue must link the latest failed run" "$issue"
out=$(node "$TMP/harness.js" "$TMP/script.js" dupes)
[[ "$out" == "update:7:body comment:9 update:9:closed" ]] || fail "with two open issues, the oldest must be updated and the other closed (got '$out')"
out=$(node "$TMP/harness.js" "$TMP/script.js" fresh)
[[ "$out" == "comment:7 update:7:closed" ]] || fail "a fresh feed must close the open issue (got '$out')"
out=$(node "$TMP/harness.js" "$TMP/script.js" published)
[[ -z "$out" ]] || fail "an old feed whose newest item is the promoted commit is not stale (got '$out')"
echo "PASS: nightly-next feed staleness alarm keeps one issue past a 4h lag, names the last green commit and failing job, and closes when fresh"
