// A confirmed draft performs exactly what its preview showed. Changing the
// input object, the returned draft or anything nested in its preview after
// the preview, or rewriting the draft's status, cannot change what is sent
// or send it twice.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";

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
  assert.deepEqual(await s.value("gD.preview"), { account: 0, to: ["bob@example.com"], cc: [], bcc: [], subject: "Numbers", body: "Looks good." });
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
