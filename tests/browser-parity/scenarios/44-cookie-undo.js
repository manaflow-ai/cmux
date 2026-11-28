// context.clearCookies() clears the tab's site only and is undoable: it
// answers restore ids, and context.restoreCookies(result) puts the cleared
// cookies back in the store they came from. Another site's cookies are never
// touched. A cookie set again since the clear is kept, not overwritten. A
// restore id works once. On the app's tabs the store is the person's
// profile, so the app keeps the backup (bead cx-qkd). The page sets the
// cookies itself, so no cookies.set is needed.
// oracle: skip (undo of a clear is cmux-defined)
// ---- cell session=cookieundo cmux-only
const site = (c) => {
  const host = String(c.domain).replace(/^\./, "");
  return host === new URL(PRIMARY).hostname ? "primary" : host === new URL(PEER).hostname ? "peer" : null;
};
const jar = async () => (await page.context().cookies()).filter(site).map((c) => `${site(c)} ${c.name}`).sort();
await page.goto(`${PEER}/set-cookie`);
await page.goto(`${PRIMARY}/set-cookie`);
await page.evaluate(() => { document.cookie = "u1=1; path=/"; document.cookie = "u2=old; path=/"; });
emitCmux("start", await jar());
const cleared = await page.context().clearCookies();
emitCmux("restore-ids", cleared.restoreIds.length);
emitCmux("cleared", await jar());
await page.evaluate(() => { document.cookie = "u2=new; path=/"; });
emitCmux("restore", await page.context().restoreCookies(cleared));
emitCmux("restored", await jar());
emitCmux("set-since-kept", (await page.context().cookies()).find((c) => site(c) === "primary" && c.name === "u2")?.value);
let again;
try {
  await page.context().restoreCookies(cleared);
  again = "restored twice";
} catch (e) {
  again = e.code || (/backup/.test(e.message) ? "invalid" : `error: ${e.message}`);
}
emitCmux("second-restore", again);
await page.context().clearCookies({ name: /^u[12]$/ });
