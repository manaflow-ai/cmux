// l10n-allow-file: benchmark fixtures and output, not shipped UI.
// The markdown page (cmux-page://cmux.markdown/, markdown-page.html) under files far past any
// a person writes by hand, in a production build on Chromium. Leo, 2026-11-17: "we should be
// stress testing everything that isn't already stress tested".
//
// A stand-in host (the cmuxPage bridge, as src/pages/markdown/devBridge.ts plays it on the dev
// server) answers `cmux.markdown.config` with a generated file and pushes `cmux.markdown.changes`
// for a live reload. Each case opens the page fresh and reads, in the page's own clock:
//   first  from the config answer to the first frame that shows the file's first line (the first
//          screen a person sees);
//   full   from the config answer to the frame that holds the file's last line, when it lands in
//          the WATCH_MS after the first screen (the rest of a long file loads in slices after it);
//   task   the longest main-thread task of the case (PerformanceObserver "longtask");
//   scroll the frame interval p95 while the page jumps through what it holds, 40 jumps;
//   reload a file being appended to 50 times: from each change to the frame that shows its new
//          last line, p50 and p95.
// The cases: prose at 10 KB (the 1x), 1 MB, 10 MB and 50 MB; a 100,000-line code fence; 5,000
// tables; 1,000-deep block quotes and lists; one 5 MB line; the 50-append reload over 10 KB and
// over 1 MB.
//
// The bound (the run exits 1 past it): every case's first screen is at most 3x the 10 KB file's
// (or LOAD_FLOOR_MS, whichever is larger), so opening a bigger file never costs a longer wait for
// its first screen; the 1 MB reload's p95 is at most 3x the 10 KB reload's (or 100 ms); no task
// passes FREEZE_MS; and no case crashes the page or stalls past CASE_DEADLINE_MS.
//   bun bench/markdown-viewer-stress.bench.ts [rounds=3] [--cases prose-10k,code-100k] [--dev]
// PROFILE=1 prints each open's 15 functions with the most self time (an unminified build).
/// <reference types="bun" />
import type { Browser, CDPSession, Page } from "playwright";
import { chromium } from "./browsers";
import { PERF_ROW_MARK, TARGET_MS, type PerfRow } from "./perfRow";
import {
  benchPositionals,
  buildLabel,
  gotoBenchPage,
  requireProductionReact,
  serveBenchPage,
} from "./support/benchPage";

const onlyAt = process.argv.indexOf("--cases");
const ONLY = onlyAt > 0 ? new Set(process.argv[onlyAt + 1]!.split(",")) : null;
const ROUNDS = Number(benchPositionals().filter((arg) => !ONLY || arg !== process.argv[onlyAt + 1])[0] ?? 3);
const CASE_DEADLINE_MS = Number(process.env.CASE_DEADLINE_MS ?? 90_000);
const LOAD_FLOOR_MS = Number(process.env.LOAD_FLOOR_MS ?? 400);
const RELOADS = 50;
/// How long after the first screen the bench watches the rest load; the longest task in it (or in the
/// whole case) past FREEZE_MS is a freeze, a failure.
const WATCH_MS = Number(process.env.WATCH_MS ?? 15_000);
const FREEZE_MS = Number(process.env.FREEZE_MS ?? 5_000);
const PROFILE = process.env.PROFILE === "1";
const log = (...args: unknown[]) => console.error("markdown-viewer-stress:", ...args);

const TOP = "stress-top";
const BOTTOM = "stress-bottom";

/** Mixed prose of about `bytes`: headings, paragraphs with marks and links, lists, a code block. */
function prose(bytes: number): string {
  const parts = [`# ${TOP}\n\n`];
  let size = parts[0]!.length;
  for (let i = 0; size < bytes; i++) {
    const section =
      `## Section ${i}\n\n` +
      `Paragraph ${i} has **bold**, _emphasis_, \`inline code\` and a [link](https://example.com/${i}) ` +
      `in a sentence long enough to wrap once in a 72 character column of text.\n\n` +
      `- item ${i}.1\n- item ${i}.2 with \`code\`\n- [ ] task ${i}\n\n` +
      "```ts\n" +
      `const value${i} = ${i} * 2;\n` +
      "```\n\n";
    parts.push(section);
    size += section.length;
  }
  parts.push(`${BOTTOM}\n`);
  return parts.join("");
}

