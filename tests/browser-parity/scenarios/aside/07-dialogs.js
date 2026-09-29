// JavaScript dialogs.
await openTab(`${PRIMARY}/dialogs.html`);
const seen = [];
page.on("dialog", async (d) => { seen.push(`${d.type()}:${d.message()}:${d.defaultValue?.() ?? ""}`); if (d.type() === "prompt") await d.accept("typed answer"); else if (d.type() === "confirm") await d.dismiss(); else await d.accept(); });
await page.locator("#alert").click();
emit("after-alert", await page.locator("#r").textContent());
await page.locator("#confirm").click();
emit("after-confirm", await page.locator("#r").textContent());
await page.locator("#prompt").click();
emit("after-prompt", await page.locator("#r").textContent());
emit("dialogs", seen);
