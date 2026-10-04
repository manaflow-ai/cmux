// A confirmed draft acts as the account that made it, or fails. The draft
// names the account; the confirmation checks it again in the page or
// request that performs the write, right before the write, so another
// session that switches the shared profile's account after the first check
// (while the composer loads) cannot make the draft act as someone else.
import test from "node:test";
import assert from "node:assert/strict";
import { createSitesEnv } from "./harness.mjs";
import { GOOGLE_ACCOUNT_ROWS } from "./mock-sites.mjs";

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
