#!/usr/bin/env bash
# The nightly-next feed staleness alarm (nightly.yml job
# nightly-next-feed-staleness, cx-f58x) keeps one open issue while promotions
# have waited longer than the limit (4 h by default) since the newest feed
# item, naming the last published commit and the latest failed promotion's
# job and step, and closes it when the feed is current again. A first
# promotion after a quiet spell is not stale, however old the feed is. Runs the job's script
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
const ago = (h) => new Date(Date.now() - h * 3600e3);
const feedAge = { stale: 30, quiet: 30, fresh: 2, published: 30, dupes: 30, newcause: 30 }[scenario];
const failing = 'Latest failed run https://github.com/o/r/actions/runs/42 on cccccccccccc: build-nightly-ghostty-cli-helper (step: libghostty-vt Zig packages are covered by the notices).';
const calls = [];
let text = '';
globalThis.fetch = async () => ({ ok: true, status: 200, text: async () =>
  `<rss><channel><item><pubDate>${ago(feedAge).toUTCString()}</pubDate></item><item><pubDate>${ago(feedAge + 50).toUTCString()}</pubDate></item></channel></rss>` });
// GitHub lists the newest issue and run first.
const openIssues = { fresh: [{ number: 7 }], dupes: [{ number: 9 }, { number: 7, body: `x\n\n${failing}\n\ny` }], newcause: [{ number: 7, body: 'an older cause' }] }[scenario] || [];
const now = { id: 44, created_at: ago(0).toISOString(), conclusion: null };
const waiting = { quiet: [now], fresh: [now] }[scenario] || [now,
  { id: 42, created_at: ago(5).toISOString(), conclusion: 'failure', head_sha: 'c'.repeat(40), html_url: 'https://github.com/o/r/actions/runs/42' }];
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
    listWorkflowRuns: async (a) => {
      const since = Date.parse(String(a.created).slice(2));
      if (a.workflow_id !== 'nightly.yml' || a.branch !== 'nightly-next' || a.event !== 'push' || !String(a.created).startsWith('>=') || Math.abs(since - ago(feedAge)) > 60e3)
        throw new Error(`unexpected listWorkflowRuns ${JSON.stringify(a)}`);
      return { data: { workflow_runs: waiting } };
    },
    listJobsForWorkflowRun: async (a) => {
      if (a.run_id !== 42) throw new Error(`jobs of run ${a.run_id}, not the failed run 42`);
      return { data: { jobs: [
        { name: 'decide', conclusion: 'success', steps: [] },
        { name: 'build-nightly-ghostty-cli-helper', conclusion: 'failure',
          steps: [{ name: 'Checkout', conclusion: 'success' }, { name: 'libghostty-vt Zig packages are covered by the notices', conclusion: 'failure' }] },
      ] } };
    },
  },
} };
const core = { notice: () => {}, warning: (m) => { throw new Error(`warning: ${m}`); } };
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
[[ "$out" == "create:nightly-next-feed-stale" ]] || fail "promotions unpublished for 5h must open the issue (got '$out')"
issue=$(cat "$TMP/script.js.body")
[[ "$issue" == *"$(printf 'b%.0s' {1..40})"* ]] || fail "the issue must name the last published commit" "$issue"
[[ "$issue" == *"build-nightly-ghostty-cli-helper (step: libghostty-vt Zig packages are covered by the notices)"* ]] || fail "the issue must name the latest failed run's job and step" "$issue"
[[ "$issue" == *"actions/runs/42"* ]] || fail "the issue must link the latest failed run" "$issue"
out=$(node "$TMP/harness.js" "$TMP/script.js" quiet)
[[ -z "$out" ]] || fail "the first promotion after a quiet spell is not stale, however old the feed (got '$out')"
out=$(node "$TMP/harness.js" "$TMP/script.js" dupes)
[[ "$out" == "update:7:body comment:9 update:9:closed" ]] || fail "with two open issues, the oldest must be updated in place and the other closed (got '$out')"
out=$(node "$TMP/harness.js" "$TMP/script.js" newcause)
[[ "$out" == "update:7:body comment:7" ]] || fail "a new failing job must be updated and commented once (got '$out')"
out=$(node "$TMP/harness.js" "$TMP/script.js" fresh)
[[ "$out" == "comment:7 update:7:closed" ]] || fail "a current feed must close the open issue (got '$out')"
out=$(node "$TMP/harness.js" "$TMP/script.js" published)
[[ -z "$out" ]] || fail "an old feed whose newest item is the promoted commit is not stale (got '$out')"
echo "PASS: nightly-next feed alarm: one issue after 4h of unpublished promotions, names the last green commit and failing job, quiet spells do not alarm"
