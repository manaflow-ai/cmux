// The runtime perf budgets (src/devkit/perfBudgets.ts) as a test failure, not only a warning under
// `cmux live`: every browser context any test file opens through Playwright gets the budgets that
// count rather than time (perfBudgetBaseline.ts GATED_CLASSES: more than 300 element children under
// one element, more than 20 live intervals), and a file whose pages hit one more often than
// test/perf-budget-baseline.tsv allows fails.
//
// test/preload.ts installs it once per `bun test` process, on Playwright's client instrumentation
// (the hook @playwright/test uses), so `browser.newPage`, `browser.newContext` and
// `launchPersistentContext` in every engine are covered without a line in any test file, and every
// page is covered whatever serves it: the webviews dev server, a built gallery, a static server,
// `page.setContent`. Each new context gets the page script (perfBudgetGate.entry.ts) as an init
// script, which runs in every frame of every document, and a binding the script sends each hit to.
//
// Checkpoints: after each test (a global afterEach) every open page's frames run their waiting
// checks and the file's counts so far are held against the baseline, so the test that pushed a row
// over it fails, naming the row; a page, context or browser that closes runs its checks first. After
// the file (a global afterAll, after the file's own teardown) a row still over fails the file, and so
// does a row under its baseline when the run was the whole file: the fix shrinks the baseline, which
// only moves down.
//
// Lowering it: `CMUX_PERF_BUDGET_OBSERVED=<dir>` writes each whole-file run's counts to <dir>, and
// `bun scripts/perf-budget-baseline.ts --update <dir>` makes them the files' rows (refusing a count
// above its row). A test that hits a budget on purpose takes its hits with claimPerfBudgetHits(page).
// `CMUX_PERF_BUDGET_GATE=off` leaves the gate out; `CMUX_PERF_BUDGET_BASELINE_FILE` reads another baseline.
import { afterAll, afterEach } from "bun:test";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { Browser, BrowserContext, Frame, Page } from "playwright";
import {
  countHits,
  judge,
  parseBaseline,
  rowFile,
  rowKey,
  siteKey,
  type GateHit,
  type Judgement,
} from "./perfBudgetBaseline";

const webviews = path.resolve(import.meta.dir, "../..");
export const PERF_BUDGET_BASELINE = path.join(webviews, "test/perf-budget-baseline.tsv");
const BINDING = "__cmuxPerfBudgetGate";
/** How long one frame's checks may take at a checkpoint; a hung or paused page is skipped. */
const FLUSH_TIMEOUT_MS = 2000;

type Instrumentation = {
  addListener(listener: {
    runAfterCreateBrowserContext?: (context: BrowserContext) => Promise<void>;
    runBeforeCloseBrowserContext?: (context: BrowserContext) => Promise<void>;
  }): void;
};

/** The file this process tests, and whether it runs the whole of it and nothing else. */
export type GateRun = { file: string; single: boolean; whole: boolean };

/**
 * Reads the run from bun's own command line (`bun test` hides its arguments from process.argv):
 * one test file named and no `-t` filter is a whole single-file run, as scripts/ci/run-webviews-tests.sh
 * runs every file. Several files in one process share the global hooks, so their hits cannot be told
 * apart: then a hit passes when any file's row names its class and site.
 */
export function readRun(main: string = Bun.main, cmdline: string[] | null = readCmdline()): GateRun {
  const file = path.relative(webviews, main);
  if (!cmdline) return { file, single: true, whole: false };
  const args = cmdline.slice(cmdline.indexOf("test") + 1);
  const files = args.filter((arg) => {
    try {
      return statSync(path.resolve(arg)).isFile();
    } catch {
      return false;
    }
  });
  const single = files.length === 1 && path.resolve(files[0]!) === path.resolve(main);
  const filtered = args.some((arg) => /^(?:-t|--test-name-pattern|--only|--todo)(?:=|$)/.test(arg));
  return { file, single, whole: single && !filtered };
}

function readCmdline(): string[] | null {
  try {
    return readFileSync("/proc/self/cmdline", "utf8").split("\0").filter(Boolean);
  } catch {
    return null;
  }
}

