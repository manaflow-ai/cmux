import { errorsBetter as errBetter } from "../lib.mjs";
// Locator members: Aside Locator.* and ChatGPT PlaywrightLocator.*, with
// the option and error variants the ChatGPT reference was verified on
// (cmux-browser-cli scripts/cua-reference-variant-cases.ts), ported to the
// lab page.
const LAB = "/diff/lab.html";
const FILES = "/diff/files.html";
// Events on #action since the last read: [type, button, detail, alt, ctrl, meta, shift].
const TAKE = `let seen = 0;
const take = async () => { const all = $LOG.filter((r) => r[1] === "action"); const d = all.slice(seen); seen = all.length; return d.map((r) => [r[0], ...r[3]]); };`;
const clickOptions = (method) => ({
  id: `loc.${method}.options`,
  members: [`aside:Locator.${method}`, `chatgpt:PlaywrightLocator.${method}`],
  path: LAB,
  better: {
    aside: {
      reason: "button and modifier options reach the page (right, middle, Alt, Control, Meta, Shift); Aside sends a plain left click for every option",
      check: (c, r) => JSON.stringify(c.right).includes("contextmenu") && !JSON.stringify(r.right).includes("contextmenu") && JSON.stringify(c.left) === JSON.stringify(r.left),
    },
  },
  code: `${TAKE}
const l = $P.locator("#action");
const out = {};
for (const [k, o] of [["left", { button: "left" }], ["right", { button: "right" }], ["middle", { button: "middle" }], ["force", { force: true }], ["timeout", $T(2000)],
  ["alt", { modifiers: ["Alt"] }], ["control", { modifiers: ["Control"] }], ["controlOrMeta", { modifiers: ["ControlOrMeta"] }], ["meta", { modifiers: ["Meta"] }], ["shift", { modifiers: ["Shift"] }]]) {
  const r = await E(() => l.${method}(o));
  out[k] = r.error ? r : await take();
}
return out;`,
});

