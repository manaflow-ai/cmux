// Same-origin and cross-origin iframes in snapshot and actions.
await openTab(`${PRIMARY}/frames.html?peer=${encodeURIComponent(PEER)}`);
await page.waitForLoadState("load");
const s1 = await snapshot(page);
emit("full", s1.tree);
const refs = [...s1.tree.matchAll(/button "Inside frame" \[ref=(\w+)\]/g)].map((m) => m[1]);
emit("frame-button-count", refs.length);
for (const r of refs) await page.locator(r).click();
const s2 = await snapshot(page);
emit("after-clicks", s2.tree);
await page.frameLocator("#cross").locator("#inner-input").fill("cross value");
emit("cross-fill", await page.frameLocator("#cross").locator("#inner-input").inputValue());
