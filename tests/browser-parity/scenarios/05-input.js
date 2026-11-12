// Real input: keyboard combos, hover, double click, context click, drag,
// coordinate clicks, wheel and contenteditable typing; every event trusted.
// ---- cell session=input
await page.goto(`${PRIMARY}/input.html`);
await page.locator("#keys").click();
await page.keyboard.type("ab");
await page.keyboard.press("Shift+KeyC");
await page.keyboard.press("Backspace");
await page.keyboard.press("ArrowLeft");
await page.keyboard.press("Shift+ArrowRight");
await page.keyboard.type("Z");
emit("keys-value", await page.locator("#keys").inputValue());
await page.keyboard.press("Meta+a");
await page.keyboard.press("Delete");
emit("select-all-delete", await page.locator("#keys").inputValue());
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
await page.waitForFunction(() => document.getElementById("scroller").scrollTop > 0);
emit("scrolled", (await page.locator("#scroller").evaluate((e) => e.scrollTop)) > 0);
await page.locator("#editor").click();
await page.keyboard.press("End");
await page.keyboard.type(" typed");
emit("editor", await page.locator("#editor").textContent());
emit("trusted-types", await page.evaluate(() => [...new Set(window.__log.filter((e) => e.trusted).map((e) => e.type))].sort()));
emit("untrusted-events", await page.evaluate(() => window.__summary().filter((l) => l.includes("UNTRUSTED"))));
// ---- cell session=input cmux-only
// page.elementAt has no Playwright counterpart.
const canvasBox = await page.locator("#canvas").boundingBox();
const hit = await page.elementAt(canvasBox.x + 10, canvasBox.y + 10);
// Form-control metrics differ between WebKit builds, so the box is compared
// with the locator's box instead of absolute coordinates.
const sameBox = ["x", "y", "width", "height"].every((k) => Math.abs(hit.box[k] - canvasBox[k]) < 0.5);
emitCmux("element-at-canvas", { ref: hit.ref, role: hit.role, name: hit.name, sameBox });
const btn = await page.locator("#dbl").boundingBox();
const at = await page.elementAt(btn.x + 2, btn.y + 2);
emitCmux("element-at-button", { role: at.role, name: at.name });
await page.locator(at.ref).click();
emitCmux("element-at-ref-clicks", await page.evaluate(() => window.__summary().filter((l) => l === "click #dbl").length));
