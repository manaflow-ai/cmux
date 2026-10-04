// Keyboard-only scripts and axe-core scans for each library build, in headless Chromium and WebKit.
// Usage: bun install && node build.mjs && node run.mjs [lib...]. Writes results-keyboard.json.
import { chromium, webkit } from "playwright";
import { createServer } from "node:http";
import { readFileSync, existsSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const require = createRequire(import.meta.url);
const here = path.dirname(new URL(import.meta.url).pathname);
const axeSource = readFileSync(require.resolve("axe-core/axe.min.js"), "utf8");
const LIBS = process.argv.slice(2).length ? process.argv.slice(2) : ["rac", "baseui", "ariakit", "radix-no-combobox"];
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };

const server = createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const [, lib, ...rest] = url.pathname.split("/");
  let file = path.join(here, "dist", lib, rest.join("/") || "index.html");
  if (!existsSync(file)) file = path.join(here, "dist", lib, "index.html");
  res.writeHead(200, { "content-type": TYPES[path.extname(file)] ?? "application/octet-stream" });
  res.end(readFileSync(file));
}).listen(0, "127.0.0.1");
await new Promise((r) => server.once("listening", r));
const origin = `http://127.0.0.1:${server.address().port}`;

// What has focus, as a screen reader would see it: the focused element, or the option or item its
// aria-activedescendant names.
const focusInfo = (page) => page.evaluate(() => {
  const el = document.activeElement;
  const describe = (node) => node && ({
    role: node.getAttribute("role") ?? node.tagName.toLowerCase(),
    name: (node.getAttribute("aria-label") ?? node.textContent ?? "").trim(),
  });
  const ad = el?.getAttribute("aria-activedescendant");
  return { ...describe(el), active: ad ? describe(document.getElementById(ad)) : null, expanded: el?.getAttribute("aria-expanded") };
});
const visible = (page, selector) => page.evaluate((s) => [...document.querySelectorAll(s)]
  .filter((n) => n.getClientRects().length && getComputedStyle(n).visibility !== "hidden")
  .map((n) => (n.textContent ?? "").trim()), selector);
const result = (page) => page.evaluate(() => document.getElementById("result").textContent);
const settle = (page, ms = 120) => page.waitForTimeout(ms);
async function axe(page, label, scans) {
  await page.evaluate(axeSource);
  const out = await page.evaluate(() => window.axe.run(document, { resultTypes: ["violations"] }));
  scans.push({ state: label, violations: out.violations.map((v) => ({ id: v.id, impact: v.impact, nodes: v.nodes.length, target: v.nodes[0]?.target?.join(" ") })) });
}

function checker() {
  const steps = [];
  return {
    steps,
    // kind: "key" = APG-required keyboard behavior, "opt" = APG-optional key, "sem" = what assistive tech is told.
    check(name, ok, detail, kind = "key") { steps.push({ name, kind, ok: Boolean(ok), detail }); },
  };
}

async function menuScript(page, c, scans) {
  await page.keyboard.press("Tab");
  let f = await focusInfo(page);
  c.check("Tab reaches the Source trigger", f.name === "Source", f);
  await page.keyboard.press("Enter");
  await settle(page);
  f = await focusInfo(page);
  c.check("Enter opens the menu and focuses the first item", f.role === "menuitem" && f.name === "Working tree", f);
  await axe(page, "menu open", scans);
  await page.keyboard.press("c");
  await settle(page);
  f = await focusInfo(page);
  c.check("Typeahead 'c' moves to Committed", f.name.startsWith("Committed"), f);
  await page.keyboard.press(process.env.RTL_MODE ? "ArrowLeft" : "ArrowRight");
  await settle(page, 250);
  f = await focusInfo(page);
  c.check("Arrow (inline-end) opens the submenu and focuses HEAD~1", f.name === "HEAD~1", f);
  await axe(page, "submenu open", scans);
  await page.keyboard.press("Escape");
  await settle(page, 250);
  f = await focusInfo(page);
  const menus = await visible(page, '[role="menu"]');
  c.check("Escape closes only the submenu, focus back on Committed", f.name.startsWith("Committed") && menus.length === 1, { f, menus });
  if (menus.length === 0) {
    // The whole menu closed; reopen it so the later steps measure their own behavior.
    await page.keyboard.press("Enter");
    await settle(page);
    await page.keyboard.press("c");
    await settle(page);
  }
  await page.keyboard.press(process.env.RTL_MODE ? "ArrowLeft" : "ArrowRight");
  await settle(page, 250);
  await page.keyboard.press("ArrowDown");
  await settle(page);
  await page.keyboard.press("Enter");
  await settle(page, 300);
  f = await focusInfo(page);
  c.check("Enter on HEAD~2 activates it", (await result(page)) === "source: HEAD~2", await result(page));
  c.check("Menu closes and focus returns to the trigger", f.name === "Source" && (await visible(page, '[role="menu"]')).length === 0, f);
}

