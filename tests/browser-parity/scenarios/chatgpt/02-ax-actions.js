// Index-addressed actions and the revision diff.
const browser = await agent.browsers.getDefault();
const tab = await browser.tabs.new();
await tab.goto(`${PRIMARY}/`);
const s1 = await tab.ax.get("state", { disableDiffing: true });
const idx = (re) => Number(s1.split("\n").find((l) => re.test(l)).trim().split(" ")[0]);
await tab.ax.setValue(idx(/text field .*Email/), "me@x.com");
await tab.ax.click(idx(/checkbox .*Accept terms/));
await tab.ax.click(idx(/button Create account/));
emit("diff", await tab.ax.get());
emit("result", await tab.playwright.locator("#ok").textContent());
emit("trusted-log", await tab.playwright.evaluate(() => window.__summary().filter((l) => /^(click|change|input) /.test(l))));
await tab.ax.typeText(idx(/text entry area .*Bio/), " there");
await tab.ax.pressKey(null, "Tab");
emit("after-type", await tab.playwright.locator("#bio").inputValue());
await tab.ax.scroll(idx(/button Far away/), "down", 1);
emit("focused-diff", await tab.ax.get());
await tab.close();
