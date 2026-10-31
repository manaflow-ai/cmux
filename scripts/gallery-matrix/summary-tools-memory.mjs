// Linux CI, after the Rust harness exports its replies:
// node scripts/gallery-matrix/summary-tools-memory.mjs /absolute/export/directory
// Uses this directory's pinned Playwright; install its Chromium beforehand.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { chromium } from "playwright";

assert.equal(process.platform, "linux", "renderer RSS requires Linux /proc");
assert.ok(process.argv[2], "pass the Rust harness's wire reply directory");
const directory = resolve(process.argv[2]);
async function rss(pid) {
  const status = await readFile(`/proc/${pid}/status`, "utf8");
  return Number(status.match(/^VmRSS:\s+(\d+) kB$/m)?.[1]) * 1024;
}
for (const endpoint of ["sessions", "watch"]) {
  const browser = await chromium.launch({ args: [
    "--renderer-process-limit=1", "--disable-features=SpareRendererForSitePerProcess",
  ] });
  try {
    const page = await browser.newPage();
    await page.route("http://summary-tools.invalid/**", (route) =>
      route.request().url().endsWith("/reply")
        ? route.fulfill({ path: resolve(directory, `${endpoint}.json`), contentType: "application/json" })
        : route.fulfill({ body: "<!doctype html><title>Summary tools memory fixture</title>", contentType: "text/html" }));
    await page.goto("http://summary-tools.invalid/");
    const browserCdp = await browser.newBrowserCDPSession();
    const renderer = async () => {
      const { processInfo } = await browserCdp.send("SystemInfo.getProcessInfo");
      const renderers = processInfo.filter((p) => p.type === "renderer");
      assert.equal(renderers.length, 1, "a single renderer is required to attribute page RSS");
      return renderers[0].id;
    };
    const pid = await renderer();
    const pageCdp = await page.context().newCDPSession(page);
    await pageCdp.send("HeapProfiler.collectGarbage");
    const before = await rss(pid);
    const counts = await page.evaluate(async () => {
      globalThis.summaryWire = await (await fetch("/reply")).text();
      globalThis.summaryReply = JSON.parse(globalThis.summaryWire);
      const rows = globalThis.summaryReply.result.sessions;
      return { sessions: rows.length, closed_sessions: rows.filter((r) => r.status === "closed").length };
    });
    assert.equal(counts.sessions, 3000);
    assert.equal(counts.closed_sessions, 1000);
    await pageCdp.send("HeapProfiler.collectGarbage");
    assert.equal(await renderer(), pid, "renderer changed during measurement");
    const after = await rss(pid);
    assert.ok(Number.isFinite(before) && Number.isFinite(after));
    console.log("acpmux-summary-tools-page: " + JSON.stringify({
      fixture: "summary-tools-v1", seed: 0x5eed3000, method: `_acpmux/${endpoint}`, ...counts,
      browser: browser.version(), memory_source: "Linux /proc renderer VmRSS; bytes",
      page: "Minimal Chromium JSON consumer retaining raw reply and parsed tree after GC; not the production app",
      page_rss_before_bytes: before, page_rss_after_bytes: after, page_rss_delta_bytes: after - before,
    }));
  } finally {
    await browser.close();
  }
}
