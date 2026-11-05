// Proves the web UI hot-reloads while it is in use: the dev server `web-overlay.sh server --local`
// runs (vite.config.ts, `/agent-pane/`), the agent pane on the in-page mock daemon with a turn
// streaming and a draft typed, then real source edits. Each edit must show up in the open page
// without a page reload, with the draft and the transcript kept.
//   node scripts/hot-reload-proof.mjs [--audit] [out dir]
// --audit also touches every component file the pane loaded and reports which ones hot-swap
// and which ones reload the page (a reload drops the draft and the scroll position).
// Every edit is undone before the script exits.
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const audit = args.includes("--audit");
const out = path.resolve(args.find((arg) => !arg.startsWith("--")) ?? path.join(webviews, "dist/hot-reload-proof"));
const pane = "src/agent-session/acpmux";
const DRAFT = "laying track while the train moves";
const PROMPT = "add punctuation to greet";
const LAST_REPLY = "the default keeps old callers working";
// A visible change per kind of file the pane is made of. `edit` returns the new text; `seen`
// runs in the page and is true once the change shows.
const PROBES = [
  {
    name: "stylesheet",
    file: `${pane}/bottomStack.css`,
    edit: (text, n) => `${text}\n:root { --hot-reload-probe: ${n}; }\n`,
    seen: (n) => getComputedStyle(document.documentElement).getPropertyValue("--hot-reload-probe").trim() === String(n),
  },
  {
    name: "composer component",
    file: `${pane}/ComposerFoot.tsx`,
    edit: (text, n) => text.replace('className="acpmux-composer-bar acpmux-composer-foot"', `data-hot-reload-probe="${n}" $&`),
    seen: (n) => !!document.querySelector(`[data-hot-reload-probe="${n}"]`),
  },
];

const files = new Map();
async function write(file, text) {
  const absolute = path.join(webviews, file);
  if (!files.has(absolute)) files.set(absolute, await fs.readFile(absolute, "utf8"));
  await fs.writeFile(absolute, text);
}
async function restore() {
  for (const [absolute, text] of files) await fs.writeFile(absolute, text);
  files.clear();
}
for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => restore().finally(() => process.exit(130)));

