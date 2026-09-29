// Real input: keyboard, hover, double click, context click, drag, wheel,
// coordinate clicks, contenteditable typing.
await openTab(`${PRIMARY}/input.html`);
await page.locator("#keys").click();
await page.keyboard.type("ab");
await page.keyboard.press("Shift+KeyC");
await page.keyboard.press("Backspace");
await page.keyboard.press("Meta+a");
emit("keys-value", await page.locator("#keys").inputValue());
await page.getByRole("button", { name: "Hover me" }).hover();
emit("hover-visible", await page.getByRole("link", { name: "Hidden item" }).isVisible());
await page.locator("#dbl").dblclick();
emit("dbl", await page.locator("#dbl").textContent());
await page.locator("#ctx").click({ button: "right" });
emit("ctx", await page.locator("#ctx").textContent());
await page.locator("#drag").dragTo(page.locator("#drop"));
emit("drop", await page.locator("#drop").textContent());
const box = await page.locator("#canvas").boundingBox();
await page.mouse.click(box.x + box.width - 20, box.y + 20);
emit("canvas", await page.locator("#canvas-hit").textContent());
await page.locator("#scroller").hover();
await page.mouse.wheel(0, 300);
emit("scrolled", (await page.locator("#scroller").evaluate((e) => e.scrollTop)) > 0);
await page.locator("#editor").click();
await page.keyboard.press("End");
await page.keyboard.type(" typed");
emit("editor", await page.locator("#editor").textContent());
emit("untrusted-events", await page.evaluate(() => window.__summary().filter((l) => l.includes("UNTRUSTED"))));