export default [
  clickOptions("click"),
  clickOptions("dblclick"),
  {
    id: "loc.click.more-options",
    members: ["aside:Locator.click"],
    path: LAB,
    code: `${TAKE}
const l = $P.locator("#action");
const out = {};
await l.click({ clickCount: 2 }); out.clickCount = await take();
await l.click({ position: { x: 2, y: 2 } }); out.position = (await take()).length;
const d = await ms(() => l.click({ delay: 300 })); out.delay = d.ms >= 280; await take();
await l.click({ trial: true }); out.trial = await take();
await l.click({ noWaitAfter: true }); out.noWaitAfter = (await take()).length;
return out;`,
    chatgpt: null,
    na: { chatgpt: "LocatorClickOptions has no clickCount, position, delay or trial" },
    better: {
      aside: {
        reason: "clickCount, position, delay and trial behave as in Playwright; Aside ignores trial and clicks anyway",
        check: (c, r) => Array.isArray(c.trial) && c.trial.length === 0 && Array.isArray(r.trial) && r.trial.length > 0,
      },
    },
    expect: { position: 3, delay: true, trial: [], noWaitAfter: 3 },
  },
  {
    id: "loc.check.options",
    members: ["aside:Locator.check", "aside:Locator.uncheck", "aside:Locator.setChecked", "chatgpt:PlaywrightLocator.check", "chatgpt:PlaywrightLocator.uncheck", "chatgpt:PlaywrightLocator.setChecked"],
    path: LAB,
    code: `const l = $P.locator("#check");
const s = () => l.evaluate((e) => e.checked);
const out = [];
await l.check({ force: true }); out.push(await s());
await l.uncheck({ force: true }); out.push(await s());
await l.check($T(2000)); out.push(await s());
await l.uncheck($T(2000)); out.push(await s());
await l.setChecked(true, { force: true }); out.push(await s());
await l.setChecked(false, $T(2000)); out.push(await s());
await l.check(); await l.check(); out.push(await s());
await $P.locator("#radio-b").check(); out.push(await $P.locator("#radio-b").evaluate((e) => e.checked));
return { states: out, radioUncheck: await E(() => $P.locator("#radio-b").uncheck($T(500))), notCheckbox: await E(() => $P.locator("#action").check($T(500))) };`,
    better: {
      aside: errBetter,
      chatgpt: errBetter,
    },
    expect: { states: [true, false, true, false, true, false, true, true], radioUncheck: { error: "invalid-arg" }, notCheckbox: { error: "invalid-arg" } },
  },
  {
    id: "loc.timeout-options",
    members: ["chatgpt:PlaywrightLocator.allTextContents", "chatgpt:PlaywrightLocator.fill", "chatgpt:PlaywrightLocator.getAttribute", "chatgpt:PlaywrightLocator.innerText", "chatgpt:PlaywrightLocator.press", "chatgpt:PlaywrightLocator.pressSequentially", "chatgpt:PlaywrightLocator.textContent", "chatgpt:PlaywrightLocator.type", "chatgpt:PlaywrightLocator.evaluate", "chatgpt:PlaywrightLocator.evaluateAll", "aside:Locator.fill", "aside:Locator.getAttribute", "aside:Locator.innerText", "aside:Locator.press", "aside:Locator.pressSequentially", "aside:Locator.textContent", "aside:Locator.type"],
    path: LAB,
    code: `const name = $P.locator("#name");
const out = {};
out.all = await $P.locator("[data-testid=item]").allTextContents();
await name.fill("typed", $T(2000));
out.attr = await name.getAttribute("placeholder", $T(2000));
out.inner = await $P.locator("#status").innerText($T(2000));
out.text = await $P.locator("#status").textContent($T(2000));
await name.press("End", $T(2000));
await name.pressSequentially("ab", $T(2000));
await name.type("cd", $T(2000));
out.value = await name.evaluate((e) => e.value);
out.valueWithArg = await name.evaluate((e, a) => e.value + a, "!");
out.items = await $P.locator("[data-testid=item]").evaluateAll((es) => es.length);
out.itemsWithArg = await $P.locator("[data-testid=item]").evaluateAll((es, a) => es.length + a, 1);
return out;`,
    aside: `const name = page.locator("#name");
const out = {};
out.all = await page.locator("[data-testid=item]").evaluateAll((es) => es.map((e) => e.textContent));
await name.fill("typed", { timeout: 2000 });
out.attr = await name.getAttribute("placeholder", { timeout: 2000 });
out.inner = await page.locator("#status").innerText({ timeout: 2000 });
out.text = await page.locator("#status").textContent({ timeout: 2000 });
await name.press("End", { timeout: 2000 });
await name.pressSequentially("ab", { timeout: 2000 });
await name.type("cd", { timeout: 2000 });
out.value = await name.evaluate((e) => e.value);
out.valueWithArg = await name.evaluate((e, a) => e.value + a, "!");
out.items = await page.locator("[data-testid=item]").evaluateAll((es) => es.length);
out.itemsWithArg = await page.locator("[data-testid=item]").evaluateAll((es, a) => es.length + a, 1);
return out;`,
    expect: { all: ["First", "Second", "Third"], attr: "Enter name", inner: "ready", text: "ready", value: "typedabcd", valueWithArg: "typedabcd!", items: 3, itemsWithArg: 4 },
  },
  {
    id: "loc.errors.missing",
    members: ["chatgpt:PlaywrightLocator.click", "chatgpt:PlaywrightLocator.dblclick", "chatgpt:PlaywrightLocator.check", "chatgpt:PlaywrightLocator.uncheck", "chatgpt:PlaywrightLocator.setChecked", "chatgpt:PlaywrightLocator.fill", "chatgpt:PlaywrightLocator.getAttribute", "chatgpt:PlaywrightLocator.innerText", "chatgpt:PlaywrightLocator.textContent", "chatgpt:PlaywrightLocator.press", "chatgpt:PlaywrightLocator.pressSequentially", "chatgpt:PlaywrightLocator.type", "chatgpt:PlaywrightLocator.selectOption", "chatgpt:PlaywrightLocator.waitFor", "aside:Locator.click", "aside:Locator.dblclick", "aside:Locator.check", "aside:Locator.fill", "aside:Locator.selectOption", "aside:Locator.waitFor"],
    path: LAB,
    code: `const m = $P.locator("#missing");
const o = $T(300);
return {
  click: await E(() => m.click(o)), dblclick: await E(() => m.dblclick(o)), check: await E(() => m.check(o)), uncheck: await E(() => m.uncheck(o)),
  setChecked: await E(() => m.setChecked(true, o)), fill: await E(() => m.fill("x", o)), getAttribute: await E(() => m.getAttribute("id", o)),
  innerText: await E(() => m.innerText(o)), textContent: await E(() => m.textContent(o)), press: await E(() => m.press("a", o)),
  pressSequentially: await E(() => m.pressSequentially("a", o)), type: await E(() => m.type("a", o)), selectOption: await E(() => m.selectOption("a", o)),
  waitFor: await E(() => m.waitFor({ state: "visible", $TO: 300 })),
};`,
    better: {
      aside: errBetter,
      chatgpt: errBetter,
    },
    expect: { click: { error: "no-element" }, fill: { error: "no-element" }, waitFor: { error: "no-element" } },
  },
  {
    id: "loc.errors.evaluate",
    members: ["chatgpt:PlaywrightLocator.evaluate", "chatgpt:PlaywrightLocator.evaluateAll", "chatgpt:PlaywrightLocator.allTextContents", "aside:Locator.evaluate", "aside:Locator.evaluateAll"],
    path: LAB,
    code: `return {
  evaluate: await E(() => $P.locator("#name").evaluate(() => { throw new Error("boom"); })),
  evaluateAll: await E(() => $P.locator("li").evaluateAll(() => { throw new Error("boom all"); })),
  strict: await E(() => $P.locator("li").evaluate((e) => e.textContent, undefined, $T(300))),
  allTextBad: await E(() => $P.locator("!!!").allTextContents()),
  emptyAll: await $P.locator("#missing").evaluateAll((es) => es.length),
};`,
    better: {
      aside: errBetter,
      chatgpt: errBetter,
    },
    expect: { evaluate: { error: "other" }, strict: { error: "strict" }, allTextBad: { error: "invalid-arg" }, emptyAll: 0 },
  },
  {
    id: "loc.failure-kinds",
    edge: "hidden-disabled",
    members: ["chatgpt:PlaywrightLocator.click", "chatgpt:PlaywrightLocator.fill", "aside:Locator.click", "aside:Locator.fill"],
    path: LAB,
    code: `const o = $T(400);
return {
  hidden: await E(() => $P.locator("#hidden").click(o)),
  disabled: await E(() => $P.locator("#disabled").click(o)),
  disabledFill: await E(() => $P.locator("#disabled").fill("x", o)),
  readonlyFill: await E(() => $P.locator("#readonly").fill("x", o)),
  notInput: await E(() => $P.locator("#status").fill("x", o)),
  role: await E(() => $P.getByRole("button", { name: "Nope" }).click(o)),
  text: await E(() => $P.getByText("Nope").click(o)),
  chained: await E(() => $P.locator("ul").locator("#nope").click(o)),
  frame: await E(() => $P.frameLocator("#frame").locator("#nope").click(o)),
  many: await E(() => $P.locator("li").fill("x", o)),
};`,
    better: {
      aside: errBetter,
      chatgpt: errBetter,
    },
    expect: { hidden: { error: "not-visible" }, disabled: { error: "disabled" }, disabledFill: { error: "disabled" }, readonlyFill: { error: "not-editable" }, many: { error: "strict" } },
  },
  {
    id: "loc.composition-errors",
    members: ["chatgpt:PlaywrightLocator.and", "chatgpt:PlaywrightLocator.or", "chatgpt:PlaywrightLocator.nth", "chatgpt:PlaywrightLocator.filter", "chatgpt:PlaywrightLocator.locator", "chatgpt:PlaywrightLocator.getByLabel", "chatgpt:PlaywrightLocator.getByPlaceholder", "chatgpt:PlaywrightLocator.getByRole", "chatgpt:PlaywrightLocator.getByTestId", "chatgpt:PlaywrightLocator.getByText", "aside:Locator.nth", "aside:Locator.filter", "aside:Locator.locator"],
    path: LAB,
    code: `const body = $P.locator("body");
return {
  and: await E(() => body.and("li").count()), or: await E(() => body.or("li").count()), nth: await E(() => body.nth("x").count()),
  filter: await E(() => body.filter({ has: "li" }).count()), locator: await E(() => body.locator("!!!").count()),
  getByLabel: await E(() => body.getByLabel(42).count()), getByPlaceholder: await E(() => body.getByPlaceholder(42).count()),
  getByRole: await E(() => body.getByRole("notarole!").count()), getByTestId: await E(() => body.getByTestId(null).count()), getByText: await E(() => body.getByText(42).count()),
};`,
    better: {
      aside: errBetter,
      chatgpt: errBetter,
    },
    expect: { and: { error: "invalid-arg" }, filter: { error: "invalid-arg" }, locator: { error: "invalid-arg" } },
  },
  {
    id: "loc.filter-options",
    members: ["chatgpt:PlaywrightLocator.filter", "chatgpt:PlaywrightLocator.locator", "aside:Locator.filter", "aside:Locator.locator"],
    path: LAB,
    code: `const ul = $P.locator("ul");
const li = $P.locator("li");
return {
  has: await $P.locator("ul").filter({ has: $P.locator("li") }).count(), hasNot: await $P.locator("ul").filter({ hasNot: $P.locator("li") }).count(),
  hasText: await li.filter({ hasText: "Sec" }).count(), hasTextRe: await li.filter({ hasText: /Sec/ }).count(), hasNotTextRe: await li.filter({ hasNotText: /Sec/ }).count(),
  visible: await $P.locator("button").filter({ visible: true }).count() > 10, hidden: await $P.locator("button").filter({ visible: false }).count(),
  lHas: await $P.locator("body").locator("ul", { has: $P.locator("li") }).count(), lHasNot: await $P.locator("body").locator("ul", { hasNot: $P.locator("li") }).count(),
  lHasText: await ul.locator("li", { hasText: "Sec" }).count(), lHasTextRe: await ul.locator("li", { hasText: /sec/i }).count(),
  lHasNotText: await ul.locator("li", { hasNotText: "Sec" }).count(), lHasNotTextRe: await ul.locator("li", { hasNotText: /sec/i }).count(),
};`,
    better: {
      aside: {
        reason: "hasNot, hasNotText and visible filters follow Playwright; Aside's hasNot keeps matches and visible:false counts visible buttons",
        check: (c, r) => c.hasNot === 0 && c.lHasNot === 0 && c.hidden === 2 && (r.hasNot !== 0 || r.hidden !== 2),
      },
    },
    expect: { has: 1, hasNot: 0, hasText: 1, hasTextRe: 1, hasNotTextRe: 2, visible: true, lHas: 1, lHasNot: 0, lHasText: 1, lHasTextRe: 1, lHasNotText: 2, lHasNotTextRe: 2 },
  },
  {
    id: "loc.regexp-getters",
    members: ["chatgpt:PlaywrightAPI.getByLabel", "chatgpt:PlaywrightAPI.getByPlaceholder", "chatgpt:PlaywrightAPI.getByRole", "chatgpt:PlaywrightAPI.getByText", "chatgpt:PlaywrightLocator.getByLabel", "chatgpt:PlaywrightLocator.getByPlaceholder", "chatgpt:PlaywrightLocator.getByRole", "chatgpt:PlaywrightLocator.getByText", "chatgpt:PlaywrightFrameLocator.getByLabel", "chatgpt:PlaywrightFrameLocator.getByPlaceholder", "chatgpt:PlaywrightFrameLocator.getByRole", "chatgpt:PlaywrightFrameLocator.getByText"],
    path: LAB,
    code: `const body = $P.locator("body");
const f = $P.frameLocator("#frame");
return {
  page: [await $P.getByLabel(/nam/i).count(), await $P.getByPlaceholder(/Enter/).count(), await $P.getByRole("button", { name: /^Act/ }).count(), await $P.getByText(/Firs/).count()],
  locator: [await body.getByLabel(/nam/i).count(), await body.getByPlaceholder(/Enter/).count(), await body.getByRole("button", { name: /^Act/ }).count(), await body.getByText(/Firs/).count()],
  frame: [await f.getByLabel(/Frame/).count(), await f.getByPlaceholder(/Frame/).count(), await f.getByRole("button", { name: /Frame/ }).count(), await f.getByText(/Frame act/).count()],
  frameExact: [await f.getByLabel("Frame label", { exact: true }).count(), await f.getByLabel("frame", { exact: false }).count(), await f.getByText("Frame action", { exact: true }).count(), await f.getByText("frame", { exact: false }).count()],
  locatorExact: [await body.getByText("First", { exact: true }).count(), await body.getByText("first", { exact: false }).count()],
};`,
    aside: null,
    na: { aside: "Aside's Locator and FrameLocator have no getBy* methods (!getByRole etc. in its surface); page-level getters are covered by page.getters.page-level" },
    expect: { page: [1, 1, 1, 1], locator: [1, 1, 1, 1], frame: [1, 1, 1, 1], frameExact: [1, 1, 1, 2], locatorExact: [1, 1] },
  },
  {
    id: "loc.select-option.forms",
    edge: "select-multiple",
    members: ["chatgpt:PlaywrightLocator.selectOption", "aside:Locator.selectOption"],
    path: LAB,
    code: `const l = $P.locator("#choice");
const v = () => l.evaluate((e) => e.value);
const out = [];
const step = async (f) => { const r = await E(f); out.push(r.error ? r : await v()); };
await step(() => l.selectOption({ value: "b" }));
await step(() => l.selectOption({ label: "Alpha" }));
await step(() => l.selectOption({ index: 1 }));
await step(() => l.selectOption(["a"]));
await step(() => l.selectOption([{ value: "b" }], $T(2000)));
await step(() => l.selectOption("Gamma"));
const multi = $P.locator("#multi");
const picked = (await E(() => multi.selectOption(["r", "b"]))).value ?? null;
return {
  values: out,
  multi: await multi.evaluate((e) => [...e.selectedOptions].map((o) => o.value)),
  returned: picked,
  events: $LOG.filter((r) => r[1] === "choice").map((r) => r[0]).slice(0, 2),
  missing: await E(() => l.selectOption("nope", $T(400))),
  notSelect: await E(() => $P.locator("#name").selectOption("a", $T(400))),
};`,
    better: {
      aside: errBetter,
      chatgpt: {
        reason: "selectOption takes a label string and returns the selected values, as in Playwright; ChatGPT's times out on a label and returns nothing",
        check: (c, r) => JSON.stringify(c.values) === JSON.stringify(['b','a','b','a','b','c']) && Array.isArray(c.returned) && !Array.isArray(r.returned),
      },
    },
    expect: { values: ["b", "a", "b", "a", "b", "c"], multi: ["r", "b"], returned: ["r", "b"], events: ["input", "change"], missing: { error: "no-element" }, notSelect: { error: "invalid-arg" } },
  },
  {
    id: "loc.wait-for.states",
    members: ["chatgpt:PlaywrightLocator.waitFor", "aside:Locator.waitFor"],
    path: LAB,
    code: `await $P.locator("#hidden").waitFor({ state: "attached" });
await $P.locator("#hidden").waitFor({ state: "hidden", $TO: 2000 });
await $P.locator("#missing").waitFor({ state: "detached" });
await $P.locator("#missing").waitFor({ state: "hidden" });
await $P.locator("#make-late").click();
const late = await ms(() => $P.locator("#late").waitFor());
return { done: true, late: late.error ? late : late.ms < 2000, hiddenVisible: await E(() => $P.locator("#hidden").waitFor({ state: "visible", $TO: 300 })), bogus: await E(() => $P.locator("#action").waitFor({ state: "bogus" })) };`,
    better: {
      aside: errBetter,
      chatgpt: errBetter,
    },
    expect: { done: true, late: true, hiddenVisible: { error: "not-visible" }, bogus: { error: "invalid-arg" } },
  },
  {
    id: "loc.fill.forms",
    members: ["aside:Locator.fill", "aside:Locator.clear", "aside:Locator.inputValue", "chatgpt:PlaywrightLocator.fill"],
    path: LAB,
    code: `await $P.locator("#name").fill("new value");
await $P.locator("#area").fill("multi\\nline");
await $P.locator("#rich").fill("rich text");
const clear = await E(() => $P.locator("#decoy").clear());
return {
  name: await $P.locator("#name").inputValue(),
  area: await $P.locator("#area").inputValue(),
  rich: await $P.locator("#rich").innerText(),
  cleared: clear.error ? clear : await $P.locator("#decoy").inputValue(),
  events: $LOG.filter((r) => r[1] === "name").map((r) => r[0] + ":" + r[2]).slice(0, 3),
  inputValueOfDiv: await E(() => $P.locator("#status").inputValue($T(300))),
};`,
    chatgpt: `await $P.locator("#name").fill("new value");
await $P.locator("#area").fill("multi\\nline");
await $P.locator("#rich").fill("rich text");
await $P.locator("#decoy").fill("");
const val = (s) => $P.locator(s).evaluate((e) => e.value);
return {
  name: await val("#name"),
  area: await val("#area"),
  rich: await $P.locator("#rich").innerText(),
  cleared: await val("#decoy"),
  events: $LOG.filter((r) => r[1] === "name").map((r) => r[0] + ":" + r[2]).slice(0, 3),
};`,
    compare: { aside: ["name", "area", "rich", "cleared", "events", "inputValueOfDiv"], chatgpt: ["name", "area", "rich", "cleared", "events"] },
    expect: { name: "new value", area: "multi\nline", rich: "rich text", cleared: "", events: ["focus:true", "input:true", "change:true"], inputValueOfDiv: { error: "invalid-arg" } },
  },
  {
    id: "loc.typing",
    members: ["aside:Locator.type", "aside:Locator.press", "aside:Locator.pressSequentially", "chatgpt:PlaywrightLocator.type", "chatgpt:PlaywrightLocator.press", "chatgpt:PlaywrightLocator.pressSequentially"],
    path: LAB,
    code: `const k = $P.locator("#keys");
await k.pressSequentially("ab");
await k.type("c");
await k.press("Shift+KeyD");
await k.press("Backspace");
const slow = await ms(() => k.pressSequentially("xy", { delay: 150 }));
await k.press("ArrowLeft");
await k.press("Delete");
const keys = $LOG.filter((r) => r[1] === "keys" && r[0] === "keydown").map((r) => r[3][0]);
return { value: await k.evaluate((e) => e.value), keys, trusted: $LOG.filter((r) => r[1] === "keys").every((r) => r[2]), slow: slow.ms >= 250, badKey: await E(() => k.press("NoSuchKey")) };`,
    better: {
      aside: errBetter,
      chatgpt: {
        reason: "key presses are trusted native events and delay is honored; ChatGPT's arrive untrusted and ignore delay",
        check: (c, r) => c.trusted === true && r.trusted === false && c.value === r.value,
      },
    },
    expect: { value: "abcx", keys: ["a", "b", "c", "Shift", "D", "Backspace", "x", "y", "ArrowLeft", "Delete"], trusted: true, slow: true, badKey: { error: "invalid-arg" } },
  },
  {
    id: "loc.hover",
    edge: "hover-menu-delay",
    members: ["aside:Locator.hover", "chatgpt:CUAAPI.move"],
    path: LAB,
    code: `await $P.locator("#hover-btn").hover();
const item = $P.locator("#menu-item");
await item.waitFor({ state: "visible", $TO: 3000 });
await item.click();
return { status: await $P.locator("#status").innerText(), enter: $LOG.some((r) => r[1] === "hover-btn" && r[0] === "mouseenter" && r[2]) };`,
    chatgpt: `const box = await $P.locator("#hover-btn").evaluate((e) => { const r = e.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; });
await t.cua.move({ x: box[0], y: box[1] });
await $P.locator("#menu-item").waitFor({ state: "visible", timeoutMs: 3000 });
await $P.locator("#menu-item").click();
return { status: await $P.locator("#status").innerText(), enter: $LOG.some((r) => r[1] === "hover-btn" && r[0] === "mouseenter" && r[2]) };`,
    chatgptMode: "legacy",
    expect: { status: "menu picked", enter: true },
  },
  {
    id: "loc.focus-blur",
    members: ["aside:Locator.focus", "aside:Locator.blur"],
    path: LAB,
    code: `await $P.locator("#name").focus();
const focused = await $P.evaluate(() => document.activeElement.id);
await $P.locator("#name").blur();
return { focused, after: await $P.evaluate(() => document.activeElement.tagName), events: $LOG.filter((r) => r[1] === "name").map((r) => r[0]) };`,
    chatgpt: `await $P.locator("#name").click();
const focused = await $P.evaluate(() => document.activeElement.id);
return { focused };`,
    compare: { chatgpt: ["focused"] },
    expect: { focused: "name", after: "BODY", events: ["focus", "blur"] },
  },
  {
    id: "loc.set-input-files",
    members: ["aside:Locator.setInputFiles", "chatgpt:PlaywrightFileChooser.setFiles", "chatgpt:PlaywrightFileChooser.isMultiple"],
    path: FILES,
    code: `const f = path.join(os.tmpdir(), "parity-upload.txt");
fs.writeFileSync(f, "Disposable browser parity upload\\n");
await $P.locator("#file").setInputFiles(f);
await $P.locator("#result").getByText("parity-upload.txt").waitFor();
const one = await $P.locator("#result").innerText();
await $P.locator("#multi").setInputFiles([f, { name: "second.txt", mimeType: "text/plain", buffer: Buffer.from("two\\n") }]);
await $P.locator("#result").getByText("second.txt").waitFor();
const many = await $P.locator("#result").innerText();
await $P.locator("#file").setInputFiles([]);
return { one, many, cleared: await $P.locator("#file").evaluate((e) => e.files.length), missing: await E(() => $P.locator("#file").setInputFiles("/nonexistent/parity.txt")), notFile: await E(() => $P.locator("#pick").setInputFiles(f, $T(400))) };`,
    aside: `const f = path.join(pwd, "parity-upload.txt");
await fs.writeFile(f, "Disposable browser parity upload\\n");
const out = {};
try {
  await page.locator("#file").setInputFiles(f);
  for (let i = 0; i < 50 && !(await page.locator("#result").innerText()).includes("parity-upload.txt"); i++) await sleep(50);
  out.one = await page.locator("#result").innerText();
  const many = await E(() => page.locator("#multi").setInputFiles([f, { name: "second.txt", mimeType: "text/plain", buffer: Buffer.from("two\\n") }]));
  for (let i = 0; i < 20 && !many.error && !(await page.locator("#result").innerText()).includes("second.txt"); i++) await sleep(50);
  out.many = many.error ? many : await page.locator("#result").innerText();
  await page.locator("#file").setInputFiles([]);
  out.cleared = await page.locator("#file").evaluate((e) => e.files.length);
  out.missing = await E(() => page.locator("#file").setInputFiles("/nonexistent/parity.txt"));
  out.notFile = await E(() => page.locator("#pick").setInputFiles(f, { timeout: 400 }));
} finally { await fs.rm(f, { force: true }); }
return out;`,
    chatgpt: `const pending = $P.waitForEvent("filechooser", {});
await $P.locator("#file").click();
const ch = await pending;
const single = ch.isMultiple();
await ch.setFiles(PARITY_UPLOAD);
await $P.waitForTimeout(300);
const one = await $P.locator("#result").innerText();
const p2 = $P.waitForEvent("filechooser", {});
await $P.locator("#multi").click();
const ch2 = await p2;
const multiple = ch2.isMultiple();
await ch2.setFiles([PARITY_UPLOAD], { timeoutMs: 5000 });
await $P.waitForTimeout(300);
return { one, many: await $P.locator("#result").innerText(), single, multiple };`,
    compare: { aside: ["one", "many", "cleared", "missing", "notFile"], chatgpt: ["one"] },
    better: {
      chatgpt: {
        reason: "setInputFiles sets files on an input directly, takes in-memory files and clears a selection; ChatGPT only answers a chooser with paths from disk",
        check: (c) => /second\.txt/.test(c.many) && c.cleared === 0,
      },
      aside: {
        reason: "setInputFiles takes in-memory files ({ name, mimeType, buffer }) as well as paths, as in Playwright; Aside takes only paths",
        check: (c, r) => c.one === r.one && /second\.txt/.test(c.many) && typeof r.many === 'object' && c.cleared === 0,
      },
    },
    expect: { one: "file: parity-upload.txt(Disposable browser parity upload)", many: "multi: parity-upload.txt(Disposable browser parity upload),second.txt(two)", cleared: 0, missing: { error: "denied" }, notFile: { error: "invalid-arg" } },
  },
  {
    id: "loc.drag-to",
    members: ["aside:Locator.dragTo", "chatgpt:AXAPI.drag", "chatgpt:CUAAPI.drag"],
    path: LAB,
    code: `await $P.locator("#drag").dragTo($P.locator("#drop"));
return { drop: await $P.locator("#drop").innerText(), events: $LOG.filter((r) => ["drag", "drop"].includes(r[1])).map((r) => r[0] + ":" + r[2]).filter((x, i, a) => a.indexOf(x) === i) };`,
    chatgpt: `const c = (s) => $P.locator(s).evaluate((e) => { const r = e.getBoundingClientRect(); return [Math.round(r.x + r.width / 2), Math.round(r.y + r.height / 2)]; });
const from = await c("#drag"), to = await c("#drop");
await t.cua.drag({ path: [{ x: from[0], y: from[1] }, { x: to[0], y: to[1] }] });
await $P.waitForTimeout(300);
return { drop: await $P.locator("#drop").innerText(), events: $LOG.filter((r) => ["drag", "drop"].includes(r[1])).map((r) => r[0] + ":" + r[2]).filter((x, i, a) => a.indexOf(x) === i) };`,
    chatgptMode: "legacy",
    better: {
      aside: {
        reason: "a drag delivers one trusted HTML5 drag sequence; Aside also replays it as untrusted synthetic events",
        check: (c, r) => c.drop === r.drop && c.events.every((e) => e.endsWith(':true')) && r.events.some((e) => e.endsWith(':false')),
      },
    },
    expect: { drop: "dropped payload" },
  },
  {
    id: "loc.drag-to.ax",
    members: ["chatgpt:AXAPI.drag"],
    path: LAB,
    code: `const c = async (s) => { const b = await $P.locator(s).boundingBox(); return [b.x + b.width / 2, b.y + b.height / 2]; };
const from = await c("#drag"), to = await c("#drop");
await $P.mouse.move(from[0], from[1]); await $P.mouse.down(); await $P.mouse.move(to[0], to[1], { steps: 8 }); await $P.mouse.up();
return { drop: await $P.locator("#drop").innerText() };`,
    chatgpt: `const c = (s) => $P.locator(s).evaluate((e) => { const r = e.getBoundingClientRect(); return [Math.round(r.x + r.width / 2), Math.round(r.y + r.height / 2)]; });
const from = await c("#drag"), to = await c("#drop");
await t.ax.drag(from, to);
await $P.waitForTimeout(300);
return { drop: await $P.locator("#drop").innerText() };`,
    aside: null,
    na: { aside: "covered by loc.drag-to (Aside has dragTo)" },
    expect: { drop: "dropped payload" },
  },
  {
    id: "loc.tap",
    members: ["aside:Locator.tap"],
    path: LAB,
    code: `return { tap: await E(() => $P.locator("#action").tap($T(1000))), status: await $P.locator("#status").innerText() };`,
    chatgpt: null,
    na: { chatgpt: "ChatGPT has no touch input" },
    compare: ["tap"],
  },
  {
    id: "loc.scroll-into-view",
    members: ["aside:Locator.scrollIntoViewIfNeeded", "aside:Locator.boundingBox", "chatgpt:AXAPI.scroll"],
    path: LAB,
    code: `const before = await $P.evaluate(() => scrollY);
await $P.locator("#far").scrollIntoViewIfNeeded();
const box = await $P.locator("#far").boundingBox();
const vh = await $P.evaluate(() => innerHeight);
return { moved: (await $P.evaluate(() => scrollY)) > before, inView: box.y >= 0 && box.y + box.height <= vh, hiddenBox: await $P.locator("#hidden").boundingBox() };`,
    chatgpt: `const before = await $P.evaluate(() => scrollY);
await t.ax.scroll([200, 200], "down", 3);
await $P.waitForTimeout(400);
return { moved: (await $P.evaluate(() => scrollY)) > before };`,
    compare: { aside: ["moved", "inView", "hiddenBox"], chatgpt: ["moved"] },
    expect: { moved: true, inView: true, hiddenBox: null },
  },
  {
    id: "loc.screenshot",
    members: ["aside:Locator.screenshot", "chatgpt:PlaywrightAPI.elementScreenshot"],
    path: LAB,
    code: `const box = await $P.locator("#canvas").boundingBox();
const img = imgInfo(await $P.locator("#canvas").screenshot());
const ratio = img.width / box.width;
return { format: img.format, matches: Math.abs(img.height / ratio - box.height) < 2, hidden: await E(() => $P.locator("#hidden").screenshot($T(400))) };`,
    aside: `const box = await page.locator("#canvas").boundingBox();
const raw = await page.locator("#canvas").screenshot();
const img = imgInfo(typeof raw === "string" ? Buffer.from(raw, "base64") : raw);
const ratio = img.width / box.width;
return { format: img.format, matches: Math.abs(img.height / ratio - box.height) < 2, hidden: await E(() => page.locator("#hidden").screenshot({ timeout: 400 })) };`,
    chatgpt: `const r = await E(() => $P.elementScreenshot({ x: 20, y: 20 }));
return { format: r.error ? r : "image" };`,
    better: {
      chatgpt: {
        reason: "an element screenshot is cropped to the element; ChatGPT's elementScreenshot is not supported by its Chrome backend",
        check: (c, r) => c.format === "png" && c.matches && r.format?.error,
      },
    },
    compare: { aside: ["format", "matches", "hidden"], chatgpt: ["format"] },
    expect: { format: "png", matches: true, hidden: { error: "not-visible" } },
  },
  {
    id: "loc.reads",
    members: ["aside:Locator.textContent", "aside:Locator.innerText", "aside:Locator.innerHTML", "aside:Locator.inputValue", "aside:Locator.getAttribute", "chatgpt:PlaywrightLocator.textContent", "chatgpt:PlaywrightLocator.innerText", "chatgpt:PlaywrightLocator.getAttribute", "chatgpt:PlaywrightLocator.allTextContents"],
    path: LAB,
    code: `return {
  text: await $P.locator("#rich").textContent(),
  inner: await $P.locator("#rich").innerText(),
  html: await $P.locator("#rich").innerHTML(),
  value: await $P.locator("#name").inputValue(),
  attr: await $P.locator("#name").getAttribute("placeholder"),
  noAttr: await $P.locator("#name").getAttribute("nope"),
  hiddenText: await $P.locator("#hidden").textContent(),
  hiddenInner: await $P.locator("#hidden").innerText(),
  all: await $P.locator("li").allTextContents(),
  allInner: await $P.locator("li").allInnerTexts(),
};`,
    chatgpt: `return {
  text: await $P.locator("#rich").textContent(),
  inner: await $P.locator("#rich").innerText(),
  html: await $P.locator("#rich").evaluate((e) => e.innerHTML),
  value: await $P.locator("#name").evaluate((e) => e.value),
  attr: await $P.locator("#name").getAttribute("placeholder"),
  noAttr: await $P.locator("#name").getAttribute("nope"),
  hiddenText: await $P.locator("#hidden").textContent(),
  hiddenInner: await $P.locator("#hidden").innerText(),
  all: await $P.locator("li").allTextContents(),
  allInner: await $P.locator("li").evaluateAll((es) => es.map((e) => e.innerText)),
};`,
    aside: `return {
  text: await page.locator("#rich").textContent(),
  inner: await page.locator("#rich").innerText(),
  html: await page.locator("#rich").innerHTML(),
  value: await page.locator("#name").inputValue(),
  attr: await page.locator("#name").getAttribute("placeholder"),
  noAttr: await page.locator("#name").getAttribute("nope"),
  hiddenText: await page.locator("#hidden").textContent(),
  hiddenInner: await page.locator("#hidden").innerText(),
  all: await page.locator("li").evaluateAll((es) => es.map((e) => e.textContent)),
  allInner: await page.locator("li").evaluateAll((es) => es.map((e) => e.innerText)),
};`,
    expect: { text: "alpha beta gamma", inner: "alpha beta gamma", html: "alpha <b>beta</b> gamma", value: "initial", attr: "Enter name", noAttr: null, hiddenText: "Hidden", hiddenInner: "Hidden", all: ["First", "Second", "Third"], allInner: ["First", "Second", "Third"] },
  },
  {
    id: "loc.states",
    members: ["aside:Locator.isVisible", "aside:Locator.isHidden", "aside:Locator.isEnabled", "aside:Locator.isDisabled", "aside:Locator.isChecked", "aside:Locator.isEditable", "chatgpt:PlaywrightLocator.isVisible", "chatgpt:PlaywrightLocator.isEnabled"],
    path: LAB,
    code: `await $P.locator("#check").check();
return {
  visible: [await $P.locator("#action").isVisible(), await $P.locator("#hidden").isVisible(), await $P.locator("#missing").isVisible()],
  hidden: [await $P.locator("#action").isHidden(), await $P.locator("#hidden").isHidden(), await $P.locator("#missing").isHidden()],
  enabled: [await $P.locator("#action").isEnabled(), await $P.locator("#disabled").isEnabled()],
  disabled: [await $P.locator("#action").isDisabled(), await $P.locator("#disabled").isDisabled()],
  checked: [await $P.locator("#check").isChecked(), await $P.locator("#radio-a").isChecked()],
  editable: [await $P.locator("#name").isEditable(), await $P.locator("#readonly").isEditable(), await $P.locator("#rich").isEditable()],
  checkedOfButton: await E(() => $P.locator("#action").isChecked()),
  enabledMissing: await E(() => $P.locator("#missing").isEnabled($T(300))),
};`,
    chatgpt: `await $P.locator("#check").check();
const ev = (s, f) => $P.locator(s).evaluate(f);
return {
  visible: [await $P.locator("#action").isVisible(), await $P.locator("#hidden").isVisible(), await $P.locator("#missing").isVisible()],
  hidden: [!(await $P.locator("#action").isVisible()), !(await $P.locator("#hidden").isVisible()), !(await $P.locator("#missing").isVisible())],
  enabled: [await $P.locator("#action").isEnabled(), await $P.locator("#disabled").isEnabled()],
  disabled: [!(await $P.locator("#action").isEnabled()), !(await $P.locator("#disabled").isEnabled())],
  checked: [await ev("#check", (e) => e.checked), await ev("#radio-a", (e) => e.checked)],
  editable: [await ev("#name", (e) => !e.readOnly && !e.disabled), await ev("#readonly", (e) => !e.readOnly), await ev("#rich", (e) => e.isContentEditable)],
  enabledMissing: await E(() => $P.locator("#missing").isEnabled()),
};`,
    aside: `await page.locator("#check").check();
const S = async (f) => { const r = await E(f); return r.error ? r : r.value; };
return {
  visible: [await S(() => page.locator("#action").isVisible()), await S(() => page.locator("#hidden").isVisible()), await S(() => page.locator("#missing").isVisible())],
  hidden: [await S(() => page.locator("#action").isHidden()), await S(() => page.locator("#hidden").isHidden()), await S(() => page.locator("#missing").isHidden())],
  enabled: [await S(() => page.locator("#action").isEnabled()), await S(() => page.locator("#disabled").isEnabled())],
  disabled: [await S(() => page.locator("#action").isDisabled()), await S(() => page.locator("#disabled").isDisabled())],
  checked: [await S(() => page.locator("#check").isChecked()), await S(() => page.locator("#radio-a").isChecked())],
  editable: [await S(() => page.locator("#name").isEditable()), await S(() => page.locator("#readonly").isEditable()), await S(() => page.locator("#rich").isEditable())],
  checkedOfButton: await E(() => page.locator("#action").isChecked()),
  enabledMissing: await E(() => page.locator("#missing").isEnabled({ timeout: 300 })),
};`,
    better: {
      aside: {
        reason: "state queries follow Playwright: isVisible and isHidden of a missing element answer false and true, and isChecked of a non-checkbox fails; Aside throws or answers otherwise",
        check: (c, r, h) => JSON.stringify(c.visible) === "[true,false,false]" && JSON.stringify(c.hidden) === "[false,true,true]" && JSON.stringify(h.comparable(c.enabled)) === JSON.stringify(h.comparable(r.enabled)) && JSON.stringify(c.editable) === JSON.stringify(r.editable),
      },
      chatgpt: {
        reason: "state reads work on any element; ChatGPT's read-only evaluate cannot read isContentEditable and isEnabled of a missing element answers false instead of failing",
        check: (c, r, h) => JSON.stringify(c.editable) === '[true,false,true]' && (r.editable?.[2] !== true || !r.enabledMissing?.error),
      },
    },
    compare: { aside: ["visible", "hidden", "enabled", "disabled", "checked", "editable", "checkedOfButton", "enabledMissing"], chatgpt: ["visible", "hidden", "enabled", "disabled", "checked", "editable", "enabledMissing"] },
    expect: { visible: [true, false, false], hidden: [false, true, true], enabled: [true, false], disabled: [false, true], checked: [true, false], editable: [true, false, true], checkedOfButton: { error: "invalid-arg" }, enabledMissing: { error: "no-element" } },
  },
  {
    id: "loc.collections",
    members: ["aside:Locator.count", "aside:Locator.all", "aside:Locator.first", "aside:Locator.last", "aside:Locator.nth", "chatgpt:PlaywrightLocator.count", "chatgpt:PlaywrightLocator.all", "chatgpt:PlaywrightLocator.first", "chatgpt:PlaywrightLocator.last", "chatgpt:PlaywrightLocator.nth"],
    path: LAB,
    code: `const li = $P.locator("li");
const all = await li.all();
return {
  count: await li.count(), all: all.length, allTexts: await Promise.all(all.map((l) => l.textContent())),
  first: await li.first().textContent(), last: await li.last().textContent(), nth: await li.nth(1).textContent(), nthNeg: await li.nth(-1).textContent(),
  nthOut: await li.nth(9).count(), none: (await $P.locator("#missing").all()).length,
};`,
    better: {
      aside: {
        reason: "nth(-1) is the last element, as in Playwright; Aside's is null",
        check: (c, r) => c.nthNeg === 'Third' && r.nthNeg !== 'Third' && c.count === r.count,
      },
    },
    expect: { count: 3, all: 3, allTexts: ["First", "Second", "Third"], first: "First", last: "Third", nth: "Second", nthNeg: "Third", nthOut: 0, none: 0 },
  },
  {
    id: "loc.and-or",
    members: ["chatgpt:PlaywrightLocator.and", "chatgpt:PlaywrightLocator.or"],
    path: LAB,
    code: `return {
  and: await $P.getByRole("button").and($P.locator("#action")).count(),
  andNone: await $P.locator("#action").and($P.locator("#counter")).count(),
  or: await $P.locator("#action").or($P.locator("#counter")).count(),
  orText: await $P.locator("#missing").or($P.getByText("Second")).textContent(),
};`,
    aside: null,
    na: { aside: "Aside's Locator has no and/or (!and, !or in its surface)" },
    expect: { and: 1, andNone: 0, or: 2, orText: "Second" },
  },
  {
    id: "loc.scoped-getters",
    members: ["chatgpt:PlaywrightLocator.getByLabel", "chatgpt:PlaywrightLocator.getByPlaceholder", "chatgpt:PlaywrightLocator.getByRole", "chatgpt:PlaywrightLocator.getByTestId", "chatgpt:PlaywrightLocator.getByText", "chatgpt:PlaywrightLocator.locator", "aside:Locator.locator"],
    path: LAB,
    code: `const body = $P.locator("body");
const ul = $P.locator("#items");
return {
  label: await body.getByLabel("Name").count(), placeholder: await body.getByPlaceholder("Enter name").count(), role: await ul.getByRole("listitem").count(),
  testId: await ul.getByTestId("item").count(), text: await ul.getByText("Third").count(), chained: await ul.locator("li").nth(2).textContent(),
  outside: await ul.getByText("Action").count(),
};`,
    aside: `const ul = page.locator("#items");
return { chained: await ul.locator("li").nth(2).textContent(), outside: await ul.locator("li").filter({ hasText: "Action" }).count() };`,
    compare: { aside: ["chained", "outside"] },
    expect: { label: 1, placeholder: 1, role: 3, testId: 3, text: 1, chained: "Third", outside: 0 },
  },
  {
    id: "loc.evaluate",
    members: ["aside:Locator.evaluate", "aside:Locator.evaluateAll", "chatgpt:PlaywrightLocator.evaluate", "chatgpt:PlaywrightLocator.evaluateAll"],
    path: LAB,
    code: `return {
  tag: await $P.locator("#action").evaluate((e) => e.tagName),
  arg: await $P.locator("#action").evaluate((e, a) => e.id + a, "!"),
  promise: await $P.locator("#action").evaluate((e) => new Promise((r) => setTimeout(() => r(e.id), 20))),
  rect: await $P.locator("#action").evaluate((e) => typeof e.getBoundingClientRect().width),
  all: await $P.locator("li").evaluateAll((es, sep) => es.map((e) => e.textContent).join(sep), "|"),
  shadow: await $P.locator("#shadow-host").evaluate((e) => !!e.shadowRoot),
};`,
    better: {
      aside: {
        reason: "locator.evaluate awaits a returned promise, as in Playwright; Aside returns the unresolved promise",
        check: (c, r) => c.promise === 'action' && r.promise !== 'action' && c.tag === r.tag,
      },
    },
    expect: { tag: "BUTTON", arg: "action!", promise: "action", rect: "number", all: "First|Second|Third", shadow: true },
  },
  {
    id: "loc.dispatch-event",
    members: ["aside:Locator.dispatchEvent"],
    path: LAB,
    code: `await $P.locator("#action").dispatchEvent("click");
return { status: await $P.locator("#status").innerText(), trusted: $LOG.filter((r) => r[1] === "action" && r[0] === "click").map((r) => r[2]) };`,
    chatgpt: null,
    na: { chatgpt: "ChatGPT's read-only evaluate cannot dispatch events and it has no dispatchEvent" },
    expect: { status: "clicked", trusted: [false] },
  },
  {
    id: "loc.download-media",
    members: ["chatgpt:PlaywrightLocator.downloadMedia", "chatgpt:PlaywrightDownload.path", "chatgpt:PlaywrightAPI.waitForEvent"],
    path: FILES,
    code: `const dl = $P.waitForEvent("download");
await $P.locator("#dl-cd").click();
const d = await dl;
const p = await d.path();
return { name: d.suggestedFilename(), body: fs.readFileSync(p, "utf8"), missing: await E(() => $P.locator("#missing").click($T(300))) };`,
    aside: `const dl = page.waitForEvent("download");
await page.locator("#dl-cd").click();
const d = await dl;
const p = await d.path();
return { name: d.suggestedFilename(), body: await fs.readFile(p, "utf8") };`,
    chatgpt: `const pending = $P.waitForEvent("download", { timeoutMs: 8000 });
pending.catch(() => {});
await $P.locator("#dl-cd").click();
const got = await E(async () => { const d = await pending; return await Promise.race([d.path({ timeoutMs: 8000 }), pause(9000).then(() => null)]); });
const p = got.value ?? null;
const viaMedia = await E(() => Promise.race([$P.locator("#dl-cd").downloadMedia({ timeoutMs: 5000 }), pause(6000).then(() => { throw new Error("downloadMedia did not settle in 6 s"); })]));
return { name: p ? p.split("/").pop() : null, body: null, viaMedia, missing: await E(() => $P.locator("#missing").downloadMedia({ timeoutMs: 300 })) };`,
    compare: { aside: ["name", "body"], chatgpt: ["name", "missing"] },
    better: {
      chatgpt: {
        reason: "the downloaded file is readable in the REPL (fs.readFileSync(await download.path())); ChatGPT returns a path its sandbox cannot read",
        check: (c, r) => c.body === "cd body a\n" && r.body == null && (c.name === r.name || /cd-a/.test(String(r.name))),
      },
    },
    expect: { name: "cd-a.txt", body: "cd body a\n", missing: { error: "no-element" } },
  },
];
