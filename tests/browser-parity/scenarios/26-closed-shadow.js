// Closed shadow roots, top level and nested in an open root: the snapshot,
// refs and locators reach inside, as an accessibility tree does. Playwright
// does not pierce closed roots, so this scenario is cmux-owned.
// oracle: skip (Playwright locators do not enter closed shadow roots)
await page.goto(`${PRIMARY}/closed-shadow.html`);
const s = await snapshot();
emitCmux("full", s.tree);
const input = s.tree.match(/textbox "Closed input" \[ref=(\w+)\]/)[1];
await page.locator(input).fill("typed");
emitCmux("ref-fill", await page.locator(input).inputValue());
await page.getByRole("button", { name: "Closed button" }).click();
emitCmux("locator-click", await page.locator("#out").textContent());
emitCmux("nested-link", await page.getByRole("link", { name: "Nested closed link" }).count());
emitCmux("css-pierces", await page.locator("#ci").count());
