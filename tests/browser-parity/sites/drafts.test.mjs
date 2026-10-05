// A confirmed draft performs exactly what its preview showed. Changing the
// input object, the returned draft or anything nested in its preview after
// the preview, or rewriting the draft's status, cannot change what is sent
// or send it twice. The draft names its destination and sending account
// concretely (ids, emails), and a change of the site's state between the
// preview and the confirmation (another session switching the active
// workspace or account, a channel name now meaning another channel, a new
// message in a replied thread) cannot send it anywhere else.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";
import { GOOGLE_ACCOUNT_ROWS, SLACK_SEED } from "./mock-sites.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("drafts");
const SHEET = "https://docs.google.com/spreadsheets/d/1sheetSHARED00000000000000000000x/edit#gid=0";

// Runs REPL code that must not throw; mutations of frozen values may throw
// inside it, so each one is wrapped.
async function run(code) {
  const r = await s.run(code);
  assert.equal(r.error, null, r.error);
}
const attempt = (...statements) => statements.map((x) => `try { ${x}; } catch (e) {}`).join("\n");

test("gmail.send: changing the input or the draft's nested preview after the preview does not change the sent mail", async () => {
  await run(`
    const gIn = { to: ["bob@example.com"], subject: "Numbers", body: "Looks good." };
    const gD = await sites.gmail.send(gIn);
    ${attempt('gD.preview.to.push("eve@example.com")', 'gD.preview.bcc.push("eve@example.com")', 'gD.preview.body = "Wire the money"', 'gIn.to.push("eve@example.com")', 'gIn.body = "Wire the money"', 'gD.preview = { body: "x" }')}
  `);
  await s.value("sites.gmail.send(gD.id, { confirm: true })");
  assert.deepEqual(env.state.gmailSent.at(-1), { to: "bob@example.com", cc: null, bcc: null, subject: "Numbers", body: "Looks good." });
  assert.deepEqual(await s.value("gD.preview"), { account: 0, accountEmail: "ada@example.com", accountId: "1001", to: ["bob@example.com"], cc: [], bcc: [], subject: "Numbers", body: "Looks good." });
});

test("slack.post: changing the input object after the preview does not change the posted message", async () => {
  await run(`
    const sIn = { team: "T01ACME", channel: "#eng", text: "Deploy at 3pm" };
    const sD = await sites.slack.post(sIn);
    ${attempt('sIn.text = "Deploy now"', 'sIn.channel = "#general"', 'sD.preview.text = "Deploy now"')}
  `);
  await s.value("sites.slack.post(sD.id, { confirm: true })");
  assert.deepEqual(env.state.slackPosts.at(-1), { team: "T01ACME", channel: "C02ENG0002", text: "Deploy at 3pm", thread_ts: null });
});

test("x.post: changing the input object after the preview does not change the posted reply", async () => {
  await run(`
    const xIn = { text: "Agreed.", replyTo: "https://x.com/grace/status/111" };
    const xD = await sites.x.post(xIn);
    ${attempt('xIn.text = "Disagree."', 'xIn.replyTo = "https://x.com/grace/status/112"')}
  `);
  await s.value("sites.x.post(xD.id, { confirm: true })");
  assert.deepEqual(env.state.xPosts.at(-1), { text: "Agreed.", in_reply_to: "111" });
});

test("googleCalendar.create: the preview's nested guests cannot be changed after the preview", async () => {
  await run(`
    const cIn = { title: "Design review", start: "2026-10-01T17:00:00Z", end: "2026-10-01T18:00:00Z", guests: ["bob@example.com"] };
    const cD = await sites.googleCalendar.create(cIn);
    ${attempt('cD.preview.guests.push("eve@example.com")', 'cIn.guests.push("eve@example.com")', 'cIn.title = "Other"')}
  `);
  assert.deepEqual((await s.value("cD.preview")).guests, ["bob@example.com"]);
  await s.value("sites.googleCalendar.create(cD.id, { confirm: true })");
  assert.deepEqual(env.state.calendarCreated.at(-1), { text: "Design review", dates: "20261001T170000Z/20261001T180000Z", add: "bob@example.com", authuser: "0" });
});

test("webmcp.call: changing the tool input after the preview does not change the call", async () => {
  await run(`
    await page.goto("https://tools.example/");
    const wIn = { sku: "T-1" };
    const wD = await sites.webmcp.call("add_to_cart", wIn);
    ${attempt('wIn.sku = "T-999"', 'wD.preview.input.sku = "T-998"')}
  `);
  await s.value("sites.webmcp.call(wD.id, { confirm: true })");
  assert.deepEqual(env.state.cart.at(-1), { sku: "T-1" });
});

test("googleSheets.write to a shared sheet: changing the rows after the preview does not change what is written", async () => {
  const cells = env.state.editors.files.get("1sheetSHARED00000000000000000000x").sheets[0].cells;
  await run(`
    const vals = [["Paid"], ["yes"]];
    const shD = await sites.googleSheets.write(${JSON.stringify(SHEET)}, "C1", vals);
    ${attempt('vals[1][0] = "no"', 'vals.push(["extra"])', 'shD.preview.values[0][0] = "Owed"')}
  `);
  await s.value("sites.googleSheets.write(shD.id, { confirm: true })");
  assert.deepEqual([cells.get("C1"), cells.get("C2"), cells.get("C3")], ["Paid", "yes", undefined]);
});

