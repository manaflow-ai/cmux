// A domain policy whose content rules WebKit cannot compile must not stay
// silently unenforced for subresources: every driver call of the session
// fails with the compile error until the policy changes.
// oracle: skip (the domain policy is cmux-defined)
// ---- cell session=policyrules cmux-only
const outcome = async (f) => {
  try {
    await f();
    return "done";
  } catch (e) {
    return /could not be applied/.test(e.message) ? "policy not applied" : `error: ${e.message}`;
  }
};
await page.goto(`${PRIMARY}/index.html`);
// The pattern parses, but a content-rule filter must be ASCII.
session.prohibitedDomains(["é://example.com"]);
emitCmux("next-call-fails", await outcome(() => page.title()));
emitCmux("later-calls-fail", await outcome(() => tabs.list()));
session.prohibitedDomains(null);
emitCmux("a-compiling-policy-recovers", await outcome(() => page.title()));