function codeFence(lines: number): string {
  const body = Array.from({ length: lines }, (_, i) => `const line${i} = compute(${i}, "value ${i}");`).join("\n");
  return `# ${TOP}\n\n\`\`\`ts\n${body}\n\`\`\`\n\n${BOTTOM}\n`;
}

function tables(count: number): string {
  const one = (i: number) =>
    `| name ${i} | kind | size |\n| --- | --- | ---: |\n| row a | **bold** | ${i} |\n| row b | \`code\` | ${i * 2} |\n`;
  return `# ${TOP}\n\n${Array.from({ length: count }, (_, i) => one(i)).join("\n")}\n${BOTTOM}\n`;
}

function nestedQuotes(depth: number): string {
  return `# ${TOP}\n\n${"> ".repeat(depth)}deep quote\n\n${BOTTOM}\n`;
}

function nestedList(depth: number): string {
  const lines = Array.from({ length: depth }, (_, i) => `${"  ".repeat(i)}- level ${i}`);
  return `# ${TOP}\n\n${lines.join("\n")}\n\n${BOTTOM}\n`;
}

function longLine(bytes: number): string {
  const word = "lorem ipsum dolor sit amet ";
  return `# ${TOP}\n\n${word.repeat(Math.ceil(bytes / word.length))}\n\n${BOTTOM}\n`;
}

type Case = { name: string; text: () => string; reload?: boolean };

const KB = 1024;
const MB = 1024 * KB;
const CASES: readonly Case[] = [
  { name: "prose-10k", text: () => prose(10 * KB) },
  { name: "prose-1m", text: () => prose(MB) },
  { name: "prose-10m", text: () => prose(10 * MB) },
  { name: "prose-50m", text: () => prose(50 * MB) },
  { name: "code-100k", text: () => codeFence(100_000) },
  { name: "tables-5k", text: () => tables(5_000) },
  { name: "quote-1000", text: () => nestedQuotes(1_000) },
  { name: "list-1000", text: () => nestedList(1_000) },
  { name: "line-5m", text: () => longLine(5 * MB) },
  { name: "reload-10k", text: () => prose(10 * KB), reload: true },
  { name: "reload-1m", text: () => prose(MB), reload: true },
];

/// The stand-in host, before the page's own code. The file comes from `/__bench/fixture` (a route
/// the bench answers), so a 50 MB text never passes through an init script. Every reply and the
/// moment of the config answer are recorded on `window.__mdBench`.
function installHost(): void {
  type Envelope = { t: string; id?: number; op?: string; stream?: string };
  type Bench = {
    configAt: number;
    firstAt: number;
    text: string;
    subs: Map<string, number>;
    seq: number;
    longest: number;
    tasks: number;
    emit: (stream: string, data: unknown) => void;
  };
  const bench: Bench = {
    configAt: 0,
    firstAt: 0,
    text: "",
    subs: new Map(),
    seq: 0,
    longest: 0,
    tasks: 0,
    emit(stream, data) {
      const sub = bench.subs.get(stream);
      if (sub === undefined) return;
      const receive = (window as unknown as Record<string, (m: unknown) => void>).__cmuxPageReceive;
      receive?.({ t: "ev", sub, seq: ++bench.seq, data });
    },
  };
  (window as unknown as { __mdBench: Bench }).__mdBench = bench;
  // The first frame that shows the file's first block, watched from the page's start: a poll
  // started from the bench after `goto` may begin after it.
  const watchFirst = () => {
    const first = document.querySelector(".md-prose")?.firstElementChild;
    if (bench.configAt && first?.textContent?.includes("stress-top")) bench.firstAt = performance.now();
    else requestAnimationFrame(watchFirst);
  };
  requestAnimationFrame(watchFirst);
  new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) {
      bench.longest = Math.max(bench.longest, entry.duration);
      bench.tasks += entry.duration;
    }
  }).observe({ type: "longtask", buffered: true });
  let nextSub = 1;
  const postMessage = async (message: Envelope): Promise<unknown> => {
    if (message.t === "sub" && message.stream) {
      const sub = nextSub++;
      bench.subs.set(message.stream, sub);
      return { t: "ok", id: message.id, value: { sub } };
    }
    if (message.t !== "call") return null;
    if (message.op === "cmux.markdown.config") {
      bench.text = await (await fetch("/__bench/fixture", { cache: "no-store" })).text();
      bench.configAt = performance.now();
      return {
        t: "ok",
        id: message.id,
        value: { path: "/bench/stress.md", text: bench.text, hash: `h${bench.text.length}`, omnibar: true },
      };
    }
    return { t: "ok", id: message.id, value: {} };
  };
  (window as unknown as { webkit: unknown }).webkit = { messageHandlers: { cmuxPage: { postMessage } } };
}

