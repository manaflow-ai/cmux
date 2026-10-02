// The per-tab virtual clipboard: read/write from the REPL, and Meta+C,
// Meta+X and Meta+V in the page. The system clipboard is never used.
// oracle: skip (the virtual clipboard is cmux-defined)
await page.goto(`${PRIMARY}/input.html`);
await page.clipboard.writeText("clip text");
emitCmux("read-text", await page.clipboard.readText());
await page.locator("#clip").click();
await page.keyboard.press("Meta+v");
emitCmux("pasted", await page.locator("#clip").inputValue());
await page.locator("#keys").fill("copy me");
await page.locator("#keys").selectText();
await page.keyboard.press("Meta+c");
emitCmux("copied", await page.clipboard.readText());
await page.keyboard.press("Meta+x");
emitCmux("cut", [await page.clipboard.readText(), await page.locator("#keys").inputValue()]);
await page.clipboard.write([{ type: "text/plain", data: "via write" }]);
const items = await page.clipboard.read();
emitCmux("read-items", items.map((i) => [i.type, i.data.toString()]));
emitCmux("trusted-paste", await page.evaluate(() => window.__summary().filter((l) => /^(input) #clip/.test(l))));
