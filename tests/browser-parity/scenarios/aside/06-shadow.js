// Open shadow roots are pierced by snapshot and locators.
await openTab(`${PRIMARY}/shadow.html`);
const s1 = await snapshot(page);
emit("full", s1.tree);
await page.getByRole("textbox", { name: "Shadow input" }).fill("inside");
await page.getByRole("button", { name: "Shadow button" }).click();
emit("out", await page.locator("#out").textContent());
