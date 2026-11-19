// Transcript-at-rest clutter: load gallery states in headless Chromium with the pointer off the page
// and no key focus, find each transcript row (scripts/gallery/transcriptClutter.ts ROW_TYPES), and
// report the rows that show more controls than their budget, the same action twice (on the row, or
// on the row and again in its ⋯ menu), or a timing such as "13ms" on a row that is not running.
//
// Warn-only: it prints its findings and exits 0. `--strict` exits 1 on any finding, for a lane that
// wants it as a check of its own. It is not wired into CI (CLAUDE.md: no new CI gates).
//
// Usage: bun scripts/gallery/transcript-clutter.ts [--all] [--entry ID ...] [--json] [--strict]
//   default  the transcript's own entries (DEFAULT_ENTRIES), every variant of each
//   --all    every Agent pane entry and variant (thousands of states; minutes)
//   --entry  only these entries (repeatable)
// It builds the gallery (dist/gallery) when there is none, or when CMUX_CAPTURE_BUILD=1.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium, type Page } from "playwright";
import { preview } from "vite";
import { loadEntries } from "./entries";
import { judgeRow, ROW_TYPES, type Finding, type RowMeasure } from "./transcriptClutter";

const DEFAULT_ENTRIES = [
  "agent-pane.transcript",
  "agent-pane.subagent-retry",
  "agent-pane.subagent-done",
  "agent-pane.subagent-row-anatomy",
  "agent-pane.tool-errors",
  "agent-pane.edited-files",
];

const args = process.argv.slice(2);
const flag = (name: string) => args.includes(name);
const picked = args.flatMap((arg, index) => (args[index - 1] === "--entry" ? [arg] : []));
const entries = (await loadEntries()).filter((entry) =>
  picked.length > 0
    ? picked.includes(entry.id)
    : flag("--all")
      ? entry.area === "Agent pane"
      : DEFAULT_ENTRIES.includes(entry.id),
);
const wanted = picked.length > 0 ? picked : flag("--all") ? [] : DEFAULT_ENTRIES;
for (const id of wanted)
  if (!entries.some((entry) => entry.id === id)) console.error(`transcript-clutter: no gallery entry ${id}`);

const root = path.resolve(import.meta.dir, "../..");
if (!fs.existsSync(path.join(root, "dist/gallery")) || process.env.CMUX_CAPTURE_BUILD === "1") {
  const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
  await new Promise((resolve, reject) => {
    build.once("error", reject);
    build.once("exit", (code) => (code === 0 ? resolve(code) : reject(new Error(`gallery build exited ${code}`))));
  });
}
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const address = server.httpServer.address();
if (!address || typeof address === "string") throw new Error("gallery preview did not bind a TCP port");
const baseUrl = `http://127.0.0.1:${address.port}`;

/// Every row of the page, measured at rest. Runs in the page; it reads only the DOM.
function measure(types: { name: string; selector: string }[]) {
  const opacity = (element: Element) => {
    let value = 1;
    for (let node: Element | null = element; node; node = node.parentElement)
      value *= Number(getComputedStyle(node).opacity);
    return value;
  };
  const visible = (element: Element) => {
    const style = getComputedStyle(element);
    const box = element.getBoundingClientRect();
    return (
      box.width > 1 &&
      box.height > 1 &&
      style.visibility !== "hidden" &&
      !element.closest("[aria-hidden=true], [inert]") &&
      opacity(element) > 0.1
    );
  };
  const label = (element: Element) =>
    (element.getAttribute("aria-label") || element.getAttribute("title") || element.textContent || "").trim();
  const CONTROL = "button, a[href], [role=button], [role=menuitem], [aria-haspopup]";
  const CONTENT = ".acpmux-edited-file, .acpmux-edited-more, .acpmux-edited-diff";
  const all = types.map((type) => document.querySelectorAll(type.selector));
  const rows: (RowMeasure & { menuTrigger?: number })[] = [];
  const marked: Element[] = [];
  types.forEach((type, typeIndex) => {
    for (const row of all[typeIndex]!) {
      // A row inside another measured row counts as the inner one only: the outer one skips its controls.
      if (!visible(row)) continue;
      const inner = types.flatMap((_, other) => [...all[other]!].filter((el) => el !== row && row.contains(el)));
      const own = (element: Element) => !inner.some((nested) => nested.contains(element));
      // A row's content is not its chrome: an edited card's file rows and Show more, and the controls
      // of a diff the reader opened, do not count.
      const content = (element: Element) => Boolean(element.closest(CONTENT));
      const controls = [row, ...row.querySelectorAll(CONTROL)].filter(
        (element) => element.matches(CONTROL) && own(element) && !content(element) && visible(element),
      );
      const words: string[] = [];
      const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
      for (let node = walker.nextNode(); node; node = walker.nextNode())
        if (node.parentElement && own(node.parentElement) && visible(node.parentElement))
          words.push(node.textContent ?? "");
      const running = Boolean(
        row.closest("[data-state=running], [data-state=retrying], [aria-busy=true]") ||
        row.querySelector("[data-state=running], [data-state=retrying], [aria-busy=true], .cv-shimmer__base"),
      );
      const trigger = controls.find((element) => element.getAttribute("aria-haspopup") === "menu");
      if (trigger) marked.push(trigger);
      rows.push({
        type: type.name,
        controls: controls.map(label),
        text: words.join(" ").replace(/\s+/g, " ").trim(),
        running,
        menuTrigger: trigger ? marked.length - 1 : undefined,
      });
    }
  });
  marked.forEach((element, index) => element.setAttribute("data-clutter-menu", String(index)));
  return rows;
}

