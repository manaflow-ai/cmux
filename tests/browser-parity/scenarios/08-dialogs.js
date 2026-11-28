// JavaScript dialogs with a "dialog" listener: Playwright semantics.
await page.goto(`${PRIMARY}/dialogs.html`);
const seen = [];
page.on("dialog", async (d) => {
  seen.push(`${d.type()}:${d.message()}:${d.defaultValue()}`);
  if (d.type() === "prompt") await d.accept("typed answer");
  else if (d.type() === "confirm") await d.dismiss();
  else await d.accept();
});
await page.locator("#alert").click();
emit("after-alert", await page.locator("#r").textContent());
await page.locator("#confirm").click();
emit("after-confirm", await page.locator("#r").textContent());
await page.locator("#prompt").click();
emit("after-prompt", await page.locator("#r").textContent());
emit("dialogs", seen);
emit("none-open", page.dialog());
page.removeAllListeners("dialog");
const waited = page.waitForEvent("dialog");
page.locator("#confirm").click().catch(() => {});
const d = await waited;
emit("wait-for-event", [d.type(), d.message()]);
await d.accept();
emit("after-wait-accept", await page.locator("#r").textContent());
