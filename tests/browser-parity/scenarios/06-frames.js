// Same-origin and cross-origin iframes: snapshot, ref actions inside frames,
// frame locators, and trusted input into the cross-origin frame.
await page.goto(`${PRIMARY}/frames.html?peer=${encodeURIComponent(PEER)}`);
await page.waitForLoadState("load");
const s1 = await snapshot();
emitCmux("full", s1.tree);
const refs = [...s1.tree.matchAll(/button "Inside frame" \[ref=(\w+)\]/g)].map((m) => m[1]);
emit("frame-button-count", refs.length);
for (const r of refs) await page.locator(r).click();
emit("same-clicked", await page.frameLocator("#same").locator("#inner-btn").textContent());
emit("cross-clicked", (await page.frameLocator("#cross").locator("#inner-btn").textContent()).replace(/\d+$/, "PORT"));
emitCmux("after-clicks", (await snapshot()).tree);
const crossField = [...s1.tree.matchAll(/textbox "Frame field" \[ref=(\w+)\]/g)].map((m) => m[1])[1];
await page.locator(crossField).click();
await page.keyboard.type("typed across");
emit("cross-typed", await page.frameLocator("#cross").locator("#inner-input").inputValue());
await page.frameLocator("#cross").locator("#inner-input").fill("cross value");
emit("cross-fill", await page.frameLocator("#cross").locator("#inner-input").inputValue());
await page.frameLocator("#same").getByRole("textbox", { name: "Frame field" }).fill("same value");
emit("same-fill", await page.frameLocator("#same").locator("#inner-input").inputValue());
emit("cross-trusted", await page.frameLocator("#cross").locator("body").evaluate(() => window.__summary().filter((l) => /^(click|keydown) /.test(l)).every((l) => !l.includes("UNTRUSTED"))));
