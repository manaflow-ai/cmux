// Measures the diff viewer's page stages in headless Chromium and WebKit against a running
// dev server (`bun run dev` with CMUX_DIFF_SIDECAR and CMUX_DIFF_DEV_REPO set to a fixture).
// Dev and bench only; nothing here ships. See plans/cmux-next/diff-perf.md.
//
// Usage: node bench/perf/browser-stages.mjs <url> <label> [chromium,webkit] [runs]
// Prints one JSON line per run.
import { execFileSync } from "node:child_process";
import { chromium, webkit } from "playwright";

const [url, label, browsersArg = "chromium,webkit", runsArg = "3"] = process.argv.slice(2);
const runs = Number(runsArg);
const timeoutMs = Number(process.env.PERF_TIMEOUT_MS ?? 240_000);

// Runs in the page before any page script. Polls once per frame for the visible milestones and
// records page-relative timestamps (performance.now(), 0 = navigation start).
const probe = () => {
  const perf = { marks: {}, longtasks: [], frames: 0 };
  window.__perf = perf;
  const mark = (name) => {
    if (!(name in perf.marks)) perf.marks[name] = performance.now();
  };
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) perf.longtasks.push([entry.startTime, entry.duration]);
    }).observe({ type: "longtask", buffered: true });
  } catch {}
  const inViewport = (element) => {
    const rect = element.getBoundingClientRect();
    return rect.height > 0 && rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth;
  };
  // Visits the light DOM and every open shadow root, stopping early when `visit` returns true.
  const walk = (root, visit) => {
    const stack = [root];
    let seen = 0;
    while (stack.length > 0 && seen < 60_000) {
      const node = stack.pop();
      seen += 1;
      if (node.nodeType === 1) {
        if (visit(node)) return true;
        if (node.shadowRoot) stack.push(node.shadowRoot);
      }
      for (let child = node.lastElementChild; child; child = child.previousElementSibling) stack.push(child);
    }
    return false;
  };
  const tick = () => {
    perf.frames += 1;
    const body = document.body;
    if (body?.dataset.streamFileCount && !perf.marks.firstBatch) mark("firstBatch");
    if (body?.dataset.streamElapsedMs) {
      mark("parseDone");
      perf.streamElapsedMs = Number(body.dataset.streamElapsedMs);
      perf.fileCount = Number(body.dataset.streamFileCount);
    }
    const need = ["fileList", "firstHunk", "firstHighlight"].filter((name) => !(name in perf.marks));
    if (need.length > 0 && body) {
      let visibleLines = 0;
      let highlightedLines = 0;
      walk(document, (element) => {
        if (!perf.marks.fileList && element.getAttribute("role") === "treeitem" && inViewport(element))
          mark("fileList");
        if (element.hasAttribute("data-line") && element.hasAttribute("data-line-type") && inViewport(element)) {
          const code = element.textContent ?? "";
          if (code.trim().length > 0) {
            visibleLines += 1;
            if (element.querySelector("span[style]")) highlightedLines += 1;
          }
        }
        return false;
      });
      if (visibleLines > 0) mark("firstHunk");
      if (highlightedLines > 0) {
        mark("firstHighlight");
        perf.highlightedVisible = highlightedLines;
        perf.visibleLines = visibleLines;
      }
    }
    if (performance.now() < 600_000) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
};

function rssOfTree(rootPid) {
  // Sum of RSS (KiB) for the browser process tree, Linux only.
  try {
    const out = execFileSync("ps", ["-e", "-o", "pid=,ppid=,rss="], { encoding: "utf8" });
    const rows = out
      .trim()
      .split("\n")
      .map((line) => line.trim().split(/\s+/).map(Number));
    const children = new Map();
    for (const [pid, ppid] of rows) children.set(ppid, [...(children.get(ppid) ?? []), pid]);
    const rss = new Map(rows.map(([pid, , kib]) => [pid, kib]));
    let total = 0;
    const stack = [rootPid];
    while (stack.length) {
      const pid = stack.pop();
      total += rss.get(pid) ?? 0;
      stack.push(...(children.get(pid) ?? []));
    }
    return total;
  } catch {
    return undefined;
  }
}

async function runOnce(browserType, name) {
  const browser = await browserType.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
  await page.addInitScript(probe);
  const consoleErrors = [];
  page.on("console", (message) => {
    if (message.type() === "error") consoleErrors.push(message.text().slice(0, 300));
  });
  const started = Date.now();
  await page.goto(url, { waitUntil: "commit" });
  // Done when the stream completed and the viewport has highlighted code, or on timeout.
  await page
    .waitForFunction(
      () => window.__perf?.marks.parseDone != null && window.__perf?.marks.firstHighlight != null,
      null,
      {
        timeout: timeoutMs,
        polling: 250,
      },
    )
    .catch(() => {});
  // Let the highlighter settle, then read worker counters and memory.
  await page.waitForTimeout(2000);
  const result = await page.evaluate(() => {
    const resources = performance.getEntriesByType("resource").map((entry) => ({
      name: entry.name.replace(location.origin, ""),
      start: entry.startTime,
      responseStart: entry.responseStart,
      end: entry.responseEnd,
      bytes: entry.transferSize || entry.encodedBodySize,
    }));
    const pick = (fragment) => resources.filter((entry) => entry.name.includes(fragment));
    const perf = window.__perf;
    const longtaskMs = perf.longtasks.reduce((sum, [, duration]) => sum + duration, 0);
    const maxLongtaskMs = perf.longtasks.reduce((max, [, duration]) => Math.max(max, duration), 0);
    return {
      marks: perf.marks,
      streamElapsedMs: perf.streamElapsedMs,
      fileCount: perf.fileCount,
      visibleLines: perf.visibleLines,
      highlightedVisible: perf.highlightedVisible,
      rpc: pick("/__cmux-diff/rpc"),
      patch: pick("/__cmux-diff/resource/"),
      workerMessages: Number(document.documentElement.dataset.cmuxDiffWorkerMessages ?? 0),
      workersCreated: Number(document.documentElement.dataset.cmuxDiffWorkersCreated ?? 0),
      longtaskCount: perf.longtasks.length,
      longtaskMs,
      maxLongtaskMs,
      jsHeapMB: performance.memory ? performance.memory.usedJSHeapSize / 1048576 : undefined,
    };
  });
  // Every process this node script started is the browser's; subtract node itself.
  const total = rssOfTree(process.pid);
  result.rssMB = total == null ? undefined : (total - process.memoryUsage().rss / 1024) / 1024;
  result.wallMs = Date.now() - started;
  result.consoleErrors = consoleErrors.slice(0, 3);
  await browser.close();
  return { label, browser: name, ...result };
}

for (const name of browsersArg.split(",")) {
  const browserType = name === "webkit" ? webkit : chromium;
  for (let index = 0; index < runs; index += 1) {
    const result = await runOnce(browserType, name);
    console.log(JSON.stringify(result));
  }
}
