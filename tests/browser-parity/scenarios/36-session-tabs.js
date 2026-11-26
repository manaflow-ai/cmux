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
// ---- cell cmux-only
// A one-shot run opens and keeps a tab; once the run ends the tab is the
// user's, and the next session only drives it.
const keptForUser = await tabs.open(`${PRIMARY}/dialogs.html?user-owned`);
await keptForUser.keep();
// ---- cell session=agent cmux-only
// A session driving a user's tab does not answer that tab's permission
// requests from session.configure: notifications stay denied, as cmux
// answers them for a tab no session drives. Events the agent registered a
// handler for on that page (a dialog, a download) still reach the session.
// Without a handler they go to the user's own UI, which a check cannot
// answer; unit/tab-ownership.test.mjs covers that on the dev driver.
const userRow = (await tabs.list()).find((t) => t.url.endsWith("?user-owned"));
const userTab = await tabs.use(userRow.id);
await session.configure({ permissions: ["notifications"] });
emitCmux("user-tab-notifications", await userTab.evaluate(() => Notification.requestPermission()));
userTab.once("dialog", (d) => d.accept());
await userTab.locator("#confirm").click();
emitCmux("user-tab-dialog-listener", await userTab.locator("#r").textContent());
await userTab.goto(`${PRIMARY}/files.html?user-owned`);
const userDownload = userTab.waitForEvent("download");
await userTab.locator("#dl").click();
emitCmux("user-tab-download-listener", (await userDownload).suggestedFilename());
await userTab.close();
await session.configure({ permissions: null });
// ---- cell cmux-only
// A run that ends with a key or mouse button still pressed must release
// them: the page gets keyup and mouseup, so it is not left mid-drag or with
// Shift held for the user.
const heldTab = await tabs.open(`${PRIMARY}/input.html?held`);
await heldTab.keep();
await heldTab.locator("#keys").click();
await heldTab.evaluate(() => { window.__log.length = 0; });
await heldTab.keyboard.down("Shift");
await heldTab.keyboard.down("KeyA");
const heldBox = await heldTab.locator("h1").boundingBox();
await heldTab.mouse.move(heldBox.x + 5, heldBox.y + 5);
await heldTab.mouse.down();
// ---- cell cmux-only
const heldRow = (await tabs.list()).find((t) => t.url.endsWith("?held"));
const heldAfter = await tabs.use(heldRow.id);
emitCmux("released-on-session-end", await heldAfter.evaluate(() => window.__log.filter((e) => e.type === "keyup" || e.type === "mouseup").map((e) => `${e.type} ${e.type === "mouseup" ? e.button : e.key} ${e.trusted}`).sort()));
await heldAfter.close();
