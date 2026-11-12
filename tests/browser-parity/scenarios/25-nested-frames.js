// Three nested iframes that alternate origins (primary > peer > primary >
// peer) plus a srcdoc frame: frameLocator chains, refs three frames deep,
// trusted input, and a closed shadow root in the deepest frame.
await page.goto(`${PRIMARY}/nest-top.html`);
const deep = page.frameLocator("#l1").frameLocator("#l2").frameLocator("#l3");
await deep.getByRole("button", { name: "Deep button" }).click();
emit("deep-chain-click", await deep.locator("#deep").textContent());
await page.frameLocator("#srcdoc").getByRole("button", { name: "Srcdoc button" }).click();
emit("srcdoc-click", await page.frameLocator("#srcdoc").locator("button").textContent());
await page.frameLocator("#l1").getByRole("textbox", { name: "L1 field" }).fill("level one");
emit("l1-fill", await page.frameLocator("#l1").locator("input").inputValue());
emit("frame-count", page.frames().length);
emit("deep-frame-url", page.frames().map((f) => f.url()).filter((u) => u.endsWith("/nest-l3.html")).length);
// ---- cell
await page.goto(`${PRIMARY}/nest-top.html`);
const deepButton = page.frameLocator("#l1").frameLocator("#l2").frameLocator("#l3").getByRole("button", { name: "Deep button" });
await deepButton.waitFor();
const s = await snapshot();
const ref = s.tree.match(/button "Deep button" \[ref=(\w+)\]/)[1];
await page.locator(ref).click();
emit("deep-ref-click", await page.frameLocator("#l1").frameLocator("#l2").frameLocator("#l3").locator("#deep").textContent());
// ---- cell cmux-only
await page.goto(`${PRIMARY}/nest-top.html`);
const l3 = page.frameLocator("#l1").frameLocator("#l2").frameLocator("#l3");
await l3.getByRole("button", { name: "Deep button" }).waitFor();
const s = await snapshot();
emitCmux("full", s.tree.replace(/"level one"/, ""));
await l3.getByRole("button", { name: "Closed shadow button" }).click();
emitCmux("closed-in-frame-click", await l3.getByRole("button", { name: /closed clicked/ }).textContent());
const closedRef = (await snapshot()).tree.match(/button "closed clicked true" \[ref=(\w+)\]/);
emitCmux("closed-in-frame-ref", !!closedRef);