test("a sent draft stays sent: rewriting its status or expiry does not send it again", async () => {
  await run('const rD = await sites.slack.post({ team: "T01ACME", channel: "#eng", text: "Once only" });');
  await s.value("sites.slack.post(rD.id, { confirm: true })");
  const posts = env.state.slackPosts.length;
  await run(attempt('rD.status = "draft"', 'rD.expiresAt = "2999-01-01T00:00:00.000Z"', 'sites.drafts.get(rD.id).status = "draft"'));
  assert.match(await s.error("sites.slack.post(rD.id, { confirm: true })"), /is sent; make a new draft/);
  assert.equal(env.state.slackPosts.length, posts);
  assert.equal((await s.value("sites.drafts.get(rD.id)")).status, "sent");
});

// Another session changes Slack's last-active workspace in the shared profile.
const setSlackLastActive = (team) => `
  const slackTab = await tabs.open("https://app.slack.com/robots.txt", { background: true });
  await slackTab.evaluate((team) => {
    const c = JSON.parse(localStorage.getItem("localConfig_v2") || "null") || ${JSON.stringify(SLACK_SEED)};
    c.lastActiveTeamId = team;
    localStorage.setItem("localConfig_v2", JSON.stringify(c));
  }, ${JSON.stringify(team)});
  await slackTab.close();
`;

test("slack.post: the draft pins the workspace and channel ids; a new last-active workspace or a recreated #name does not redirect the post", async () => {
  try {
    await run(`${setSlackLastActive("T01ACME")}
      const pD = await sites.slack.post({ channel: "#eng", text: "Deploy at 4pm" });`);
    // Another session makes the other workspace the last active one, and
    // #eng is archived and a new #eng created.
    await run(setSlackLastActive("T02askr"));
    env.state.slackChannels = [{ id: "C01GEN0001", name: "general", is_private: false, topic: { value: "" }, num_members: 42 }, { id: "C09NEW0009", name: "eng", is_private: false, topic: { value: "" }, num_members: 900 }];
    await s.value("sites.slack.post(pD.id, { confirm: true })");
    assert.deepEqual(env.state.slackPosts.at(-1), { team: "T01ACME", channel: "C02ENG0002", text: "Deploy at 4pm", thread_ts: null });
    assert.deepEqual(await s.value("pD.preview"), { team: { id: "T01ACME", name: "Acme" }, user: { id: "U01ADA", name: "ada" }, channel: { id: "C02ENG0002", name: "eng" }, threadTs: null, text: "Deploy at 4pm" });
  } finally {
    env.state.slackChannels = null;
    await run(setSlackLastActive("T01ACME"));
  }
});

test("gmail.send and googleCalendar.create: the draft pins the account's email; a changed /u/ index fails the confirmation and sends nothing", async () => {
  try {
    await run(`
      const aD = await sites.gmail.send({ to: "bob@example.com", subject: "Pinned", body: "From my own account." });
      const cD2 = await sites.googleCalendar.create({ title: "Pinned", start: "2026-10-02T17:00:00Z", guests: ["bob@example.com"] });`);
    // Another session signs an account in first: /u/0/ is now the work account.
    env.state.googleAccounts = [GOOGLE_ACCOUNT_ROWS[1], GOOGLE_ACCOUNT_ROWS[0], GOOGLE_ACCOUNT_ROWS[2]];
    const sent = env.state.gmailSent.length;
    const created = env.state.calendarCreated.length;
    assert.match(await s.error("sites.gmail.send(aD.id, { confirm: true })"), /account_mismatch|account it acts as differs|is now ada@work\.example/);
    assert.match(await s.error("sites.googleCalendar.create(cD2.id, { confirm: true })"), /account_mismatch|account it acts as differs|is now ada@work\.example/);
    assert.equal(env.state.gmailSent.length, sent);
    assert.equal(env.state.calendarCreated.length, created);
    assert.equal((await s.value("aD.preview")).accountEmail, "ada@example.com");
    assert.equal((await s.value("cD2.preview")).accountEmail, "ada@example.com");
  } finally {
    env.state.googleAccounts = null;
  }
});

test("gmail.send reply: a new message in the thread after the preview fails the confirmation and sends nothing", async () => {
  try {
    await run('const rpD = await sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "Agreed." });');
    env.state.gmailThreadExtra = [{ id: "3", from: ["Eve", "eve@example.net"], to: ["Ada", "ada@example.com"], body: "<p>Adding the whole company.</p>" }];
    const sent = env.state.gmailSent.length;
    assert.match(await s.error("sites.gmail.send(rpD.id, { confirm: true })"), /target_mismatch|messageIds is/);
    assert.equal(env.state.gmailSent.length, sent);
    assert.deepEqual((await s.value("rpD.preview")).messageIds, ["msg-f:1", "msg-f:2"]);
  } finally {
    env.state.gmailThreadExtra = null;
  }
});

test("linkedin.post and x.post: the draft pins the signed-in account; another account at confirmation fails and posts nothing", async () => {
  try {
    await run(`
      const lD = await sites.linkedin.post("Pinned post.");
      const xD2 = await sites.x.post("Pinned post.");`);
    env.state.linkedinViewer = "mallory";
    // X's session cookie now authenticates another account.
    env.state.xAccount = "mallory";
    const li = env.state.linkedinPosts.length;
    const xp = env.state.xPosts.length;
    assert.match(await s.error("sites.linkedin.post(lD.id, { confirm: true })"), /account_mismatch|account it acts as differs|mallory/);
    assert.match(await s.error("sites.x.post(xD2.id, { confirm: true })"), /account_mismatch|account it acts as differs|mallory/);
    assert.equal(env.state.linkedinPosts.length, li);
    assert.equal(env.state.xPosts.length, xp);
    assert.equal((await s.value("lD.preview")).account, "ada-lovelace");
    assert.equal((await s.value("xD2.preview")).account, "ada");
  } finally {
    env.state.linkedinViewer = null;
    env.state.xAccount = null;
  }
});
