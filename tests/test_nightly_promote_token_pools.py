#!/usr/bin/env python3
"""The nightly-next promote's GitHub calls never run on one token alone.

A GitHub App has one installation per organization, so every job that mints its token
spends one hourly pool, and github.token is one pool for every workflow in the
repository. On 2026-11-17 at 01:24Z the promote's "Decide the promotion" step failed
with "API rate limit exceeded for installation": its reads ran on the glaeda-route App
(minted by the PR checks) and fell back to github.token only when that mint failed, not
when its pool was spent.

The promote job now mints the release App's own read token first (its pool is shared
only by the release path), then a spare from another App (cmux-bot, as cmux#44171's
GH_TOKEN_SPARE), keeps the glaeda-route token as a second spare and github.token last.
scripts/ci/promote-nightly-next.mjs budgetRequest moves a refused read to the next token
at once and waits (bounded) only when the last one is refused too.

This test pins the mints and each github-script step's token chain, then runs the real
step scripts and the guard's hook against fake clients.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
GUARD = ROOT / "scripts" / "ci" / "promote-nightly-next.mjs"

# READ_TOKEN_CHAIN in the guard, with the mint each one comes from.
CHAIN = [
    ("GH_TOKEN_PRIMARY", "${{ steps.release-read-token.outputs.token }}"),
    ("GH_TOKEN_SPARE", "${{ steps.spare-token.outputs.token }}"),
    ("GH_TOKEN_SPARE_ROUTE", "${{ steps.read-token.outputs.token }}"),
    ("GH_TOKEN_FALLBACK", "${{ github.token }}"),
]
CHAIN_HEAD = ("${{ steps.release-read-token.outputs.token || steps.spare-token.outputs.token"
              " || steps.read-token.outputs.token || github.token }}")
# The App each mint uses: every token in the chain is a different pool.
MINT_APPS = {
    "release-read-token": "${{ secrets.CMUX_RELEASE_APP_ID }}",
    "spare-token": "${{ vars.CMUX_BOT_APP_ID }}",
    "read-token": "${{ vars.GLAEDA_ROUTE_APP_ID }}",
}


def job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["promote-nightly-next"]


def steps() -> list[dict]:
    return job()["steps"]


def by_id(step_id: str) -> dict:
    return next(step for step in steps() if step.get("id") == step_id)


def by_name(name: str) -> dict:
    return next(step for step in steps() if step.get("name") == name)


def node(script: str, **env: str) -> dict:
    result = subprocess.run(["node", "--input-type=module", "-e", script], cwd=ROOT,
                            env={**os.environ, "GUARD": str(GUARD), "GITHUB_WORKSPACE": str(ROOT), **env},
                            capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout.strip().splitlines()[-1])


def test_the_guard_chain_matches_the_workflow() -> None:
    text = GUARD.read_text(encoding="utf-8")
    match = re.search(r"export const READ_TOKEN_CHAIN = \[([^\]]*)\];", text)
    assert match, "READ_TOKEN_CHAIN not found in the guard"
    assert re.findall(r"'([A-Z_]+)'", match.group(1)) == [name for name, _ in CHAIN]


def test_every_token_in_the_chain_is_its_own_pool() -> None:
    for step_id, app in MINT_APPS.items():
        mint = by_id(step_id)
        assert mint["uses"].startswith("actions/create-github-app-token@"), step_id
        assert mint["with"]["app-id"] == app, (step_id, mint["with"]["app-id"])
        # A failed mint drops that token from the chain; it never fails the promotion.
        assert mint.get("continue-on-error") is True, step_id
    assert len(set(MINT_APPS.values())) == len(MINT_APPS)


def test_the_primary_is_the_release_app_read_only() -> None:
    mint = by_id("release-read-token")
    permissions = {key: value for key, value in mint["with"].items() if key.startswith("permission-")}
    assert permissions == {"permission-contents": "read"}, permissions
    assert "if" not in mint, "the primary must be minted for every request"
    # Minted before the decision reads with it; the write token stays a separate mint.
    names = [step.get("id") for step in steps()]
    assert names.index("release-read-token") < names.index("spare-token") < names.index("read-token") < names.index("decide")
    assert by_id("app-token")["with"].get("permission-contents") == "write"


def test_every_github_script_step_reads_through_the_whole_chain() -> None:
    scripted = [step for step in steps() if str(step.get("uses", "")).startswith("actions/github-script@")]
    assert {step["name"] for step in scripted} == {"Decide the promotion", "Move nightly-next"}, [s["name"] for s in scripted]
    for step in scripted:
        assert step["with"].get("github-token") == CHAIN_HEAD, (step["name"], step["with"].get("github-token"))
        for name, value in CHAIN:
            assert step["env"].get(name) == value, (step["name"], name, step["env"].get(name))
        script = step["with"]["script"]
        assert "guard.readTokens(process.env).slice(1).map((token) => getOctokit(token))" in script, step["name"]
        assert re.search(r"github\.hook\.wrap\('request', guard\.budgetRequest\(\{ core, spares[ ,}]", script), step["name"]
        assert "quotaResetRetry" not in script, step["name"]
    # The compare-and-swap read must see nightly-next as it is now.
    assert "memo: false" in by_name("Move nightly-next")["with"]["script"]


# Runs a promote step's real script with fake clients: `github` is the primary's, every
# getOctokit(token) client records the calls it sends. The guard then fails on the fake
# API (that is fine); the hook the script installed is captured and driven directly.
STEP_HARNESS = r"""
import { createRequire } from 'node:module';
const require = createRequire(`${process.env.GITHUB_WORKSPACE}/`);
const sent = [];
const notices = [];
let hook = null;
const rateLimited = (who) => Object.assign(new Error(`API rate limit exceeded for installation (${who})`), {
  status: 403, response: { headers: { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': '1' } },
});
const spent = new Set(JSON.parse(process.env.SPENT));
const client = (token) => ({
  request: async (options) => {
    if (options.request?.hook) throw new Error('the primary client hook reached a spare');
    if (options.headers?.authorization) throw new Error('the primary authorization reached a spare');
    sent.push(token);
    if (spent.has(token)) throw rateLimited(token);
    return { data: token };
  },
});
const unreachable = new Proxy({}, { get: () => new Proxy({}, { get: () => async () => { throw new Error('fake API'); } }) });
const github = { hook: { wrap: (name, fn) => { if (name === 'request') hook = fn; } }, rest: unreachable,
  paginate: async () => { throw new Error('fake API'); } };
const core = { notice: (m) => notices.push(m), warning: () => {}, setOutput: () => {}, setFailed: () => {},
  summary: { addRaw() { return this; }, write: async () => {} } };
const env = JSON.parse(process.env.STEP_ENV);
const run = new Function('github', 'context', 'core', 'process', 'getOctokit', 'require',
  `return (async () => {\n${process.env.STEP_SCRIPT}\n})();`);
try {
  await run(github, { repo: { owner: 'o', repo: 'r' }, runId: 1, payload: {} }, core,
    { env: { ...env, GITHUB_WORKSPACE: process.env.GITHUB_WORKSPACE } }, client, require);
} catch {}
const primary = env.GH_TOKEN_PRIMARY || env.GH_TOKEN_SPARE || env.GH_TOKEN_SPARE_ROUTE || env.GH_TOKEN_FALLBACK;
// The hook's own client: the primary token, whose options carry its request hook.
const first = async () => { sent.push(primary); if (spent.has(primary)) throw rateLimited(primary); return { data: primary }; };
const answers = [];
for (let i = 0; i < 2; i += 1) {
  try {
    answers.push((await hook(first, {
      method: 'GET', url: `/repos/{owner}/{repo}/actions/runs?i=${i}`, headers: { authorization: `token ${primary}` },
      request: { hook: () => {} },
    })).data);
  } catch (error) { answers.push(`refused: ${error.message}`); }
}
console.log(JSON.stringify({ hooked: Boolean(hook), sent, answers, notices }));
"""


def run_step(name: str, spent: list[str], tokens: dict[str, str]) -> dict:
    step = by_name(name)
    env = {key: value for key, value in step["env"].items() if key not in tokens and "${{" not in value}
    env.update({"DECISION": json.dumps({"sha": "a" * 40, "current": "b" * 40}), "REQUESTED_SHA": "a" * 40})
    env.update(tokens)
    return node(STEP_HARNESS, STEP_SCRIPT=step["with"]["script"], STEP_ENV=json.dumps(env), SPENT=json.dumps(spent))


TOKENS = {"GH_TOKEN_PRIMARY": "release", "GH_TOKEN_SPARE": "bot", "GH_TOKEN_SPARE_ROUTE": "route", "GH_TOKEN_FALLBACK": "workflow"}


def test_a_spent_primary_pool_moves_the_promote_to_the_spare_at_once() -> None:
    for name in ("Decide the promotion", "Move nightly-next"):
        out = run_step(name, ["release"], TOKENS)
        assert out["hooked"], name
        # The refused call goes out again on cmux-bot's token with no wait, and so does the next.
        assert out["sent"] == ["release", "bot", "bot"], (name, out)
        assert out["answers"] == ["bot", "bot"], (name, out)
        assert any("token 2 now" in notice for notice in out["notices"]), (name, out)


def test_each_spent_pool_hands_on_to_the_next_down_to_github_token() -> None:
    out = run_step("Decide the promotion", ["release", "bot", "route"], TOKENS)
    assert out["sent"] == ["release", "bot", "route", "workflow", "workflow"], out
    assert out["answers"] == ["workflow", "workflow"], out


def test_a_failed_primary_mint_still_leaves_a_spare() -> None:
    out = run_step("Decide the promotion", ["bot"], {**TOKENS, "GH_TOKEN_PRIMARY": ""})
    assert out["sent"] == ["bot", "route", "route"], out


GUARD_HARNESS = r"""
const guard = await import(process.env.GUARD);
const refused = (status, message, headers = {}) => Object.assign(new Error(message), { status, response: { headers, data: { message } } });
const limit = (reset = '1100') => refused(403, 'API rate limit exceeded for installation', { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': reset });
const out = {};

// A read the release App may not make goes to the spare; a refused write never moves.
{
  const sent = [];
  const spare = { request: async (o) => { sent.push(['spare', o.method]); return { data: 'spare' }; } };
  const hook = guard.budgetRequest({ spares: [spare] });
  const primary = async (o) => { sent.push(['primary', o.method]); throw refused(403, 'Resource not accessible by integration'); };
  out.unreachableRead = (await hook(primary, { method: 'GET', url: '/repos/{owner}/{repo}/commits/{commit_sha}/pulls' })).data;
  const writeHook = guard.budgetRequest({ spares: [spare] });
  try { await writeHook(primary, { method: 'PATCH', url: '/repos/{owner}/{repo}/git/refs/{ref}' }); out.write = 'sent'; }
  catch (error) { out.write = error.status; }
  out.sent = sent;
}

// The last token refused: one bounded wait for its reset, then the read again.
{
  const waits = [];
  let calls = 0;
  const hook = guard.budgetRequest({ spares: [], now: () => 1000000, sleep: async (ms) => waits.push(ms) });
  out.waited = (await hook(async () => { calls += 1; if (calls === 1) throw limit(); return { data: 'after' }; },
    { method: 'GET', url: '/repos/{owner}/{repo}/git/ref/{ref}', ref: 'heads/x' })).data;
  out.waits = waits;
  const far = guard.budgetRequest({ spares: [], now: () => 1000000, sleep: async (ms) => waits.push(ms) });
  try { await far(async () => { throw limit('5000'); }, { method: 'GET', url: '/x' }); out.far = 'answered'; }
  catch (error) { out.far = error.status; }
  out.farWaits = waits.length;
}

// A repeated snapshot read is answered once; an /actions/ read (polled) and a failed read are sent again.
{
  let compares = 0, runs = 0, flaky = 0;
  const hook = guard.budgetRequest({});
  const compare = { method: 'GET', url: '/repos/{owner}/{repo}/compare/{basehead}', basehead: 'a...b', request: { hook: 1 }, headers: { 'x': 1 } };
  await Promise.all([hook(async () => { compares += 1; return { data: 1 }; }, compare),
    hook(async () => { compares += 1; return { data: 1 }; }, { ...compare, request: { hook: 2 } })]);
  await hook(async () => { compares += 1; return { data: 1 }; }, { ...compare, basehead: 'a...c' });
  const list = { method: 'GET', url: '/repos/{owner}/{repo}/actions/runs', per_page: 100 };
  await hook(async () => { runs += 1; return { data: [] }; }, list);
  await hook(async () => { runs += 1; return { data: [] }; }, list);
  const get = { method: 'GET', url: '/repos/{owner}/{repo}/git/commits/{commit_sha}', commit_sha: 'c' };
  try { await hook(async () => { flaky += 1; throw refused(502, 'Bad Gateway'); }, get); } catch {}
  await hook(async () => { flaky += 1; return { data: 'c' }; }, get);
  const off = guard.budgetRequest({ memo: false });
  let fresh = 0;
  await off(async () => { fresh += 1; return {}; }, get);
  await off(async () => { fresh += 1; return {}; }, get);
  Object.assign(out, { compares, runs, flaky, fresh });
}

out.tokens = guard.readTokens({ GH_TOKEN_PRIMARY: ' a ', GH_TOKEN_SPARE: '', GH_TOKEN_SPARE_ROUTE: 'a', GH_TOKEN_FALLBACK: 'w' });
out.kinds = [
  guard.refusal(refused(429, 'Too Many Requests')),
  guard.refusal(refused(403, 'You have exceeded a secondary rate limit')),
  guard.refusal(refused(403, 'Must have admin rights', {}), { method: 'GET' }),
  guard.refusal(refused(403, 'Resource not accessible by integration'), { method: 'POST' }),
  guard.refusal(refused(404, 'Not Found')),
];
console.log(JSON.stringify(out));
"""


def test_the_guard_hook() -> None:
    out = node(GUARD_HARNESS)
    assert out["unreachableRead"] == "spare", out
    assert out["write"] == 403 and out["sent"] == [["primary", "GET"], ["spare", "GET"], ["primary", "PATCH"]], out
    assert out["waited"] == "after" and out["waits"] == [101000], out
    # A reset beyond the three-minute bound is returned to the caller, not waited for.
    assert out["far"] == 403 and out["farWaits"] == 1, out
    assert out["compares"] == 2, out
    assert out["runs"] == 2, out
    assert out["flaky"] == 2, out
    assert out["fresh"] == 2, out
    assert out["tokens"] == ["a", "w"], out
    assert out["kinds"] == ["rate limit", "rate limit", None, None, None], out


def main() -> None:
    tests = [value for name, value in globals().items() if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS: nightly-next promote token pools ({len(tests)} cases)")


if __name__ == "__main__":
    main()
