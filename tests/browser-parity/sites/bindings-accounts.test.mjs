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
    assert.match(await s.error("sites.linkedin.post(lnD.id, { confirm: true })"), /account_mismatch|account it acts as differs|mallory/);
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
    assert.match(await s.error("sites.gmail.send(gmD.id, { confirm: true })"), /account_mismatch|account it acts as differs|ada@work\.example/);
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
    assert.match(await s.error("sites.gmail.send(grD.id, { confirm: true })"), /account_mismatch|account it acts as differs|ada@work\.example/);
    assert.equal(env.state.gmailSent.length, sent);
  } finally {
    env.state.googleAccounts = null;
    env.state.googleSwitchOnLoad = null;
  }
});

// r10 whole#5: page labels are page text. A Gmail or Calendar page whose
// title and Google Account button name the drafted account, while Google's
// account list says the drafted index is now another account, sends and
// saves nothing: the account comes from Google's account list, read right
// before the click, and the labels only have to agree with it.
test("gmail.send and googleCalendar.create: page labels naming the drafted account do not stand in for Google's account list", async () => {
  try {
    await s.run('var lbG = await sites.gmail.send({ to: "bob@example.com", subject: "Labels", body: "Who sends this?" })');
    await s.run('var lbC = await sites.googleCalendar.create({ title: "Labels", start: "2026-10-03T17:00:00Z", guests: ["bob@example.com"] })');
    env.state.googlePageAccount = "ada@example.com";
    env.state.googleSwitchOnLoad = SWITCHED();
    const sent = env.state.gmailSent.length;
    assert.match(await s.error("sites.gmail.send(lbG.id, { confirm: true })"), /account_mismatch|account it acts as differs|ada@work\.example/);
    assert.equal(env.state.gmailSent.length, sent, "the work account sent the drafted mail");
    env.state.googleAccounts = null;
    env.state.googleSwitchOnLoad = SWITCHED();
    const created = env.state.calendarCreated.length;
    assert.match(await s.error("sites.googleCalendar.create(lbC.id, { confirm: true })"), /account_mismatch|account it acts as differs|ada@work\.example/);
    assert.equal(env.state.calendarCreated.length, created, "the work account saved the drafted event");
  } finally {
    env.state.googleAccounts = null;
    env.state.googleSwitchOnLoad = null;
    env.state.googlePageAccount = null;
  }
});

test("googleCalendar.create: the event editor's account is checked right before Save; a switch while it loads creates nothing", async () => {
  try {
    await s.run('var gcD = await sites.googleCalendar.create({ title: "Bound", start: "2026-10-03T17:00:00Z", guests: ["bob@example.com"] })');
    env.state.googleSwitchOnLoad = SWITCHED();
    const created = env.state.calendarCreated.length;
    assert.match(await s.error("sites.googleCalendar.create(gcD.id, { confirm: true })"), /account_mismatch|account it acts as differs|ada@work\.example/);
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

// X's twid cookie names a user id, but any page script (another session's
// too) can write it, and the post goes out as the account X's session
// cookie authenticates. The draft names that account, read from X's own
// account endpoint, and the confirmation reads it again in the composer
// right before Post.
test("x.post: the draft names the account X authenticates; a switch while the composer loads posts nothing, whatever twid says", async () => {
  try {
    await s.run('var xD = await sites.x.post("Bound to my X account.")');
    env.state.xSwitchOnCompose = "mallory";
    const before = env.state.xPosts.length;
    assert.match(await s.error("sites.x.post(xD.id, { confirm: true })"), /account_mismatch|account it acts as differs|mallory/);
    assert.equal(env.state.xPosts.length, before, "the post went out as mallory");
    assert.equal((await s.value("xD.preview")).account, "ada");
  } finally {
    env.state.xAccount = null;
    env.state.xSwitchOnCompose = null;
  }
});

test("x.post: no draft when X does not say which account it authenticates", async () => {
  env.state.xAccountUnknown = true;
  try {
    assert.match(await s.error('sites.x.post("Who am I?")'), /account_unknown|which X account/);
  } finally {
    env.state.xAccountUnknown = false;
  }
});

// Docs, Sheets and Slides edits and Drive trash run in the file's editor
// at a positional account index (/u/N/, authuser). The draft names the
// account the editor is signed in as; the confirmation reads it again in
// the editor, right before the first input, so another account at that
// index (another session signed one in or out) edits or trashes nothing.
const EDIT_DOC_ID = "1docPRIVATE000000000000000000000x";
const EDIT_DOC = `https://docs.google.com/document/d/${EDIT_DOC_ID}/edit`;

test("Google editor drafts: the draft names the editor's account; another account there at confirmation edits nothing", async () => {
  const doc = env.state.editors.files.get(EDIT_DOC_ID);
  const before = JSON.stringify(doc.blocks);
  doc.shared = true;
  try {
    await s.run(`var edD = await sites.googleDocs.replace(${JSON.stringify(EDIT_DOC)}, "Intro", "Opening")`);
    env.state.googleAccounts = SWITCHED();
    assert.match(await s.error("sites.googleDocs.replace(edD.id, { confirm: true })"), /account_mismatch|account it acts as differs|ada@work\.example/);
    assert.equal(JSON.stringify(doc.blocks), before, "the shared doc was edited as the work account");
    assert.equal((await s.value("edD.preview")).account, "ada@example.com");
  } finally {
    doc.shared = false;
    env.state.googleAccounts = null;
  }
});

test("googleDrive.trash drafts: the draft names the editor's account; a switch while the confirmation's editor loads trashes nothing", async () => {
  const doc = env.state.editors.files.get(EDIT_DOC_ID);
  doc.shared = true;
  try {
    await s.run(`var trA = await sites.googleDrive.trash(${JSON.stringify(EDIT_DOC)})`);
    env.state.googleSwitchOnLoad = SWITCHED();
    assert.match(await s.error("sites.googleDrive.trash(trA.id, { confirm: true })"), /account_mismatch|account it acts as differs|ada@work\.example/);
    assert.equal(doc.trashed, false, "the shared file was trashed as the work account");
    assert.equal((await s.value("trA.preview")).account, "ada@example.com");
  } finally {
    doc.shared = false;
    doc.trashed = false;
    env.state.googleAccounts = null;
    env.state.googleSwitchOnLoad = null;
  }
});

const NOTION_PAGE_URL = "https://www.notion.so/acme/Team-Handbook-1a2b3c4d00004000800000000000abcd";

test("notion.append: the draft names the Notion user; another user at confirmation appends nothing", async () => {
  try {
    await s.run(`var nD = await sites.notion.append(${JSON.stringify(NOTION_PAGE_URL)}, "Bound to Ada.")`);
    env.state.notionUser = NOTION_MALLORY;
    const ops = env.state.notionOps.length;
    assert.match(await s.error("sites.notion.append(nD.id, { confirm: true })"), /account_mismatch|account it acts as differs|mallory/);
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
    assert.match(await s.error("sites.slack.post(slD.id, { confirm: true })"), /account_mismatch|account it acts as differs|U09MAL/);
    assert.equal(env.state.slackPosts.length, posts, "nothing was posted as mallory");
    assert.deepEqual((await s.value("slD.preview")).user, { id: "U01ADA", name: "ada" });
  } finally {
    await s.run(setSlackMember({ token: SLACK_SEED.teams.T01ACME.token, user_id: SLACK_SEED.teams.T01ACME.user_id }));
  }
});
