// One-shot runs close their tabs unless kept; named sessions keep bindings
// and tabs across calls.
// oracle: skip (session lifetime is cmux-defined)
await page.goto(`${PRIMARY}/aria.html?oneshot`);
const kept = await tabs.open(`${PRIMARY}/dynamic.html?kept`);
await kept.keep();
await tabs.open(`${PRIMARY}/dynamic.html?closed`, { background: true });
emitCmux("open-during-run", (await tabs.list()).filter((t) => t.url.startsWith(PRIMARY)).map((t) => t.url).sort());
// ---- cell
emitCmux("after-one-shot", (await tabs.list()).filter((t) => t.url.startsWith(PRIMARY)).map((t) => t.url).sort());
const keptTab = (await tabs.list()).find((t) => t.url.endsWith("?kept"));
await tabs.use(keptTab.id);
emitCmux("attach-kept", await page.title());
await page.close();
// ---- cell session=work
emitCmux("session-name", await session.name("parity work"));
emitCmux("guide", /snapshot\(/.test(session.guide()));
const counter = { n: 1 };
let label = "first";
await page.goto(`${PRIMARY}/aria.html?named`);
// ---- cell session=work
counter.n++;
emitCmux("bindings-persist", [counter.n, label]);
emitCmux("page-persists", page.url().endsWith("?named"));
function helper() { return counter.n * 10; }
// ---- cell session=work
emitCmux("functions-persist", helper());
emitCmux("session-id", typeof session.id);
// ---- cell
emitCmux("named-tabs-open", (await tabs.list()).filter((t) => t.url.startsWith(PRIMARY)).map((t) => t.url).sort());
