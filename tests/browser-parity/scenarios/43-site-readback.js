// Site helpers that send or save (sites.gmail.send, a Gmail reply, and
// sites.googleCalendar.create) read back what the page holds right before
// they press Send or Save (recipients as address sets and the subject; the
// event's title, start and end in its time zone, and its guests) and refuse
// when it is not the draft. The real site URLs are answered by
// fixtures/site-forms.html, which imitates each form (no account, nothing
// sent).
// oracle: skip (site helpers are cmux-defined)
// ---- cell session=readback cmux-only
const Page = page.constructor.prototype;
const realGoto = Page.goto;
let tamper = "";
Page.goto = function (url, options) {
  const u = new URL(String(url));
  let local = null;
  if (u.host === "mail.google.com" && u.searchParams.get("view") === "cm") local = `site=gmail&${u.searchParams}`;
  else if (u.host === "mail.google.com" && u.hash.startsWith("#all/")) local = "site=gmail-thread";
  else if (u.host === "calendar.google.com" && u.pathname === "/calendar/render") local = `site=calendar&${u.searchParams}`;
  if (local) url = `${PRIMARY}/site-forms.html?${local}${tamper ? `&tamper=${tamper}` : ""}`;
  return realGoto.call(this, url, options);
};
// Each case: the draft is made on the honest page, the confirm runs with
// the page changed as `tamper` says ("" = unchanged).
const outcome = (e) => `${e.code || e.name}: ${(/the page does not hold the drafted ([a-z]+)/.exec(e.message) || [])[1] || e.message.slice(0, 120)}`;
const run = async (make, input, cases) => {
  const out = {};
  for (const c of cases) {
    tamper = "";
    const draft = await make(input);
    tamper = c;
    out[c || "honest"] = await make(draft.id, { confirm: true }).then((r) => r.status, outcome);
  }
  tamper = "";
  return out;
};
try {
  const mail = { to: "Someone@Example.com", cc: "copy@example.com", subject: "Quarterly numbers", body: "The numbers are attached." };
  emitCmux("gmail-new", await run((...a) => sites.gmail.send(...a), mail, ["", "to", "bcc", "subject", "outside"]));
  emitCmux("gmail-reply", await run((...a) => sites.gmail.send(...a), { threadId: "thread-f:1784000000000000000", body: "Thanks, see you then." }, ["", "cc"]));
  const event = { title: "Planning", start: "2026-10-01T15:00:00Z", end: "2026-10-01T16:00:00Z", timeZone: "Europe/Berlin", guests: ["Guest@Example.com"] };
  emitCmux("calendar-create", await run((...a) => sites.googleCalendar.create(...a), event, ["", "title", "time", "guest", "late"]));
} finally {
  Page.goto = realGoto;
}
