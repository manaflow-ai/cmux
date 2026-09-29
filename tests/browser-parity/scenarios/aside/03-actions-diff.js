// Ref-addressed actions, then the diff representation after the page changes.
await openTab(`${PRIMARY}/`);
const s1 = await snapshot(page, { interactive: true });
const ref = (re) => s1.tree.split("\n").find((l) => re.test(l)).match(/\[ref=(\w+)\]/)[1];
await page.locator(ref(/textbox "Email"/)).fill("me@x.com");
await page.locator(ref(/checkbox "Accept terms"/)).click();
await page.locator(ref(/combobox/)).selectOption("Team");
await page.locator(ref(/button "Create account"/)).click();
const s2 = await snapshot(page, { interactive: true });
emit("diff", s2.diff);
emit("result", await page.locator("#ok").textContent());
emit("trusted-log", await page.evaluate(() => window.__summary().filter((l) => /^(click|change|input) /.test(l))));