/// The names in the menu a row's ⋯ opens: opened with a real click, read, then closed with Escape.
async function menuOf(page: Page, index: number): Promise<string[]> {
  const trigger = page.locator(`[data-clutter-menu="${index}"]`);
  await trigger.click({ timeout: 3_000 }).catch(() => undefined);
  const items = await page
    .locator("[role=menuitem]")
    .allTextContents()
    .catch(() => []);
  await page.keyboard.press("Escape");
  await page.mouse.move(0, 0);
  return items.map((item) => item.trim()).filter(Boolean);
}

type Report = { entry: string; variant: string; type: string; text: string; findings: Finding[] };
const reports: Report[] = [];
let states = 0;
let rowsSeen = 0;
const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
try {
  const context = await browser.newContext({ viewport: { width: 760, height: 900 }, colorScheme: "dark" });
  const page = await context.newPage();
  for (const entry of entries) {
    for (const variant of Object.keys(entry.variants ?? {})) {
      const query = new URLSearchParams({
        entry: entry.id,
        variant,
        colorScheme: "dark",
        width: "normal",
        frame: "component",
      });
      try {
        await page.goto(`${baseUrl}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
      } catch {
        console.error(`transcript-clutter: ${entry.id} ${variant} did not load`);
        continue;
      }
      // At rest: no pointer on the page, no key focus. A variant that opened a menu or hovered on
      // purpose is measured after that is undone.
      await page.keyboard.press("Escape");
      await page.mouse.move(0, 0);
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await page.evaluate(
        () =>
          new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 400)))),
      );
      const rows = await page.evaluate(
        measure,
        ROW_TYPES.map(({ name, selector }) => ({ name, selector })),
      );
      states += 1;
      rowsSeen += rows.length;
      for (const row of rows) {
        const menu = row.menuTrigger === undefined ? undefined : await menuOf(page, row.menuTrigger);
        const findings = judgeRow({ ...row, menu });
        if (findings.length > 0)
          reports.push({ entry: entry.id, variant, type: row.type, text: row.text.slice(0, 80), findings });
      }
    }
  }
  await context.close();
} finally {
  await browser.close();
  await new Promise<void>((resolve, reject) => server.httpServer.close((error) => (error ? reject(error) : resolve())));
}

if (flag("--json")) for (const report of reports) console.log(JSON.stringify(report));
else
  for (const report of reports)
    for (const finding of report.findings)
      console.log(
        `${finding.rule.padEnd(9)} ${report.type.padEnd(17)} ${report.entry} ${report.variant}: ${finding.detail}  [${report.text}]`,
      );
const count = (rule: Finding["rule"]) =>
  reports.reduce((n, report) => n + report.findings.filter((finding) => finding.rule === rule).length, 0);
console.log(
  `transcript-clutter: ${states} states, ${rowsSeen} rows; over budget ${count("budget")}, duplicate ${count("duplicate")}, timing at rest ${count("timing")} (warn-only${flag("--strict") ? ", --strict" : ""})`,
);
if (flag("--strict") && reports.length > 0) process.exit(1);
