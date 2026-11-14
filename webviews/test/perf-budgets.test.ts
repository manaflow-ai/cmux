// The runtime perf budgets' engine-independent half (src/devkit/perfBudgets.ts) in jsdom, on every
// lane: the interval count, the DOM breadth check, the React commit budget through the devtools
// hook, dedupe, the modes, stop() and pagehide, and the dev server plugin that injects them only
// when serving. perf-budgets.browser.test.ts covers the same classes in real Chromium, with layout
// shift and long frames.
import { describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { perfBudgetsDevEntry } from "../dev-server/plugins";
import { PERF_BUDGET_PREFIX, startPerfBudgets, type PerfBudgetsOptions } from "../src/devkit/perfBudgets";

type Hook = { onCommitFiberRoot: (id: number, root: unknown) => void };

/** A loaded page with the budgets on: before its load nothing is budgeted but breadth and intervals. */
async function page(options: PerfBudgetsOptions = {}) {
  const dom = new JSDOM("<!doctype html><body><main id='root'></main></body>", { pretendToBeVisual: true });
  const win = dom.window as unknown as Window & { __REACT_DEVTOOLS_GLOBAL_HOOK__?: Hook };
  const originalSet = win.setInterval;
  const budgets = startPerfBudgets(win, { mode: "collect", settleMs: 0, ...options });
  if (win.document.readyState !== "complete")
    await new Promise((resolve) => win.addEventListener("load", resolve, { once: true }));
  return { win, doc: win.document, budgets, originalSet, close: () => (budgets.stop(), dom.window.close()) };
}

describe("live-intervals", () => {
  test("a timer per row passes the budget once, naming the call site", async () => {
    const { win, budgets, close } = await page();
    const ids = Array.from({ length: 50 }, () => win.setInterval(() => {}, 1000));
    expect(budgets.violations).toHaveLength(1);
    expect(budgets.violations[0]).toMatchObject({ kind: "live-intervals", measured: 21, budget: 20 });
    expect(budgets.violations[0]!.site).toContain("perf-budgets.test.ts");
    for (const id of ids) win.clearInterval(id);
    close();
  });

  test("cleared intervals (clearInterval or clearTimeout) are not live", async () => {
    const { win, budgets, close } = await page();
    for (let round = 0; round < 40; round++) {
      const id = win.setInterval(() => {}, 1000);
      if (round % 2) win.clearInterval(id);
      else win.clearTimeout(id);
    }
    expect(budgets.violations).toEqual([]);
    close();
  });
});

describe("dom-breadth", () => {
  test("a 1000-row list drawn whole fires once; an allowed one stays silent", async () => {
    const { doc, budgets, close } = await page();
    const list = doc.createElement("ul");
    list.className = "projects";
    for (let index = 0; index < 1000; index++) list.append(doc.createElement("li"));
    doc.getElementById("root")!.append(list);
    const allowedList = doc.createElement("ol");
    allowedList.setAttribute("data-perf-budget-allow", "a fixture that is the whole document");
    for (let index = 0; index < 1000; index++) allowedList.append(doc.createElement("li"));
    doc.body.append(allowedList);
    budgets.flush();
    // More rows into the same list: still one warning.
    for (let index = 0; index < 10; index++) list.append(doc.createElement("li"));
    budgets.flush();
    expect(budgets.violations.map((violation) => [violation.kind, violation.site, violation.measured])).toEqual([
      ["dom-breadth", "ul.projects", 1000],
    ]);
    expect(budgets.violations[0]!.fix).toContain("VirtualList");
    close();
  });

  test("a list of 50 stays silent", async () => {
    const { doc, budgets, close } = await page();
    const list = doc.createElement("ul");
    for (let index = 0; index < 50; index++) list.append(doc.createElement("li"));
    doc.body.append(list);
    budgets.flush();
    expect(budgets.violations).toEqual([]);
    close();
  });
});

describe("react-commit", () => {
  const root = (doc: Document, actualDuration = 1) => ({
    current: { actualDuration },
    containerInfo: doc.getElementById("root"),
  });

  test("more than 120 commits in a second fire; the first, mounting commit is never timed", async () => {
    const { win, doc, budgets, close } = await page();
    const hook = win.__REACT_DEVTOOLS_GLOBAL_HOOK__!;
    const slowMount = root(doc, 200);
    hook.onCommitFiberRoot(1, slowMount);
    expect(budgets.violations).toEqual([]);
    const streaming = root(doc);
    for (let commit = 0; commit < 130; commit++) hook.onCommitFiberRoot(1, streaming);
    expect(budgets.violations.map((violation) => violation.kind)).toEqual(["react-commit"]);
    expect(budgets.violations[0]!.site).toBe("the React root in main#root (commits in 1 s)");
    close();
  });

  test("a slow update commit fires", async () => {
    const { win, doc, budgets, close } = await page();
    const hook = win.__REACT_DEVTOOLS_GLOBAL_HOOK__!;
    const fiberRoot = root(doc, 2);
    hook.onCommitFiberRoot(1, fiberRoot);
    fiberRoot.current.actualDuration = 30;
    hook.onCommitFiberRoot(1, fiberRoot);
    expect(budgets.violations).toMatchObject([{ kind: "react-commit", measured: 30, budget: 16 }]);
    close();
  });

  test("an existing hook (Fast Refresh's, a devtools extension's) is wrapped and still called", () => {
    const dom = new JSDOM("<!doctype html><body><main id='root'></main></body>");
    const win = dom.window as unknown as Window & { __REACT_DEVTOOLS_GLOBAL_HOOK__?: Hook };
    const seen: unknown[] = [];
    const theirs = (_id: number, fiberRoot: unknown) => void seen.push(fiberRoot);
    win.__REACT_DEVTOOLS_GLOBAL_HOOK__ = { onCommitFiberRoot: theirs };
    const budgets = startPerfBudgets(win, { mode: "collect", settleMs: 0 });
    win.__REACT_DEVTOOLS_GLOBAL_HOOK__.onCommitFiberRoot(1, { current: { actualDuration: 1 } });
    expect(seen).toHaveLength(1);
    budgets.stop();
    expect(win.__REACT_DEVTOOLS_GLOBAL_HOOK__.onCommitFiberRoot).toBe(theirs);
    dom.window.close();
  });

  test("a load or hot update settles: no commit budget for the settle window", async () => {
    const { win, doc, budgets, close } = await page({ settleMs: 60_000 });
    const fiberRoot = root(doc, 30);
    for (let commit = 0; commit < 200; commit++) win.__REACT_DEVTOOLS_GLOBAL_HOOK__!.onCommitFiberRoot(1, fiberRoot);
    expect(budgets.violations).toEqual([]);
    close();
  });
});

describe("modes and stop", () => {
  test("warn mode: one console line with the prefix, the measure, the budget and the fix", async () => {
    const lines: string[] = [];
    const { win, close } = await page({ mode: "warn", report: (line) => lines.push(line) });
    for (let index = 0; index < 30; index++) win.setInterval(() => {}, 1000);
    expect(lines).toHaveLength(1);
    expect(lines[0]).toStartWith(
      `${PERF_BUDGET_PREFIX} live-intervals: 21 live intervals over the budget of 20 live intervals at `,
    );
    expect(lines[0]).toContain("Fix: subscribe to the page clock");
    close();
  });

  test("throw mode throws at the call that passes the budget", async () => {
    const { win, close } = await page({ mode: "throw" });
    for (let index = 0; index < 20; index++) win.setInterval(() => {}, 1000);
    expect(() => win.setInterval(() => {}, 1000)).toThrow(PERF_BUDGET_PREFIX);
    close();
  });

  test("off mode touches nothing", () => {
    const dom = new JSDOM("<!doctype html><body></body>");
    const win = dom.window as unknown as Window & { __REACT_DEVTOOLS_GLOBAL_HOOK__?: unknown };
    const set = win.setInterval;
    startPerfBudgets(win, { mode: "off" });
    expect(win.setInterval).toBe(set);
    expect(win.__REACT_DEVTOOLS_GLOBAL_HOOK__).toBeUndefined();
    dom.window.close();
  });

  test("pagehide stops it: timers put back, the breadth observer disconnected", async () => {
    const { win, doc, budgets, originalSet, close } = await page();
    win.dispatchEvent(new (win as unknown as { Event: typeof Event }).Event("pagehide"));
    expect(win.setInterval).toBe(originalSet);
    const list = doc.createElement("ul");
    for (let index = 0; index < 1000; index++) list.append(doc.createElement("li"));
    doc.body.append(list);
    budgets.flush();
    expect(budgets.violations).toEqual([]);
    close();
  });
});

describe("dev server plugin", () => {
  test("serve only, the page's first script", () => {
    const plugin = perfBudgetsDevEntry();
    expect(plugin.apply).toBe("serve");
    (plugin.configResolved as (config: { root: string }) => void)({ root: `${import.meta.dir}/..` });
    const tags = (plugin.transformIndexHtml as unknown as () => unknown[])();
    expect(tags).toEqual([
      { tag: "script", attrs: { type: "module", src: "/src/devkit/perfBudgets.dev.ts" }, injectTo: "head-prepend" },
    ]);
  });

  test("a server whose root is elsewhere (the standalone pane's) gets an /@fs path; CMUX_PERF_BUDGETS=off injects nothing", () => {
    const plugin = perfBudgetsDevEntry();
    (plugin.configResolved as (config: { root: string }) => void)({
      root: `${import.meta.dir}/../src/agent-session/acpmux`,
    });
    const [tag] = (plugin.transformIndexHtml as unknown as () => { attrs: { src: string } }[])();
    expect(tag!.attrs.src).toMatch(/^\/@fs\/.*\/webviews\/src\/devkit\/perfBudgets\.dev\.ts$/);
    process.env.CMUX_PERF_BUDGETS = "off";
    try {
      expect((plugin.transformIndexHtml as unknown as () => unknown[])()).toEqual([]);
    } finally {
      delete process.env.CMUX_PERF_BUDGETS;
    }
  });
});
