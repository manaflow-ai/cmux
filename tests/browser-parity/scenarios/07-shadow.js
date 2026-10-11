// Open shadow roots are pierced by the snapshot, refs and locators.
await page.goto(`${PRIMARY}/shadow.html`);
const s1 = await snapshot();
emitCmux("full", s1.tree);
const input = s1.tree.match(/textbox "Shadow input" \[ref=(\w+)\]/)[1];
await page.locator(input).fill("inside");
await page.getByRole("button", { name: "Shadow button" }).click();
emit("out", await page.locator("#out").textContent());
