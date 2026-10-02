// context.clearCookies() clears the current tab's site, not the user's whole
// profile: a name or RegExp filter stays on that site, and another site's
// cookies survive. Playwright clears the whole (throwaway) context instead.
// oracle: skip (cookie scope is cmux-defined: driven tabs use the user's profile)
// ---- cell session=cookies
const site = (c) => {
  const host = String(c.domain).replace(/^\./, "");
  return host === new URL(PRIMARY).hostname ? "primary" : host === new URL(PEER).hostname ? "peer" : null;
};
const jar = async () => (await page.context().cookies()).filter(site).map((c) => `${site(c)} ${c.name}`).sort();
await page.goto(`${PRIMARY}/set-cookie`);
const peerTab = await tabs.open(`${PEER}/set-cookie`);
await page.context().addCookies([
  { name: "a1", value: "1", url: `${PRIMARY}/` }, { name: "a2", value: "1", url: `${PRIMARY}/` },
  { name: "b1", value: "1", url: `${PEER}/` },
]);
emitCmux("start", await jar());
await page.context().clearCookies({ name: "a1" });
emitCmux("by-name", await jar());
await page.context().clearCookies({ name: /^(parity|b1)$/ });
emitCmux("by-regexp", await jar());
await page.context().clearCookies();
emitCmux("this-site", await jar());
await peerTab.context().clearCookies();
emitCmux("peer-site", await jar());
await peerTab.close();
