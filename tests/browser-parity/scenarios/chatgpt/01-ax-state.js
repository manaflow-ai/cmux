// Numbered accessibility tree: full state on two fixtures, then the
// no-change result.
const browser = await agent.browsers.getDefault();
const tab = await browser.tabs.new();
await tab.goto(`${PRIMARY}/`);
emit("index-full", await tab.ax.get("state", { disableDiffing: true }));
emit("index-unchanged", await tab.ax.get());
await tab.goto(`${PRIMARY}/aria.html`);
emit("aria-full", await tab.ax.get("state", { disableDiffing: true }));
await tab.close();
