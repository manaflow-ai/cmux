// States, values, tables, links and whitespace on the states fixture.
// oracle: skip (snapshot text is cmux-defined)
await page.goto(`${PRIMARY}/states.html?peer=${encodeURIComponent(PEER)}`);
emitCmux("full", (await snapshot()).tree);
emitCmux("options", (await snapshot({ options: true })).tree.split("\n").filter((l) => /combobox|option/.test(l)));
await page.locator("#name").fill("x");
await page.locator("#name").fill("");
await page.locator("#code").focus();
emitCmux("user-invalid", (await snapshot()).tree.split("\n").filter((l) => /textbox "(Name|Code)"/.test(l)));
