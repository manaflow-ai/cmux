// Where a session's behavior stops: what a tab the session opened inherits,
// and what a tab it only drives keeps from the user.
// oracle: skip (session and tab ownership are cmux-defined)
// ---- cell session=store cmux-only
// A tab opened after session.configure({ proxy }) uses a private data store.
// A link it opens in a new tab (Meta+click) must use that store too, so the
// session's cookies follow and the user's profile stays out. The dev driver
// has one context and no proxy, so there the store is shared anyway.
try {
  await session.configure({ proxy: { server: PRIMARY } });
} catch (e) {
  if (e.code !== "unsupported") throw e;
}
const storeOpener = await tabs.open(`${PRIMARY}/index.html?store-opener`);
await storeOpener.evaluate((href) => {
  document.cookie = "brepl_store=session; path=/";
  const a = document.createElement("a");
  a.id = "to-store-popup";
  a.href = href;
  a.textContent = "Store popup";
  document.body.prepend(a);
}, `${PRIMARY}/dynamic.html?store-popup`);
await storeOpener.locator("#to-store-popup").click({ modifiers: ["Meta"] });
let storeRow = null;
for (let i = 0; i < 100 && !storeRow; i++) {
  storeRow = (await tabs.list()).find((t) => t.url.endsWith("?store-popup"));
  if (!storeRow) await sleep(50);
}
const storePopup = storeRow && (await tabs.get(storeRow.id));
if (storePopup) await storePopup.waitForLoadState();
emitCmux("popup-store-cookie", storePopup ? await storePopup.evaluate(() => document.cookie.split("; ").filter((c) => c.startsWith("brepl_store="))) : "no popup");
if (storePopup) await storePopup.close();
await storeOpener.close();
await session.configure({ proxy: null });
