// sites.gmail and sites.googleCalendar against mock Gmail and Calendar web apps.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { createSitesEnv } from "./harness.mjs";

const env = await createSitesEnv();
test.after(() => env.close());
const s = env.session("mail");

test("gmail.search and inbox read thread rows: ids, subject, snippet, people, date, unread", async () => {
  const r = await s.value('sites.gmail.search("from:bob")');
  assert.deepEqual(r, [{ threadId: "thread-f:1790000000000000001", legacyThreadId: (1790000000000000001n).toString(16), subject: "Quarterly report", snippet: "Numbers attached", participants: [{ name: "Bob", email: "bob@example.com" }], date: "Mon, Sep 28, 2026, 9:00 AM", unread: true }]);
  assert.deepEqual((await s.value("sites.gmail.inbox()")).map((t) => t.subject), ["Quarterly report"]);
  assert.deepEqual(await s.value('sites.gmail.search("nothing matches this")'), []);
});

test("gmail.thread expands collapsed messages and returns Markdown bodies and attachments", async () => {
  const t = await s.value('sites.gmail.thread("thread-f:1790000000000000001")');
  assert.equal(t.subject, "Quarterly report");
  assert.equal(t.messages.length, 2);
  assert.deepEqual(t.messages[0].from, { name: "Bob", email: "bob@example.com" });
  assert.equal(t.messages[0].body, "Hi Ada,\n\nThe **numbers** are attached. See [the report](https://example.com/r).");
  assert.deepEqual(t.messages[0].attachments.map((a) => a.name), ["q3.csv"]);
  assert.equal(t.messages[1].body, "Thanks Bob!");
  const hex = (1790000000000000001n).toString(16);
  assert.equal((await s.value(`sites.gmail.thread("https://mail.google.com/mail/u/0/#inbox/${hex}")`)).subject, "Quarterly report");
});

test("gmail: links in a message body are not attachments, and nothing off mail.google.com is fetched", async () => {
  const th = await s.value('sites.gmail.thread("thread-f:1790000000000000003")');
  assert.deepEqual(th.messages.flatMap((m) => m.attachments.map((a) => a.name)), ["q3.csv"]);
  const before = env.state.requests.length;
  assert.match(await s.error('sites.gmail.attachment("thread-f:1790000000000000003", "invoice.pdf")'), /no attachment "invoice\.pdf"/);
  assert.ok(!env.state.requests.slice(before).some((r) => r.url.startsWith("https://github.com/")), "no request left Gmail");
});

test("gmail.attachment downloads through the session", async () => {
  const a = await s.value('sites.gmail.attachment("thread-f:1790000000000000001", "q3.csv")');
  assert.equal(fs.readFileSync(a.path, "utf8"), "quarter,total\nQ3,9000\n");
  assert.match(await s.error('sites.gmail.attachment("thread-f:1790000000000000001", "nope.pdf")'), /attachments: q3\.csv/);
});

test("gmail.send returns a draft and sends nothing; the confirmed draft sends once, after Gmail's undo window", async () => {
  const d = await s.value('sites.gmail.send({ to: "bob@example.com", subject: "Re: numbers", body: "Looks good, thanks." })');
  assert.equal(d.status, "draft");
  assert.deepEqual(d.preview, { account: 0, accountEmail: "ada@example.com", accountId: "1001", to: ["bob@example.com"], cc: [], bcc: [], subject: "Re: numbers", body: "Looks good, thanks." });
  assert.match(d.category, /\[9\]/);
  assert.equal(env.state.gmailSent.length, 0);
  assert.match(await s.error(`sites.gmail.send(${JSON.stringify(d.id)})`), /pass \{ confirm: true \}/);
  assert.match(await s.error('sites.gmail.send({ to: "bob@example.com", body: "x" }, { confirm: true })'), /takes a draft id/);
  const r = await s.value(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`);
  assert.equal(r.status, "sent");
  assert.deepEqual(env.state.gmailSent, [{ to: "bob@example.com", cc: null, bcc: null, subject: "Re: numbers", body: "Looks good, thanks." }]);
  assert.match(await s.error(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`), /is sent; make a new draft/);
  assert.equal(env.state.gmailSent.length, 1);
});