/// The page-clock moment of the first frame whose editor's first (or last) block holds `needle`,
/// polled once a frame. One block's text, never the whole document's: reading a 50 MB document's
/// text every frame would be the bench's own cost.
async function frameShowing(
  page: Page,
  needle: string,
  deadline: number,
  where: "first" | "last" = "first",
): Promise<number | null> {
  return page.evaluate(
    ({ needle, deadline, where }) =>
      new Promise<number | null>((resolve) => {
        const end = performance.now() + deadline;
        const tick = () => {
          // The clock now, not the frame's timestamp, which can be before the work it shows.
          const now = performance.now();
          const prose = document.querySelector(".md-prose");
          const block = where === "first" ? prose?.firstElementChild : prose?.lastElementChild;
          if (block?.textContent?.includes(needle)) return resolve(now);
          if (now > end) return resolve(null);
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      }),
    { needle, deadline, where },
  );
}

type Result = {
  first: number[];
  full: number[];
  longest: number[];
  scroll: number[];
  reload: number[];
  failure?: string;
};

/** The page's CPU profile (PROFILE=1): print the top functions so far, or start again from now. */
type Profile = { print: () => Promise<void>; restart: () => Promise<void> };

async function openCase(
  browser: Browser,
  url: string,
  text: string,
): Promise<{ page: Page; crashed: () => boolean; profile: Profile | null }> {
  const context = await browser.newContext({ viewport: { width: 1200, height: 900 } });
  const page = await context.newPage();
  let crashed = false;
  page.on("crash", () => (crashed = true));
  page.on("pageerror", (error) => log(`page error: ${error.message}`));
  await page.route("**/__bench/fixture", (route) =>
    route.fulfill({ status: 200, contentType: "text/markdown", body: text }),
  );
  await page.addInitScript(installHost);
  const cdp = PROFILE ? await context.newCDPSession(page) : null;
  if (cdp) {
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 500 });
    await cdp.send("Profiler.start");
  }
  await page.goto(url);
  const profile = cdp && {
    print: () => topSelfTime(cdp),
    restart: async () => {
      await cdp.send("Profiler.stop");
      await cdp.send("Profiler.start");
    },
  };
  return { page, crashed: () => crashed, profile };
}

/// The profile so far: the 15 functions with the most self time, one line each.
async function topSelfTime(cdp: CDPSession): Promise<void> {
  type Node = { id: number; callFrame: { functionName: string; url: string; lineNumber: number } };
  const { profile } = (await cdp.send("Profiler.stop")) as unknown as {
    profile: { nodes: Node[]; samples: number[]; timeDeltas: number[] };
  };
  const self = new Map<number, number>();
  profile.samples.forEach((id, i) => self.set(id, (self.get(id) ?? 0) + (profile.timeDeltas[i] ?? 0) / 1000));
  const byName = new Map<string, number>();
  for (const node of profile.nodes) {
    const { functionName, url, lineNumber } = node.callFrame;
    const key = `${functionName || "(anonymous)"} ${url.replace(/^.*\//, "")}:${lineNumber + 1}`;
    byName.set(key, (byName.get(key) ?? 0) + (self.get(node.id) ?? 0));
  }
  for (const [key, ms] of [...byName].sort((a, b) => b[1] - a[1]).slice(0, 15))
    log(`  self ${ms.toFixed(0)} ms ${key}`);
}