let script: Promise<string> | undefined;
/** The page script, bundled once per process. Its URL names perfBudgets, so the budgets' call sites skip its frames. */
function gateScript(): Promise<string> {
  script ??= (async () => {
    const built = await Bun.build({
      entrypoints: [path.join(import.meta.dir, "perfBudgetGate.entry.ts")],
      target: "browser",
    });
    if (!built.success) throw new Error(`perfBudgetGate: the page script did not build\n${built.logs.join("\n")}`);
    return `${await built.outputs[0]!.text()}\n//# sourceURL=cmux-perfBudgets-gate.js\n`;
  })();
  return script;
}

const hits = new Map<string, GateHit & { page?: Page }>();
const claimed = new Set<string>();
const contexts = new Set<BrowserContext>();
let opened = false;

function record(hit: GateHit, page?: Page) {
  if (!hit || typeof hit.id !== "string" || hits.has(hit.id)) return;
  hits.set(hit.id, { ...hit, page });
}

async function flushFrame(frame: Frame, page: Page) {
  let timer: Parameters<typeof clearTimeout>[0];
  // fixed-wait: a deadline, not a wait: a frame that answers sooner ends the race at once.
  const timeout = new Promise<undefined>((resolve) => (timer = setTimeout(resolve, FLUSH_TIMEOUT_MS)));
  try {
    const found = await Promise.race([
      frame
        .evaluate(
          () =>
            (globalThis as { __cmuxPerfBudgetGateHandle?: { flush(): unknown } }).__cmuxPerfBudgetGateHandle?.flush() ??
            [],
        )
        .catch(() => []),
      timeout,
    ]);
    for (const hit of (found as GateHit[] | undefined) ?? []) record(hit, page);
  } finally {
    clearTimeout(timer);
  }
}

async function flushPage(page: Page) {
  if (page.isClosed()) return;
  await Promise.all(page.frames().map((frame) => flushFrame(frame, page)));
}

async function flushContext(context: BrowserContext) {
  await Promise.all(context.pages().map(flushPage));
}

/**
 * Runs the page's waiting checks and takes its hits out of the gate: for a test that hits a budget on
 * purpose (perf-budgets.browser.test.ts) and asserts on the hits itself.
 */
export async function claimPerfBudgetHits(page: Page): Promise<GateHit[]> {
  await flushPage(page);
  const taken: GateHit[] = [];
  for (const [id, hit] of hits)
    if (hit.page === page && !claimed.has(id)) {
      claimed.add(id);
      const { page: _page, ...rest } = hit;
      taken.push(rest);
    }
  return taken;
}

let pageClose: Page["close"] | undefined;
let browserClose: Browser["close"] | undefined;
/** Page.close and Browser.close skip the instrumentation's close hook: run the checks first there too. */
function wrapClose(page: Page) {
  const proto = Object.getPrototypeOf(page) as Page;
  if (!pageClose) {
    pageClose = proto.close;
    proto.close = async function (this: Page, ...args: Parameters<Page["close"]>) {
      await flushPage(this).catch(() => {});
      return pageClose!.apply(this, args);
    };
  }
  const browser = page.context().browser();
  if (browser && !browserClose) {
    const browserProto = Object.getPrototypeOf(browser) as Browser;
    browserClose = browserProto.close;
    browserProto.close = async function (this: Browser, ...args: Parameters<Browser["close"]>) {
      await Promise.all(this.contexts().map(flushContext)).catch(() => {});
      return browserClose!.apply(this, args);
    };
  }
}

async function gateContext(context: BrowserContext) {
  opened = true;
  contexts.add(context);
  await context.exposeBinding(BINDING, ({ page }, hit: GateHit) => record(hit, page));
  await context.addInitScript({ content: await gateScript() });
  for (const page of context.pages()) wrapClose(page);
  context.on("page", wrapClose);
  context.on("close", () => contexts.delete(context));
}

function readBaseline(file: string): Map<string, number> {
  return existsSync(file) ? parseBaseline(readFileSync(file, "utf8")) : new Map();
}

function describeRows(rows: Judgement["grew"], examples: Map<string, GateHit>): string {
  return rows
    .map(({ key, count, baseline }) => {
      const [, kind, site] = key.split("\t");
      const example = examples.get(key);
      return `  ${kind} at ${site}: ${count} (baseline ${baseline})${example ? `\n    ${example.message}\n    page: ${example.url}` : ""}`;
    })
    .join("\n");
}

/**
 * Installs the gate on Playwright's engines (they share one client connection and its
 * instrumentation) and registers its checkpoints as global hooks. Called once, from test/preload.ts.
 */