await fs.mkdir(out, { recursive: true });
const server = await createServer({
  configFile: path.join(webviews, "vite.config.ts"),
  server: { port: 0, strictPort: false, host: "127.0.0.1" },
  logLevel: "warn",
});
await server.listen();
const { port } = server.httpServer.address();
let browser;
const results = [];
try {
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    args: ["--no-sandbox"],
  });
  const page = await browser.newPage({ viewport: { width: 980, height: 820 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  // Vite's client logs each hot update and each full reload, with the module that caused it.
  const vite = [];
  page.on("console", (message) => message.text().startsWith("[vite]") && vite.push(message.text()));
  let loads = 0;
  page.on("load", () => (loads += 1));
  await page.goto(`http://127.0.0.1:${port}/agent-pane/?mock`);
  const editor = page.locator(".ProseMirror").first();
  await editor.waitFor({ timeout: 60_000 });
  // Start a turn, then type the next message while it streams.
  await editor.click();
  await page.keyboard.type(PROMPT);
  await page.keyboard.press("Enter");
  await page.getByText(PROMPT).first().waitFor();
  await editor.click();
  await page.keyboard.type(DRAFT);
  await page.evaluate(() => (window.__hotReloadProbe = "same page"));
  const loadsBefore = loads;
  // A full reload destroys the page's context mid-read: wait for the new page, then read it.
  const state = async () => {
    for (let attempt = 0; ; attempt += 1) {
      try {
        return await read();
      } catch (error) {
        if (attempt === 3) throw error;
        await page.waitForLoadState("load");
      }
    }
  };
  const read = () =>
    page.evaluate(
      ({ draft, prompt }) => ({
        samePage: window.__hotReloadProbe === "same page",
        draftKept: (document.querySelector(".ProseMirror")?.textContent ?? "").includes(draft),
        transcriptKept: document.body.innerText.includes(prompt),
      }),
      { draft: DRAFT, prompt: PROMPT },
    );

  let n = 0;
  for (const probe of PROBES) {
    n += 1;
    const original = files.get(path.join(webviews, probe.file)) ?? (await fs.readFile(path.join(webviews, probe.file), "utf8"));
    const edited = probe.edit(original, n);
    if (edited === original) throw new Error(`${probe.name}: the edit no longer applies to ${probe.file}`);
    const started = performance.now();
    const viteBefore = vite.length;
    await write(probe.file, edited);
    let shown = true;
    await page.waitForFunction(probe.seen, n, { timeout: 15_000 }).catch(() => (shown = false));
    const ms = Math.round(performance.now() - started);
    // Let a reload that follows the update land before reading the page.
    await page.waitForEvent("load", { timeout: 1_500 }).catch(() => {});
    results.push({ probe: probe.name, file: probe.file, shown, ms, ...(await state()), vite: vite.slice(viteBefore) });
  }
  // The turn that was streaming when the code changed still finishes in the same page.
  let turnFinished = true;
  await page.getByText(LAST_REPLY).first().waitFor({ timeout: 20_000 }).catch(() => (turnFinished = false));
  await page.screenshot({ path: path.join(out, "after-edits.png") });
  const live = { results, turnFinished, reloads: loads - loadsBefore, ...(await state()) };

  for (const row of results)
    console.log(
      `${row.probe} (${row.file}): ${row.shown ? `shown in ${row.ms} ms` : "never shown"}, ` +
        `same page ${row.samePage}, draft kept ${row.draftKept}, transcript kept ${row.transcriptKept}` +
        (row.vite.length ? `\n    ${row.vite.join("\n    ")}` : ""),
    );
  console.log(`streaming turn finished after the edits: ${turnFinished}; page reloads: ${live.reloads}`);

  const auditRows = [];
  if (audit) {
    // Runs `fn` in the page, again after any reload that lands meanwhile.
    const inPage = async (fn) => {
      for (let attempt = 0; ; attempt += 1) {
        try {
          return await page.evaluate(fn);
        } catch (error) {
          if (attempt === 3) throw error;
          await page.waitForLoadState("load");
        }
      }
    };
    // Wait for a reload or two quiet seconds: Vite answers a save within a second.
    const settle = () => page.waitForEvent("load", { timeout: 2_000 }).catch(() => {});
    await restore();
    await settle();
    // Every pane component module the page loaded; touching one sends Vite's update for it.
    const loaded = [...server.moduleGraph.idToModuleMap.keys()]
      .filter((id) => id.startsWith(path.join(webviews, pane)) && /\.tsx$/.test(id) && !/\.(test|gallery)\./.test(id))
      .sort();
    for (const id of loaded) {
      const file = path.relative(webviews, id);
      await page.locator(".ProseMirror").first().waitFor({ timeout: 60_000 });
      await inPage(() => (window.__hotReloadProbe = "same page"));
      const before = loads;
      const original = await fs.readFile(id, "utf8");
      await write(file, `${original}\n// hot-reload probe\n`);
      await settle();
      const reloaded = loads > before || (await inPage(() => window.__hotReloadProbe !== "same page"));
      auditRows.push({ file, hot: !reloaded });
      await restore();
      await settle();
    }
    const hot = auditRows.filter((row) => row.hot);
    console.log(`audit: ${hot.length} of ${auditRows.length} loaded pane components hot-swap in place`);
    for (const row of auditRows.filter((row) => !row.hot)) console.log(`  reloads the page: ${row.file}`);
  }

  const report = { port, live, audit: auditRows, pageErrors: errors, vite };
  await fs.writeFile(path.join(out, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
  console.log(out);
  const ok = results.every((row) => row.shown && row.samePage && row.draftKept && row.transcriptKept) && turnFinished;
  process.exitCode = ok ? 0 : 1;
} finally {
  await restore();
  await browser?.close();
  await server.close();
}