async function runCase(browser: Browser, url: string, one: Case, text: string, result: Result): Promise<void> {
  const { page, crashed, profile } = await openCase(browser, url, text);
  try {
    const timeout = (label: string) =>
      new Promise<never>((_, reject) =>
        setTimeout(() => reject(new Error(`${label} froze past ${CASE_DEADLINE_MS} ms`)), CASE_DEADLINE_MS),
      );
    const shown = await Promise.race([frameShowing(page, TOP, CASE_DEADLINE_MS), timeout("first screen")]);
    if (shown === null) throw new Error(`first screen not shown in ${CASE_DEADLINE_MS} ms`);
    const { configAt, firstAt } = await page.evaluate(() => {
      const bench = (window as unknown as { __mdBench: { configAt: number; firstAt: number } }).__mdBench;
      return { configAt: bench.configAt, firstAt: bench.firstAt };
    });
    result.first.push((firstAt || shown) - configAt);
    // The rest loads after the first screen (a 50 MB file takes minutes to parse): the bench
    // watches WATCH_MS and records the full load only when it lands in that time. A reload case
    // waits for its whole file, since it appends to it.
    const full = await Promise.race([
      frameShowing(page, BOTTOM, one.reload ? CASE_DEADLINE_MS : WATCH_MS, "last"),
      timeout("full load"),
    ]);
    if (full === null && one.reload) throw new Error(`last line not shown in ${CASE_DEADLINE_MS} ms`);
    if (full !== null) result.full.push(full - configAt);
    // A reload case profiles its reloads, not its open.
    if (!one.reload) await profile?.print();
    const longest = await page.evaluate(
      () => (window as unknown as { __mdBench: { longest: number } }).__mdBench.longest,
    );
    result.longest.push(longest);
    // Jumps through the document, one per frame; each frame interval is what that jump cost.
    const intervals = await Promise.race([
      page.evaluate(
        () =>
          new Promise<number[]>((resolve) => {
            const scroller = document.querySelector<HTMLElement>(".md-scroll") ?? document.scrollingElement!;
            const out: number[] = [];
            let last = 0;
            let step = 0;
            const tick = (now: number) => {
              if (last) out.push(now - last);
              last = now;
              if (step === 40) return resolve(out);
              const fraction = ((step * 7919) % 40) / 40;
              scroller.scrollTop = fraction * (scroller.scrollHeight - scroller.clientHeight);
              step++;
              requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          }),
      ),
      timeout("scroll"),
    ]);
    result.scroll.push(...intervals);
    if (one.reload) {
      await profile?.restart();
      let current = text;
      for (let i = 0; i < RELOADS; i++) {
        const needle = `appended-${i}-end`;
        current = `${current}\nParagraph appended ${i}, ${needle}\n`;
        const took = await Promise.race([
          page.evaluate(
            ({ text, needle }) =>
              new Promise<number>((resolve) => {
                const bench = (window as unknown as { __mdBench: { emit: (stream: string, data: unknown) => void } })
                  .__mdBench;
                const start = performance.now();
                bench.emit("cmux.markdown.changes", { path: "/bench/stress.md", hash: `h${text.length}`, text });
                const tick = () => {
                  const last = document.querySelector(".md-prose")?.lastElementChild;
                  if (last?.textContent?.includes(needle)) resolve(performance.now() - start);
                  else requestAnimationFrame(tick);
                };
                requestAnimationFrame(tick);
              }),
            { text: current, needle },
          ),
          timeout(`reload ${i}`),
        ]);
        result.reload.push(took);
      }
      await profile?.print();
    }
  } finally {
    if (crashed()) result.failure = "the page crashed";
    await page
      .context()
      .close()
      .catch(() => {});
  }
}

const quantile = (values: readonly number[], q: number): number => {
  if (!values.length) return Number.NaN;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
};
const fmt = (value: number) => (Number.isFinite(value) ? value.toFixed(1) : "-");

const served = await serveBenchPage("/markdown-page.html", { unminified: PROFILE });
const browser = await chromium.launch({ headless: true });
const results = new Map<string, Result>();
try {
  {
    // The build check: a dev bundle's numbers are refused unless --dev labelled them.
    const probe = await browser.newPage();
    await probe.addInitScript(installHost);
    await probe.route("**/__bench/fixture", (route) => route.fulfill({ status: 200, body: prose(KB) }));
    await gotoBenchPage(probe, served);
    await frameShowing(probe, TOP, 30_000);
    await requireProductionReact(probe, served);
    await probe.close();
  }
  for (const one of CASES) {
    if (ONLY && !ONLY.has(one.name)) continue;
    const text = one.text();
    const result: Result = { first: [], full: [], longest: [], scroll: [], reload: [] };
    results.set(one.name, result);
    const rounds = one.name.startsWith("reload") ? 1 : ROUNDS;
    for (let round = 0; round < rounds && !result.failure; round++) {
      try {
        await runCase(browser, served.url, one, text, result);
      } catch (error) {
        result.failure = error instanceof Error ? error.message : String(error);
      }
    }
    log(
      `${one.name} (${(text.length / MB).toFixed(2)} MB): first p50 ${fmt(quantile(result.first, 0.5))} ` +
        `p95 ${fmt(quantile(result.first, 0.95))} ms, full p50 ${fmt(quantile(result.full, 0.5))} ms, ` +
        `longest task ${fmt(Math.max(0, ...result.longest))} ms, scroll frame p95 ${fmt(quantile(result.scroll, 0.95))} ms` +
        (result.reload.length
          ? `, reload p50 ${fmt(quantile(result.reload, 0.5))} p95 ${fmt(quantile(result.reload, 0.95))} ms`
          : "") +
        (result.failure ? `  FAILED: ${result.failure}` : ""),
    );
  }
} finally {
  await browser.close();
  await served.close();
}

// The rows and the bound.
const label = buildLabel(served);
const failures: string[] = [];
const base = results.get("prose-10k");
const firstBound = base?.first.length ? Math.max(3 * quantile(base.first, 0.95), LOAD_FLOOR_MS) : LOAD_FLOOR_MS;
for (const [name, result] of results) {
  if (result.failure) failures.push(`${name}: ${result.failure}`);
  if (result.first.length) {
    const p95 = quantile(result.first, 0.95);
    const row: PerfRow = {
      name: `markdown_viewer.${name}.first_screen`,
      p50: quantile(result.first, 0.5),
      p95,
      target: TARGET_MS.load,
    };
    console.log(PERF_ROW_MARK + JSON.stringify(row));
    if (p95 > firstBound) failures.push(`${name}: first screen p95 ${fmt(p95)} ms > bound ${fmt(firstBound)} ms`);
  }
  if (result.reload.length) {
    const row: PerfRow = {
      name: `markdown_viewer.${name}.change`,
      p50: quantile(result.reload, 0.5),
      p95: quantile(result.reload, 0.95),
      target: TARGET_MS.response,
    };
    console.log(PERF_ROW_MARK + JSON.stringify(row));
  }
  const longest = Math.max(0, ...result.longest);
  if (longest > FREEZE_MS) failures.push(`${name}: a ${fmt(longest)} ms task (freeze, > ${FREEZE_MS} ms)`);
}
const small = results.get("reload-10k");
const large = results.get("reload-1m");
if (small?.reload.length && large?.reload.length) {
  const bound = Math.max(3 * quantile(small.reload, 0.95), TARGET_MS.response);
  const p95 = quantile(large.reload, 0.95);
  if (p95 > bound) failures.push(`reload-1m: change p95 ${fmt(p95)} ms > bound ${fmt(bound)} ms`);
}
log(`build ${label}; first-screen bound ${fmt(firstBound)} ms`);
if (failures.length) {
  for (const failure of failures) log(`FAIL ${failure}`);
  process.exit(1);
}
log("PASS");

// The timeouts above still hold timers; the verdict is in.
process.exit(0);