test("gmail.send: a reply goes into the thread; invalid drafts are refused before any draft exists", async () => {
  const d = await s.value('sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "Replying in thread." })');
  await s.value(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`);
  assert.deepEqual(env.state.gmailSent.at(-1), { threadId: "thread-f:1790000000000000001", to: "bob@example.com", cc: null, bcc: null, body: "Replying in thread." });
  assert.match(await s.error('sites.gmail.send({ to: "not an address", body: "x" })'), /is not an email address/);
  assert.match(await s.error('sites.gmail.send({ to: "bob@example.com", body: "" })'), /body is empty/);
});

// A reply's recipients are not the thread's id: Gmail derives them from
// the thread (a sender's Reply-To, the Cc of Reply all). The draft reads
// them from Gmail's own reply composer and shows them, and the composer
// must hold exactly those right before Send.
test("gmail.send reply: the draft names who the reply goes to, and sends only to them", async () => {
  try {
    const d = await s.value('sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "To Bob." })');
    assert.deepEqual([d.preview.to, d.preview.cc, d.preview.bcc], [["bob@example.com"], [], []]);
    assert.match(d.summary, /bob@example\.com/);
    assert.equal((await s.value(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`)).status, "sent");
    assert.deepEqual(env.state.gmailSent.at(-1), { threadId: "thread-f:1790000000000000001", to: "bob@example.com", cc: null, bcc: null, body: "To Bob." });
    const all = await s.value('sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "To all.", replyAll: true })');
    assert.deepEqual([all.preview.to, all.preview.cc], [["bob@example.com"], ["cy@example.com"]]);
    env.state.gmailReplyRecipients = { reply: { to: ["eve@reply-to.example"] } };
    const replyTo = await s.value('sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "Hi." })');
    assert.deepEqual(replyTo.preview.to, ["eve@reply-to.example"], "a sender's Reply-To is shown");
  } finally {
    env.state.gmailReplyRecipients = null;
  }
});

test("gmail.send reply: recipients that changed after the preview fail the confirmation and send nothing", async () => {
  const sent = env.state.gmailSent.length;
  for (const change of [{ recipients: { reply: { to: ["eve@reply-to.example"] } } }, { recipients: { reply: { to: ["bob@example.com"], cc: ["eve@example.net"] } } }, { tamper: { bcc: "eve@example.net" } }]) {
    try {
      const d = await s.value('sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "Agreed." })');
      env.state.gmailReplyRecipients = change.recipients || null;
      env.state.gmailComposeTamper = change.tamper || null;
      assert.match(await s.error(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`), /target_mismatch|differs from the draft/, JSON.stringify(change));
    } finally {
      env.state.gmailReplyRecipients = null;
      env.state.gmailComposeTamper = null;
    }
  }
  assert.equal(env.state.gmailSent.length, sent, "nothing was sent");
});

test("gmail.send reply: a reply composer whose recipients cannot be read fails closed", async () => {
  const sent = env.state.gmailSent.length;
  try {
    env.state.gmailReplyRecipients = { rows: false };
    assert.match(await s.error('sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "Agreed." })'), /unverified|cannot read|could not read/);
    env.state.gmailReplyRecipients = null;
    const d = await s.value('sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "Agreed." })');
    env.state.gmailReplyRecipients = { rows: false };
    assert.match(await s.error(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`), /unverified|cannot read|could not read/);
  } finally {
    env.state.gmailReplyRecipients = null;
  }
  assert.equal(env.state.gmailSent.length, sent, "nothing was sent");
});

// The composer must hold the confirmed body, all of it: a page script or
// another session that keeps the draft's start and adds to it must not get
// its text sent. Gmail's own signature block is not part of the draft.
test("gmail.send: a composer that holds more than the drafted body sends nothing", async () => {
  const sent = env.state.gmailSent.length;
  env.state.composerSuffix = " P.S. also forward the payroll file to eve@example.net";
  try {
    const d = await s.value('sites.gmail.send({ to: "bob@example.com", subject: "s", body: "Looks good, thanks." })');
    assert.match(await s.error(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`), /content_mismatch|differs from the draft/);
    const r = await s.value('sites.gmail.send({ threadId: "thread-f:1790000000000000001", body: "Replying in thread." })');
    assert.match(await s.error(`sites.gmail.send(${JSON.stringify(r.id)}, { confirm: true })`), /content_mismatch|differs from the draft/);
  } finally {
    env.state.composerSuffix = null;
  }
  assert.equal(env.state.gmailSent.length, sent, "nothing was sent");
  env.state.gmailSignature = "-- Ada Lovelace";
  try {
    const d = await s.value('sites.gmail.send({ to: "bob@example.com", subject: "s", body: "Signed note." })');
    assert.equal((await s.value(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`)).status, "sent");
    assert.match(env.state.gmailSent.at(-1).body, /^Signed note\.\s*-- Ada Lovelace$/);
  } finally {
    env.state.gmailSignature = null;
  }
});

