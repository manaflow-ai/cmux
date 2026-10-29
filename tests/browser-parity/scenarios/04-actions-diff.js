// Actions addressed by snapshot refs, then how a snapshot prints: the diff
// when it saves at least 30% over the tree, the tree otherwise.
await page.goto(`${PRIMARY}/`);
const s1 = await snapshot();
const ref = (re) => s1.tree.split("\n").find((l) => re.test(l)).match(/\[ref=(\w+)\]/)[1];
await page.locator(ref(/textbox "Email"/)).fill("me@x.com");
await page.locator(ref(/checkbox "Accept terms"/)).click();
await page.locator(ref(/combobox "Plan"/)).selectOption("Team");
await page.ref(ref(/button "Create account"/)).click();
emit("result", await page.locator("#ok").textContent());
emit("trusted-log", await page.evaluate(() => window.__summary().filter((l) => /^(click|change|input) /.test(l))));
emitCmux("after-actions", (await snapshot()).tree);
// Printing: a small change on a larger page prints the diff; a rewrite of the
// page prints the tree.
await page.goto(`${PRIMARY}/aria.html`);
await snapshot();
await page.evaluate(() => { document.querySelector("h3").textContent = "Level three renamed"; document.querySelector("#for-input").value = "changed"; });
const small = await snapshot();
emitCmux("small-change-prints-diff", small.usesDiff);
emitCmux("small-change", String(small));
emitCmux("no-change", String(await snapshot()));
await page.evaluate(() => { document.querySelector("main").innerHTML = "<h1>Replaced</h1><p>New content</p>"; });
const large = await snapshot();
emitCmux("large-change-prints-diff", large.usesDiff);
emitCmux("large-change", String(large));
emitCmux("large-change-diff", large.diff);