async function pickerScript(page, c, scans) {
  await page.keyboard.press("Tab");
  await page.keyboard.press("Tab");
  await page.waitForFunction(() => document.body.textContent.includes("src/"), null, { timeout: 3000 }).catch(() => {});
  await settle(page);
  let f = await focusInfo(page);
  c.check("Tab reaches the path input", f.name === "Path", f);
  c.check("Input is exposed as role=combobox", f.role === "combobox", f, "sem");
  c.check("Async listing highlights the first row via aria-activedescendant", f.active?.name === "src/", f);
  if (!f.active) { await page.keyboard.press("ArrowDown"); await settle(page); }
  await page.keyboard.type("sr");
  // React Aria delays aria-activedescendant 500 ms after typed characters so VoiceOver reads the
  // typed letter first; wait past that.
  await settle(page, 700);
  f = await focusInfo(page);
  c.check("Typing filters and keeps a highlighted row", f.active?.name === "src/", f);
  await page.keyboard.press("ArrowRight");
  await page.waitForFunction(() => document.body.textContent.includes("components/"), null, { timeout: 3000 }).catch(() => {});
  await settle(page, 200);
  f = await focusInfo(page);
  c.check("ArrowRight drills into src and highlights its first row", f.active?.name === "components/", f);
  if (!f.active) { await page.keyboard.press("ArrowDown"); await settle(page); f = await focusInfo(page); }
  if (f.active?.name !== "components/") c.check("drill recovered", false, f);
  await axe(page, "picker after drill", scans);
  await page.keyboard.press("ArrowDown");
  await settle(page);
  f = await focusInfo(page);
  c.check("ArrowDown moves the highlight", f.active?.name === "main.tsx", f);
  await page.keyboard.press("Enter");
  await settle(page);
  c.check("Enter chooses the file", (await result(page)) === "chose: /src/main.tsx", await result(page));
  await page.keyboard.press("Backspace");
  await page.waitForFunction(() => document.body.textContent.includes("README.md"), null, { timeout: 3000 }).catch(() => {});
  await settle(page, 200);
  f = await focusInfo(page);
  const crumbAtRoot = await page.evaluate(() => document.body.textContent.includes("README.md"));
  c.check("Backspace on an empty query goes up to the root", crumbAtRoot && f.name === "Path", { crumbAtRoot, f });
  c.check("Root listing highlights a row again", f.active?.name === "src/", f);
  const announced = await page.evaluate(() => [...document.querySelectorAll('[aria-live], [role="status"], [role="log"]')].map((n) => n.textContent.trim()).filter(Boolean));
  c.check("Folder change or result count is announced in a live region (beyond our #result)", announced.some((t) => !t.startsWith("chose:")), announced, "sem");
}

