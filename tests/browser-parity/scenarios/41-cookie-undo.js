// context.clearCookies() is undoable: it answers restore ids, and
// context.restoreCookies(result) puts the cleared cookies back in the store
// they came from. A cookie set again since the clear is kept, not
// overwritten. A restore id works once. On the app's tabs the store is the
// person's profile, so the app keeps the backup (bead cx-qkd).
// oracle: skip (undo of a clear is cmux-defined)
// ---- cell session=cookieundo cmux-only
const site = (c) => {
  const host = String(c.domain).replace(/^\./, "");
  return host === new URL(PRIMARY).hostname ? "primary" : host === new URL(PEER).hostname ? "peer" : null;
};
const jar = async () => (await page.context().cookies()).filter(site).map((c) => `${site(c)} ${c.name}`).sort();
await page.goto(`${PRIMARY}/set-cookie`);
await page.context().addCookies([
  { name: "u1", value: "1", url: `${PRIMARY}/` }, { name: "u2", value: "old", url: `${PRIMARY}/` },
]);
emitCmux("start", await jar());
const cleared = await page.context().clearCookies();
emitCmux("restore-ids", cleared.restoreIds.length);
emitCmux("cleared", await jar());
await page.context().addCookies([{ name: "u2", value: "new", url: `${PRIMARY}/` }]);
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
