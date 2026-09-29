// Tab discovery, attach, popups opened by the page, close.
const first = await openTab(`${PRIMARY}/dynamic.html`);
const listed = (await listBrowserTabs()).filter((t) => t.url.startsWith(PRIMARY));
emit("listed-keys", Object.keys(listed[0]).sort());
emit("listed-count", listed.length);
const popupP = page.waitForEvent("popup");
await page.locator("#blank").click();
const popup = await popupP;
await popup.waitForLoadState();
emit("popup-title", await popup.title());
const after = (await listBrowserTabs()).filter((t) => t.url.startsWith(PRIMARY));
emit("after-count", after.length);
const target = after.find((t) => t.url.endsWith("/aria.html"));
const attached = await attachBrowserTab(target.targetId);
emit("attached-title", await page.title());
emit("tabs-length", tabs.length);
await closeTab(page);
emit("after-close", (await listBrowserTabs()).filter((t) => t.url.startsWith(PRIMARY)).length);
