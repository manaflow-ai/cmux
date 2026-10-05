// Dialogs without a listener stay open: the snapshot shows them, page script
// calls fail with the way out, and page.dialog() answers them.
// oracle: skip (Playwright dismisses dialogs nobody listens for)
await page.goto(`${PRIMARY}/dialogs.html`);
await page.locator("#confirm").click();
emitCmux("snapshot", (await snapshot()).tree);
const d = page.dialog();
emitCmux("dialog", { type: d.type, message: d.message, defaultValue: d.defaultValue });
try {
  await page.locator("#r").textContent();
  emitCmux("blocked", "no error");
} catch (e) {
  emitCmux("blocked", e.message);
}
try {
  await page.evaluate(() => 1);
  emitCmux("blocked-evaluate", "no error");
} catch (e) {
  emitCmux("blocked-evaluate", e.message);
}
await d.accept();
emitCmux("after-accept", await page.locator("#r").textContent());
emitCmux("closed", page.dialog());
await page.locator("#prompt").click();
emitCmux("prompt-line", (await snapshot()).tree.split("\n")[2]);
await page.dialog().accept("from agent");
emitCmux("after-prompt", await page.locator("#r").textContent());
await page.locator("#prompt").click();
await page.dialog().dismiss();
emitCmux("prompt-dismissed", await page.locator("#r").textContent());
await page.locator("#alert").focus();
await page.keyboard.press("Enter");
emitCmux("keyboard-opened", page.dialog() && page.dialog().type);
await page.dialog().dismiss();
emitCmux("after-alert", await page.locator("#r").textContent());
await page.evaluate(() => setTimeout(() => confirm("Later"), 50));
await page.waitForTimeout(300);
emitCmux("timer-dialog", page.dialog() && page.dialog().message);
await page.dialog().dismiss();
emitCmux("after-timer", (await snapshot()).tree.split("\n").length > 2);
