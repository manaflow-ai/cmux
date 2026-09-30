// sites.slack, notion, github, linear and jira against mock web APIs and pages.
// Each check also proves no session secret reaches the REPL.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";
import { SECRETS } from "./mock-sites.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("work");
// Every value in the REPL scope (or one value), as text.
const scopeText = (value) => {
  if (value !== s.repl.scope) return JSON.stringify(value);
  return Object.keys(value).map((k) => { try { return JSON.stringify(value[k]); } catch { return ""; } }).join("\n");
};
const noSecrets = (value) => {
  const text = scopeText(value);
  for (const [name, secret] of Object.entries(SECRETS)) assert.ok(!text.includes(secret), `${name} leaked into the result`);
};

test("slack.workspaces lists workspaces from the signed-in Slack page without tokens", async () => {
  const w = await s.value("sites.slack.workspaces()");
  noSecrets(w);
  assert.deepEqual(w.map((x) => [x.teamId, x.name, x.domain, x.lastActive]), [["T01ACME", "Acme", "acme", true], ["T02askr", "Side Project", "sidep", false]]);
  assert.ok(!JSON.stringify(w).includes("xoxc"));
});

test("slack reads: channels, history by #name, replies, search, users; token stays in the page", async () => {
  const ch = await s.value('sites.slack.channels("T01ACME")');
  assert.deepEqual(ch.channels.map((c) => `${c.name}:${c.isPrivate}`), ["general:false", "eng:true"]);
  const h = await s.value('sites.slack.history("Acme", "#general")');
  assert.equal(h.channel, "C01GEN0001");
  assert.deepEqual(h.messages[0], { ts: "1790000000.000200", user: "U01ADA", text: "Ship it", threadTs: "1790000000.000100", replyCount: 2 });
  assert.deepEqual(h.messages[1].files, ["q3.pdf"]);
  assert.equal((await s.value('sites.slack.replies("acme", "C01GEN0001", "1790000000.000100")')).messages.length, 2);
  const found = await s.value('sites.slack.search("T01ACME", "q3")');
  assert.deepEqual([found.total, found.matches[0].text, found.matches[0].channel], [1, "Report about q3", "general"]);
  assert.equal((await s.value('sites.slack.user("T01ACME", "U01BOB")')).realName, "Bob Builder");
  assert.equal((await s.value('sites.slack.call("T01ACME", "auth.test")')).team, "Acme");
  noSecrets(s.repl.scope);
  assert.match(await s.error('sites.slack.call("T01ACME", "chat.postMessage", { channel: "C01GEN0001", text: "x" })'), /not a read-only method/);
  assert.match(await s.error('sites.slack.history("T01ACME", "#nope")'), /no channel #nope/);
  assert.match(await s.error('sites.slack.channels("T99")'), /no signed-in workspace "T99"/);
});

test("slack.post: draft, then the confirmed draft posts once", async () => {
  const d = await s.value('sites.slack.post({ team: "T01ACME", channel: "#eng", text: "Deploy at 3pm", threadTs: "1790000000.000100" })');
  assert.deepEqual(d.preview, { team: "T01ACME", channel: "#eng", threadTs: "1790000000.000100", text: "Deploy at 3pm" });
  assert.equal(env.state.slackPosts.length, 0);
  assert.deepEqual(await s.value(`sites.slack.post(${JSON.stringify(d.id)}, { confirm: true })`), { status: "posted", channel: "C02ENG0002", ts: "1790000009.000900" });
  assert.deepEqual(env.state.slackPosts, [{ team: "T01ACME", channel: "C02ENG0002", text: "Deploy at 3pm", thread_ts: "1790000000.000100" }]);
});

test("notion: accounts, search and a page as Markdown (chunked load plus missing children)", async () => {
  const acc = await s.value("sites.notion.accounts()");
  assert.deepEqual(acc, [{ userId: "user-ada", email: "ada@example.com", name: "Ada Lovelace", spaces: [{ id: "space-0000-0001", name: "Acme Wiki" }] }]);
  const found = await s.value('sites.notion.search("handbook")');
  assert.deepEqual(found.map((x) => [x.id, x.title, x.url]), [["1a2b3c4d-0000-4000-8000-00000000abcd", "Team Handbook", "https://www.notion.so/1a2b3c4d00004000800000000000abcd"]]);
  const page = await s.value('sites.notion.read("https://www.notion.so/acme/Team-Handbook-1a2b3c4d00004000800000000000abcd")');
  assert.equal(page.title, "Team Handbook");
  assert.equal(page.markdown, "# Team Handbook\n\n## Welcome\nRead the [guide](https://example.com/guide) and be **kind**.\n- [x] Set up laptop\n- Parent item\n  - Child item\n```shell\nnpm test\n```\n[Sub page](https://www.notion.so/b6)\n");
  noSecrets(s.repl.scope);
});

test("notion.append: draft converts Markdown; the confirmed draft writes set + listAfter operations after the last block", async () => {
  const d = await s.value('sites.notion.append("1a2b3c4d00004000800000000000abcd", "## Update\\n- [ ] follow up\\nPlain **bold** line")');
  assert.equal(d.preview.blocks, 3);
  assert.equal(env.state.notionOps.length, 0);
  const r = await s.value(`sites.notion.append(${JSON.stringify(d.id)}, { confirm: true })`);
  assert.equal(r.status, "appended");
  const sets = env.state.notionOps.filter((o) => o.command === "set");
  assert.deepEqual(sets.map((o) => [o.args.type, o.args.parent_id, o.args.space_id]), [["sub_header", "1a2b3c4d-0000-4000-8000-00000000abcd", "space-0000-0001"], ["to_do", "1a2b3c4d-0000-4000-8000-00000000abcd", "space-0000-0001"], ["text", "1a2b3c4d-0000-4000-8000-00000000abcd", "space-0000-0001"]]);
  assert.deepEqual(sets[2].args.properties.title, [["Plain "], ["bold", [["b"]]], [" line"]]);
  const lists = env.state.notionOps.filter((o) => o.command === "listAfter");
  assert.equal(lists[0].args.after, "b6");
  assert.equal(lists[1].args.after, sets[0].args.id);
});

test("github: issue and pull request pages as structured Markdown, diff, issue list, raw file", async () => {
  const i = await s.value('sites.github.issue("acme/private#7")');
  assert.deepEqual([i.title, i.state, i.labels], ["Crash on start", "Open", ["bug", "p1"]]);
  assert.deepEqual(i.body, { author: "ada", createdAt: "2026-09-01T00:00:00Z", body: "It crashes with `SIGSEGV`.\n\n- macOS 26" });
  assert.deepEqual(i.comments, [{ author: "bob", createdAt: "2026-09-02T00:00:00Z", body: "Repro confirmed." }]);
  const p = await s.value('sites.github.pull("https://github.com/acme/private/pull/8", { diff: true })');
  assert.deepEqual([p.title, p.state, p.body.body, p.diff], ["Fix crash", "Open", "Fixes #7", "diff --git a/a.c b/a.c\n-crash();\n+ok();\n"]);
  assert.deepEqual(await s.value('sites.github.issues("acme/private")'), [{ number: 7, kind: "issue", title: "Crash on start", url: "https://github.com/acme/private/issues/7" }, { number: 8, kind: "pull", title: "Fix crash", url: "https://github.com/acme/private/pull/8" }]);
  assert.equal(await s.value('sites.github.file("acme/private", "README.md")'), "# Private readme\n");
  assert.match(await s.error('sites.github.issue("acme/private#999")'), /was not found, or this account cannot see it/);
});

test("linear: viewer, issue with comments, search, assigned; mutations refused", async () => {
  assert.deepEqual(await s.value("sites.linear.viewer()"), { id: "u1", name: "Ada", email: "ada@example.com", organization: "Acme" });
  const i = await s.value('sites.linear.issue("https://linear.app/acme/issue/ENG-12/flaky-test")');
  assert.deepEqual([i.identifier, i.state.name, i.labels, i.description, i.comments[0].author], ["ENG-12", "In Progress", ["bug"], "Fails 1 in 10 runs.", "Bob"]);
  assert.deepEqual((await s.value('sites.linear.search("flaky")')).map((x) => x.identifier), ["ENG-12"]);
  assert.equal((await s.value("sites.linear.assigned()")).length, 1);
  assert.match(await s.error('sites.linear.query("mutation { issueDelete(id: \\"x\\") { success } }")'), /mutations are not run/);
});

test("jira: issue with ADF description and comments as Markdown, JQL search, current user", async () => {
  const i = await s.value('sites.jira.issue("https://acme.atlassian.net/browse/ABC-1")');
  assert.deepEqual([i.key, i.summary, i.status, i.assignee, i.url], ["ABC-1", "Login fails", "To Do", "Ada", "https://acme.atlassian.net/browse/ABC-1"]);
  assert.equal(i.description, "Steps **matter**\n\n- Open app");
  assert.deepEqual(i.comments, [{ author: "Bob", created: "2026-09-02T00:00:00.000+0000", body: "@Ada can you look?" }]);
  assert.deepEqual((await s.value('sites.jira.search("project = ABC", { site: "acme" })')).map((x) => x.key), ["ABC-1"]);
  assert.equal((await s.value('sites.jira.me({ site: "https://acme.atlassian.net" })')).displayName, "Ada");
  assert.match(await s.error('sites.jira.issue("ABC-1")'), /pass an issue URL or \{ site/);
  assert.match(await s.error('sites.jira.issue("ABC-2", { site: "acme" })'), /not found/);
});

test("signed out: each API reports not_signed_in", async () => {
  const out = await createSitesEnv({ signedIn: false });
  try {
    const o = out.session("x");
    assert.match(await o.error('sites.notion.search("x")'), /not signed in to Notion/);
    assert.match(await o.error('sites.linear.viewer()'), /not signed in to Linear/);
    assert.match(await o.error('sites.jira.me({ site: "acme" })'), /not signed in to https:\/\/acme\.atlassian\.net/);
    assert.match(await o.error('sites.github.issue("acme/private#7")'), /github: the cmux browser is not signed in/);
    assert.match(await o.error('sites.slack.search("T01ACME", "x")'), /slack search\.messages: invalid_auth|not signed in/);
  } finally {
    await out.close();
  }
});