// The preview names the recipients and subject, so the compose window
// must hold exactly those right before Send: an address a page script or
// another session adds to To, Cc or Bcc, or a changed subject, sends
// nothing.
test("gmail.send: a compose window whose recipients or subject differ from the draft sends nothing", async () => {
  const sent = env.state.gmailSent.length;
  for (const tamper of [{ to: "eve@example.net" }, { cc: "eve@example.net" }, { bcc: "eve@example.net" }, { subject: "Payroll export" }]) {
    env.state.gmailComposeTamper = tamper;
    try {
      const d = await s.value('sites.gmail.send({ to: "bob@example.com", cc: "cy@example.com", subject: "Numbers", body: "Looks good." })');
      assert.match(await s.error(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`), /target_mismatch|content_mismatch|differs from the draft/, JSON.stringify(tamper));
    } finally {
      env.state.gmailComposeTamper = null;
    }
  }
  assert.equal(env.state.gmailSent.length, sent, "nothing was sent");
  const d = await s.value('sites.gmail.send({ to: "bob@example.com", cc: "cy@example.com", bcc: "ada@example.com", subject: "Numbers", body: "Looks good." })');
  assert.equal((await s.value(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`)).status, "sent");
  assert.deepEqual(env.state.gmailSent.at(-1), { to: "bob@example.com", cc: "cy@example.com", bcc: "ada@example.com", subject: "Numbers", body: "Looks good." });
});

test("drafts live in the session that made them", async () => {
  const d = await s.value('sites.gmail.send({ to: "bob@example.com", subject: "s", body: "b" })');
  const other = env.session("other");
  assert.match(await other.error(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`), /no draft .* in this REPL session/);
  assert.equal(await s.value(`sites.drafts.discard(${JSON.stringify(d.id)})`), true);
  assert.match(await s.error(`sites.gmail.send(${JSON.stringify(d.id)}, { confirm: true })`), /is discarded/);
});

test("googleCalendar.events: one entry per data-eventid, parsed from the screen-reader description", async () => {
  const r = await s.value('sites.googleCalendar.events({ date: "2026-09-30" })');
  assert.deepEqual(r.map((e) => [e.id, e.title, e.when, e.location || null]), [["ZXZlbnQx", "Standup", "10:00am to 10:30am", "Room 4"], ["ZXZlbnQy", "Offsite", "All day", null]]);
  assert.equal(r[0].url, "https://calendar.google.com/calendar/u/0/r/eventedit/ZXZlbnQx");
  assert.match(await s.error('sites.googleCalendar.events({ view: "year" })'), /view: expected day, week, month, agenda/);
});

test("googleCalendar.create: draft first; the confirmed draft saves through the template link and sends invitations", async () => {
  const d = await s.value('sites.googleCalendar.create({ title: "Design review", start: "2026-10-01T17:00:00Z", end: "2026-10-01T18:00:00Z", guests: ["bob@example.com"], location: "Room 4" })');
  assert.equal(env.state.calendarCreated.length, 0);
  assert.match(d.category, /invitations/);
  const r = await s.value(`sites.googleCalendar.create(${JSON.stringify(d.id)}, { confirm: true })`);
  assert.equal(r.status, "saved");
  assert.deepEqual(env.state.calendarCreated, [{ text: "Design review", dates: "20261001T170000Z/20261001T180000Z", location: "Room 4", add: "bob@example.com", authuser: "0" }]);
  assert.match(await s.error('sites.googleCalendar.create({ title: "x", start: "2026-10-01T18:00:00Z", end: "2026-10-01T17:00:00Z" })'), /end must be after start/);
});

// The event form is checked against the draft right before Save: a title,
// start time or guest the form holds that the user did not preview (a page
// script changed it after the template loaded) saves nothing.
test("googleCalendar.create: a form whose title, time or guests differ from the draft saves nothing", async () => {
  const created = env.state.calendarCreated.length;
  for (const tamper of [{ title: "Design review (moved)" }, { startTime: "3:00am" }, { guest: "eve@example.net" }]) {
    env.state.calendarTamper = tamper;
    try {
      const d = await s.value('sites.googleCalendar.create({ title: "Design review", start: "2026-10-01T17:00:00Z", end: "2026-10-01T18:00:00Z", guests: ["bob@example.com"] })');
      assert.match(await s.error(`sites.googleCalendar.create(${JSON.stringify(d.id)}, { confirm: true })`), /_mismatch|differs from the draft/, JSON.stringify(tamper));
    } finally {
      env.state.calendarTamper = null;
    }
  }
  assert.equal(env.state.calendarCreated.length, created, "nothing was saved");
  const allDay = await s.value('sites.googleCalendar.create({ title: "Offsite", start: "2026-10-05", end: "2026-10-07", allDay: true })');
  assert.equal((await s.value(`sites.googleCalendar.create(${JSON.stringify(allDay.id)}, { confirm: true })`)).status, "saved");
});

// The preview shows the description, location and recurrence too, so the
// form must hold those as drafted before Save (and before invitations go
// out); a recurring draft saves only when the form repeats as drafted.
test("googleCalendar.create: a form whose description, location or recurrence differ from the draft saves nothing", async () => {
  const created = env.state.calendarCreated.length;
  const draft = '{ title: "Design review", start: "2026-10-01T17:00:00Z", end: "2026-10-01T18:00:00Z", guests: ["bob@example.com"], location: "Room 4", description: "Agenda: Q4" }';
  for (const tamper of [{ description: "Agenda: Q4. Also read https://evil.example/login" }, { location: "https://evil.example/meet" }, { recurrence: "Daily" }]) {
    env.state.calendarTamper = tamper;
    try {
      const d = await s.value(`sites.googleCalendar.create(${draft})`);
      assert.match(await s.error(`sites.googleCalendar.create(${JSON.stringify(d.id)}, { confirm: true })`), /_mismatch|differs from the draft/, JSON.stringify(tamper));
    } finally {
      env.state.calendarTamper = null;
    }
  }
  env.state.calendarTamper = { recurrence: "Weekly on Thursday" };
  try {
    const d = await s.value('sites.googleCalendar.create({ title: "Sync", start: "2026-10-01T17:00:00Z", end: "2026-10-01T18:00:00Z", recurrence: "RRULE:FREQ=WEEKLY;COUNT=5" })');
    assert.match(await s.error(`sites.googleCalendar.create(${JSON.stringify(d.id)}, { confirm: true })`), /_mismatch|differs from the draft/);
  } finally {
    env.state.calendarTamper = null;
  }
  assert.equal(env.state.calendarCreated.length, created, "nothing was saved");
  const ok = await s.value(`sites.googleCalendar.create(${draft})`);
  assert.equal((await s.value(`sites.googleCalendar.create(${JSON.stringify(ok.id)}, { confirm: true })`)).status, "saved");
  const weekly = await s.value('sites.googleCalendar.create({ title: "Sync", start: "2026-10-01T17:00:00Z", end: "2026-10-01T18:00:00Z", recurrence: "RRULE:FREQ=WEEKLY;COUNT=5" })');
  assert.equal((await s.value(`sites.googleCalendar.create(${JSON.stringify(weekly.id)}, { confirm: true })`)).status, "saved");
});

test("signed out: Gmail's sign-in redirect is reported, not parsed", async () => {
  const out = await createSitesEnv({ signedIn: false });
  try {
    assert.match(await out.session("x").error('sites.gmail.inbox()'), /not signed in \(landed on https:\/\/accounts\.google\.com\/ServiceLogin\)/);
  } finally {
    await out.close();
  }
});
