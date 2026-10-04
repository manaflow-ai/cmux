// A confirmed draft acts as the account that made it, or fails. The draft
// names the account; the confirmation checks it again in the page or
// request that performs the write, right before the write, so another
// session that switches the shared profile's account after the first check
// (while the composer loads) cannot make the draft act as someone else.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";
import { GOOGLE_ACCOUNT_ROWS, NOTION_MALLORY, SLACK_MALLORY, SLACK_SEED } from "./mock-sites.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("bindings-accounts");

test("linkedin.post: the member is read again in the share composer right before Post; a switch while it loads posts nothing", async () => {
  try {
    await s.run('var lnD = await sites.linkedin.post("Bound to my account.")');
    env.state.linkedinSwitchOnCompose = "mallory";
    const before = env.state.linkedinPosts.length;
    assert.match(await s.error("sites.linkedin.post(lnD.id, { confirm: true })"), /account_changed|mallory/);
    assert.equal(env.state.linkedinPosts.length, before, "nothing was posted as mallory");
    assert.deepEqual(await s.value("lnD.preview"), { account: "ada-lovelace", memberId: 424242, text: "Bound to my account." });
  } finally {
    env.state.linkedinViewer = null;
    env.state.linkedinSwitchOnCompose = null;
  }
});

// Another session signs ada@work.example in first while the page loads, so
// /u/0/ (the drafted index) becomes the work account after the
// confirmation's ListAccounts check passed.
const SWITCHED = () => [GOOGLE_ACCOUNT_ROWS[1], GOOGLE_ACCOUNT_ROWS[0], GOOGLE_ACCOUNT_ROWS[2]];

test("gmail.send: the account the compose page is signed in as is checked right before Send; a switch while it loads sends nothing", async () => {
  try {
    await s.run('var gmD = await sites.gmail.send({ to: "bob@example.com", subject: "Bound", body: "From my own account." })');
    env.state.googleSwitchOnLoad = SWITCHED();
    const sent = env.state.gmailSent.length;
    assert.match(await s.error("sites.gmail.send(gmD.id, { confirm: true })"), /account_changed|ada@work\.example/);
    assert.equal(env.state.gmailSent.length, sent, "nothing was sent from the work account");
  } finally {
    env.state.googleAccounts = null;
    env.state.googleSwitchOnLoad = null;
  }
});

test("gmail.send reply: the thread page's account is checked right before Send", async () => {
  try {
    await s.run('var grD = await sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "Agreed." })');
    env.state.googleSwitchOnLoad = SWITCHED();
    const sent = env.state.gmailSent.length;
    assert.match(await s.error("sites.gmail.send(grD.id, { confirm: true })"), /account_changed|ada@work\.example/);
    assert.equal(env.state.gmailSent.length, sent);
  } finally {
    env.state.googleAccounts = null;
    env.state.googleSwitchOnLoad = null;
  }
});

test("googleCalendar.create: the event editor's account is checked right before Save; a switch while it loads creates nothing", async () => {
  try {
    await s.run('var gcD = await sites.googleCalendar.create({ title: "Bound", start: "2026-10-03T17:00:00Z", guests: ["bob@example.com"] })');
    env.state.googleSwitchOnLoad = SWITCHED();
    const created = env.state.calendarCreated.length;
    assert.match(await s.error("sites.googleCalendar.create(gcD.id, { confirm: true })"), /account_changed|ada@work\.example/);
    assert.equal(env.state.calendarCreated.length, created, "no invitation went out from the work account");
  } finally {
    env.state.googleAccounts = null;
    env.state.googleSwitchOnLoad = null;
  }
});

test("googleDrive.create: the file is the named account's, also when another session signs an account in while the editor loads", async () => {
  try {
    env.state.googleSwitchOnLoad = SWITCHED();
    const f = await s.value('sites.googleDrive.create("document", "Bound create", { uid: 0 })');
    assert.equal(env.state.editors.files.get(f.id).owner, "ada@example.com", "the file was created in the account that moved to u/0");
  } finally {
    env.state.googleAccounts = null;
    env.state.googleSwitchOnLoad = null;
  }
  assert.match(await s.error('sites.googleDrive.create("document", "Bad uid", { uid: "0&x=1" })'), /uid: expected a non-negative integer/);
});

const NOTION_PAGE_URL = "https://www.notion.so/acme/Team-Handbook-1a2b3c4d00004000800000000000abcd";

test("notion.append: the draft names the Notion user; another user at confirmation appends nothing", async () => {
  try {
    await s.run(`var nD = await sites.notion.append(${JSON.stringify(NOTION_PAGE_URL)}, "Bound to Ada.")`);
    env.state.notionUser = NOTION_MALLORY;
    const ops = env.state.notionOps.length;
    assert.match(await s.error("sites.notion.append(nD.id, { confirm: true })"), /account_changed|mallory/);
    assert.equal(env.state.notionOps.length, ops, "nothing was appended as mallory");
    assert.deepEqual((await s.value("nD.preview")).account, { userId: "user-ada", email: "ada@example.com" });
  } finally {
    env.state.notionUser = null;
  }
});

test("notion.append: the write names the drafted user, so a switch after the confirmation's check appends nothing", async () => {
  try {
    await s.run(`var nD2 = await sites.notion.append(${JSON.stringify(NOTION_PAGE_URL)}, "Still bound to Ada.")`);
    env.state.notionSwitchOnSync = NOTION_MALLORY;
    const ops = env.state.notionOps.length;
    assert.ok(await s.error("sites.notion.append(nD2.id, { confirm: true })"), "the confirmation failed");
    assert.equal(env.state.notionOps.length, ops, "nothing was appended as mallory");
  } finally {
    env.state.notionUser = null;
    env.state.notionSwitchOnSync = null;
  }
});

// Another session signs a different member of the same Acme workspace in to
// the shared profile: Slack's web config keeps the workspace id with that
// member's token.
const setSlackMember = (member) => `
  const slackTab = await tabs.open("https://app.slack.com/robots.txt", { background: true });
  await slackTab.evaluate((m) => {
    const c = JSON.parse(localStorage.getItem("localConfig_v2") || "null") || ${JSON.stringify(SLACK_SEED)};
    c.teams.T01ACME = { ...c.teams.T01ACME, token: m.token, user_id: m.user_id };
    localStorage.setItem("localConfig_v2", JSON.stringify(c));
  }, ${JSON.stringify(member)});
  await slackTab.close();
`;

test("slack.post: the draft names the member; another member of the same workspace at confirmation posts nothing", async () => {
  try {
    await s.run('var slD = await sites.slack.post({ team: "T01ACME", channel: "#eng", text: "From Ada only" })');
    await s.run(setSlackMember(SLACK_MALLORY));
    const posts = env.state.slackPosts.length;
    assert.match(await s.error("sites.slack.post(slD.id, { confirm: true })"), /account_changed|U09MAL/);
    assert.equal(env.state.slackPosts.length, posts, "nothing was posted as mallory");
    assert.deepEqual((await s.value("slD.preview")).user, { id: "U01ADA", name: "ada" });
  } finally {
    await s.run(setSlackMember({ token: SLACK_SEED.teams.T01ACME.token, user_id: SLACK_SEED.teams.T01ACME.user_id }));
  }
});