export function installPerfBudgetGate(engines: unknown[], env: Record<string, string | undefined> = process.env) {
  if (env.CMUX_PERF_BUDGET_GATE === "off") return;
  const instrumentation = (engines[0] as { _instrumentation?: Instrumentation } | undefined)?._instrumentation;
  if (!instrumentation?.addListener) {
    // A Playwright without the client hook would leave every browser test ungated without a word.
    throw new Error("perfBudgetGate: Playwright's client instrumentation is missing; the gate cannot see new contexts");
  }
  instrumentation.addListener({
    runAfterCreateBrowserContext: gateContext,
    async runBeforeCloseBrowserContext(context) {
      await flushContext(context).catch(() => {});
    },
  });

  const baselinePath = env.CMUX_PERF_BUDGET_BASELINE_FILE ?? PERF_BUDGET_BASELINE;
  const shown = path.relative(webviews, baselinePath);
  let run: GateRun | undefined;
  /** Rows already failed, with the count they failed at: a test fails again only when its row grows further. */
  const failed = new Map<string, number>();

  const judgeNow = (whole: boolean) => {
    run ??= readRun();
    const baseline = readBaseline(baselinePath);
    const open = [...hits].filter(([id]) => !claimed.has(id)).map(([, hit]) => hit);
    const file = run.single ? run.file : "*";
    const counts = countHits(file, open);
    // The first hit of each row, for its message and page.
    const examples = new Map<string, GateHit>();
    for (const hit of open) {
      const key = rowKey(file, hit.kind, siteKey(hit.kind, hit.site));
      if (!examples.has(key)) examples.set(key, hit);
    }
    if (run.single) return { ...judge(file, counts, baseline, { whole: whole && run.whole }), counts, examples };
    // Several files in this process: a hit passes when any file's row names its class and site.
    const known = new Set([...baseline.keys()].map((key) => key.slice(rowFile(key).length + 1)));
    const grew = [...counts]
      .filter(([key]) => !known.has(key.slice(2)))
      .map(([key, count]) => ({ key, count, baseline: 0 }));
    return { grew, shrank: [], counts, examples };
  };

  const fix =
    "Fix the page (each message names the fix), or mark an element that must hold every child " +
    'data-perf-budget-allow="<reason>". The baseline only moves down: a new row is not added for you.';

  afterEach(async () => {
    if (!opened) return;
    await Promise.all([...contexts].map(flushContext));
    const { grew, examples } = judgeNow(false);
    const fresh = grew.filter(({ key, count }) => count > (failed.get(key) ?? 0));
    for (const { key, count } of fresh) failed.set(key, count);
    if (fresh.length > 0)
      throw new Error(
        `perf budget gate: this test's pages hit a perf budget more often than ${shown} allows:\n` +
          `${describeRows(fresh, examples)}\n${fix}`,
      );
  });

  afterAll(async () => {
    if (!opened) return;
    await Promise.all([...contexts].map(flushContext));
    const { grew, shrank, counts, examples } = judgeNow(true);
    run ??= readRun();
    const dir = env.CMUX_PERF_BUDGET_OBSERVED;
    if (dir && run.whole) {
      mkdirSync(dir, { recursive: true });
      const rows = [...counts].map(([key, count]) => `${key}\t${count}\n`).join("");
      writeFileSync(path.join(dir, `${run.file.replace(/[/\\]/g, "__")}.tsv`), `# ${run.file}\n${rows}`);
    }
    const problems: string[] = [];
    const fresh = grew.filter(({ key, count }) => count > (failed.get(key) ?? 0));
    if (fresh.length > 0)
      problems.push(
        `this file's pages hit a perf budget more often than ${shown} allows:\n${describeRows(fresh, examples)}\n${fix}`,
      );
    if (shrank.length > 0)
      problems.push(
        `this file hit a perf budget less often than ${shown} says; lower its rows so the fix stays:\n` +
          `${describeRows(shrank, new Map())}\n` +
          `  CMUX_BROWSER_TESTS=1 CMUX_PERF_BUDGET_OBSERVED=$dir bun test ./${run.file} && bun scripts/perf-budget-baseline.ts --update $dir`,
      );
    if (problems.length > 0) throw new Error(`perf budget gate: ${problems.join("\n")}`);
  });
}
