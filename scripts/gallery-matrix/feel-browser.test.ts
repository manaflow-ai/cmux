// The feel crawl against a page built to feel bad, in a real Chromium: each control has one known
// fault, and the crawl must name each one with its number, and nothing on the good controls. This is
// the check that the detectors detect (a crawl that flags nothing on the real gallery proves nothing
// by itself).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { crawlState, serveDirectory } from "./feel";

const fleetTest = process.env.CMUX_GALLERY_IN_VM === "1" ? test : test.skip;

const PAGE = `<!doctype html><html><head><style>
  body { margin: 0; font: 14px sans-serif; }
  button { display: block; margin: 8px; width: 160px; height: 28px; }
  #hovershift:hover { margin-top: 24px; }
</style></head><body>
<button id="good" aria-label="Good">Good</button>
<button id="dead" aria-label="Dead">Dead</button>
<button id="slow" aria-label="Slow">Slow</button>
<button id="popin" aria-label="Popin">Popin</button>
<button id="jump" aria-label="Jump">Jump</button>
<button id="hovershift" aria-label="Hovershift">Hovershift</button>
<div id="out"></div>
<div id="tail" style="height:40px">tail</div>
<script>
  const out = document.getElementById("out");
  const panel = (text, h) => { const d = document.createElement("div"); d.textContent = text; d.style.height = h + "px"; d.style.width = "300px"; return d; };
  // Good: answers in the same frame, one wave.
  good.onclick = () => good.setAttribute("aria-pressed", "true");
  // Dead: looks clickable, does nothing.
  dead.style.cursor = "pointer";
  // Slow: blocks the main thread, then answers.
  slow.onclick = () => { const end = performance.now() + 320; while (performance.now() < end); slow.setAttribute("aria-pressed", "true"); };
  // Pop-in: a spinner now, the content 250 ms later.
  popin.onclick = () => { out.replaceChildren(panel("...", 4)); setTimeout(() => out.replaceChildren(panel("rows", 120)), 250); };
  // Jump: answers, then a late banner pushes everything below it down.
  jump.onclick = () => { jump.setAttribute("aria-pressed", "true"); setTimeout(() => out.prepend(panel("banner", 60)), 300); };
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") out.replaceChildren(); });
  requestAnimationFrame(() => requestAnimationFrame(() => { document.documentElement.dataset.galleryReady = "1"; }));
</script></body></html>`;

let browser: Browser;
let server: { baseUrl: string; close: () => void };

beforeAll(async () => {
  if (process.env.CMUX_GALLERY_IN_VM !== "1") return;
  const dir = mkdtempSync(join(tmpdir(), "feel-fixture-"));
  writeFileSync(join(dir, "frame.html"), PAGE);
  server = await serveDirectory(dir);
  browser = await chromium.launch({ ...(process.env.CMUX_CHROME_HEADLESS_SHELL ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL } : { channel: "chrome" }) });
});

afterAll(async () => {
  await browser?.close();
  server?.close();
});

fleetTest("the crawl names each fault of a page built to feel bad, with its number", async () => {
  const report = await crawlState(browser, server.baseUrl, { id: "fixture", path_or_url: "frame.html", params: { entry: "fixture", variant: "bad", width: 640, height: 480 } }, 20);
  expect(report.error).toBeUndefined();
  if (process.env.FEEL_DEBUG) console.log(JSON.stringify(report.actions.map((a) => [a.action, a.target, a.responseMs, a.waves, a.shift, a.lateShift, a.findings.map((f) => f.kind)])));
  const byTarget = new Map<string, string[]>();
  for (const action of report.actions)
    for (const finding of action.findings) byTarget.set(finding.kind + " " + action.target, [...(byTarget.get(finding.kind + " " + action.target) ?? []), finding.detail]);
  const kinds = [...byTarget.keys()].sort();
  const named = (kind: string, label: string) => kinds.some((key) => key.startsWith(kind) && key.includes(`"${label}"`));
  expect(named("dead-click", "Dead")).toBe(true);
  expect(named("slow-response", "Slow")).toBe(true);
  expect(named("pop-in", "Popin")).toBe(true);
  expect(named("layout-jump", "Jump")).toBe(true);
  expect(named("hover-shift", "Hovershift")).toBe(true);
  // Nothing on the good control.
  expect(kinds.filter((key) => key.includes('"Good"'))).toEqual([]);
  const slow = report.actions.find((action) => action.action === "click" && action.target.includes('"Slow"'))!;
  expect(slow.responseMs!).toBeGreaterThan(200);
  const good = report.actions.find((action) => action.action === "click" && action.target.includes('"Good"'))!;
  expect(good.responseMs!).toBeLessThan(100);
}, 60_000);
