// Site helpers that post or send (sites.x.post, sites.linkedin.post,
// sites.gmail.send) check that the composer holds the whole draft before
// they press Post or Send, never only its start. The helpers open the real
// sites; here each site URL is answered by fixtures/composer.html, which
// imitates that site's composer (no account, no real post).
// oracle: skip (site helpers are cmux-defined)
// ---- cell session=composers cmux-only
const Page = page.constructor.prototype;
const realGoto = Page.goto;
let tamper = false;
Page.goto = function (url, options) {
  const u = new URL(String(url));
  let local = null;
  if (u.host === "x.com" && u.pathname === "/intent/post") local = `site=x&text=${encodeURIComponent(u.searchParams.get("text") || "")}`;
  else if (u.host === "www.linkedin.com" && u.pathname === "/feed/") local = `site=linkedin&text=${encodeURIComponent(u.searchParams.get("text") || "")}`;
  else if (u.host === "mail.google.com" && u.searchParams.get("view") === "cm") local = `site=gmail&body=${encodeURIComponent(u.searchParams.get("body") || "")}`;
  if (local) url = `${PRIMARY}/composer.html?${local}${tamper ? "&tamper=1" : ""}`;
  return realGoto.call(this, url, options);
};
const draftText = "A post the user approved, with a link https://example.com/a and a long ending that must arrive whole.";
const run = async (make, args) => {
  const results = [];
  for (const t of [false, true]) {
    tamper = t;
    const draft = await make(...args);
    results.push(await make(draft.id, { confirm: true }).then((r) => r.status, (e) => `${e.code || e.name}: ${/differ at character \d+/.test(e.message) ? "differs" : e.message}`));
  }
  return results;
};
try {
  emitCmux("x-post", await run((...a) => sites.x.post(...a), [draftText]));
  emitCmux("linkedin-post", await run((...a) => sites.linkedin.post(...a), [draftText]));
  emitCmux("gmail-send", await run((...a) => sites.gmail.send(...a), [{ to: "someone@example.com", subject: "Hi", body: draftText }]));
  // Gmail draws an emoji as an image; its alt text is part of the body.
  tamper = false;
  const emoji = await sites.gmail.send({ to: "someone@example.com", subject: "Hi", body: "Thanks 🙂 see you" });
  emitCmux("gmail-emoji", await sites.gmail.send(emoji.id, { confirm: true }).then((r) => r.status, (e) => e.code || e.message));
} finally {
  Page.goto = realGoto;
}