async function toolbarScript(page, c, scans, skipPicker) {
  const tabs = skipPicker ? 2 : 3;
  for (let i = 0; i < tabs; i++) await page.keyboard.press("Tab");
  await settle(page, 900);
  let f = await focusInfo(page);
  c.check("Tab lands on the first tool", f.name === "Split view", f);
  let tips = await visible(page, ".tooltip");
  c.check("Keyboard focus shows its tooltip", tips.includes("Split view"), tips);
  const exposed = await page.evaluate(() => {
    const el = document.activeElement;
    const ids = (el.getAttribute("aria-describedby") ?? "").split(/\s+/).filter(Boolean);
    return { roleTooltip: [...document.querySelectorAll('[role="tooltip"]')].length, describedby: ids.map((id) => document.getElementById(id)?.textContent ?? null) };
  });
  c.check("Tooltip is role=tooltip and named by aria-describedby", exposed.roleTooltip > 0 && exposed.describedby.length > 0, exposed, "sem");
  await axe(page, "toolbar tooltip", scans);
  await page.keyboard.press(process.env.RTL_MODE ? "ArrowLeft" : "ArrowRight");
  await settle(page, 900);
  f = await focusInfo(page);
  c.check("Arrow (inline-end) moves to the next tool", f.name === "Unified view", f);
  tips = await visible(page, ".tooltip");
  c.check("Tooltip follows focus", tips.includes("Unified view") && !tips.includes("Split view"), tips);
  await page.keyboard.press("End");
  await settle(page);
  f = await focusInfo(page);
  c.check("End moves to the last tool", f.name === "Collapse all files", f, "opt");
  await page.keyboard.press("Home");
  await settle(page, 900);
  f = await focusInfo(page);
  c.check("Home moves to the first tool", f.name === "Split view", f, "opt");
  for (let i = 0; i < 4 && f.name !== "Split view"; i++) {
    await page.keyboard.press(process.env.RTL_MODE ? "ArrowRight" : "ArrowLeft");
    await settle(page);
    f = await focusInfo(page);
  }
  await settle(page, 900);
  await page.keyboard.press("Escape");
  await settle(page, 300);
  tips = await visible(page, ".tooltip");
  c.check("Escape hides the tooltip", tips.length === 0, tips);
  await page.keyboard.press("Enter");
  await settle(page);
  c.check("Enter activates the tool", (await result(page)) === "tool: split", await result(page));
  await page.keyboard.press(process.env.RTL_MODE ? "ArrowLeft" : "ArrowRight");
  await page.keyboard.press("Shift+Tab");
  await settle(page);
  f = await focusInfo(page);
  c.check("Shift+Tab leaves the toolbar in one step", !["Split view", "Unified view", "Wrap lines", "Collapse all files"].includes(f.name), f);
  await page.keyboard.press("Tab");
  await settle(page);
  f = await focusInfo(page);
  c.check("Tab re-enters the toolbar at the last focused tool", f.name === "Unified view", f, "opt");
}

const report = {};
for (const [engineName, engine] of [["chromium", chromium], ["webkit", webkit]]) {
  const browser = await engine.launch({ headless: true });
  for (const lib of LIBS) {
    for (const rtl of [false, true]) {
      const key = `${lib} ${engineName}${rtl ? " rtl" : ""}`;
      const scans = [];
      const groups = {};
      const scripts = [["menu", menuScript], ["picker", pickerScript], ["toolbar", toolbarScript]]
        .filter(([name]) => !(lib.startsWith("radix") && name === "picker"))
        .filter(([name]) => !rtl || name !== "picker");
      for (const [name, script] of scripts) {
        const context = await browser.newContext({ locale: rtl ? "ar-AE" : "en-US", reducedMotion: "reduce" });
        const page = await context.newPage();
        const errors = [];
        page.on("pageerror", (e) => errors.push(String(e)));
        page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
        await page.goto(`${origin}/${lib}/${rtl ? "?rtl" : ""}`);
        await page.waitForSelector("#root *");
        if (!rtl && name === "menu") await axe(page, "initial", scans);
        const c = checker();
        process.env.RTL_MODE = rtl ? "1" : "";
        try { await script(page, c, scans, lib.startsWith("radix")); } catch (e) { c.check("script ran", false, String(e)); }
        if (errors.length) c.check("no page errors", false, errors.slice(0, 3));
        groups[name] = c.steps;
        await context.close();
      }
      report[key] = { groups, axe: scans };
      const all = Object.values(groups).flat();
      const tally = (kind) => { const k = all.filter((s) => s.kind === kind); return `${k.filter((s) => s.ok).length}/${k.length}`; };
      const axeCount = scans.reduce((n, s) => n + s.violations.reduce((m, v) => m + v.nodes, 0), 0);
      const axeSerious = scans.reduce((n, s) => n + s.violations.filter((v) => v.impact === "serious" || v.impact === "critical").reduce((m, v) => m + v.nodes, 0), 0);
      report[key].summary = { key: tally("key"), opt: tally("opt"), sem: tally("sem"), axeNodes: axeCount, axeSeriousNodes: axeSerious };
      console.log(`${key.padEnd(34)} required keys ${tally("key")}  optional ${tally("opt")}  AT semantics ${tally("sem")}  axe nodes ${axeCount} (serious+critical ${axeSerious})`);
      for (const s of all.filter((s) => !s.ok)) console.log(`    FAIL[${s.kind}] ${s.name}: ${JSON.stringify(s.detail).slice(0, 200)}`);
      for (const s of scans) for (const v of s.violations) console.log(`    axe [${s.state}] ${v.id} (${v.impact}) x${v.nodes} ${v.target ?? ""}`);
    }
  }
  await browser.close();
}
writeFileSync(path.join(here, "results-keyboard.json"), JSON.stringify(report, null, 2));
server.close();
