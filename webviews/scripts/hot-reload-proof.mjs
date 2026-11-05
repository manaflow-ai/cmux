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
    edit: (text, n) =>
      text.replace('className="acpmux-composer-bar acpmux-composer-foot"', `data-hot-reload-probe="${n}" $&`),
    seen: (n) => !!document.querySelector(`[data-hot-reload-probe="${n}"]`),
  },
];

// Each edited file: its text before the first edit and the text this script last wrote.
const files = new Map();
// The edit being written, so a restore waits for it instead of racing it.
let writing = Promise.resolve();
async function write(file, text) {
  const absolute = path.join(webviews, file);
  const original = files.get(absolute)?.original ?? (await fs.readFile(absolute, "utf8"));
  files.set(absolute, { original, written: text });
  writing = fs.writeFile(absolute, text);
  await writing;
}
/// Puts back each file this script edited, unless someone changed it since: their edit stays.
async function restore() {
  await writing.catch(() => {});
  for (const [absolute, { original, written }] of files) {
    const now = await fs.readFile(absolute, "utf8").catch(() => undefined);
    if (now === written) await fs.writeFile(absolute, original);
    else console.error(`left ${path.relative(webviews, absolute)} as it is: it changed during the run`);
  }
  files.clear();
}
for (const [signal, code] of [
  ["SIGINT", 130],
  ["SIGTERM", 143],
])
  process.on(signal, () => restore().finally(() => process.exit(code)));

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
    // Our own handlers undo the edits first; Playwright's would exit before they finish.
    handleSIGINT: false,
    handleSIGTERM: false,
  });
  const page = await browser.newPage({ viewport: { width: 980, height: 820 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  // Vite's client logs each hot update and each Fast Refresh it gives up on, with the module.
  const vite = [];
  const viteListeners = new Set();
  page.on("console", (message) => {
    if (!message.text().startsWith("[vite]")) return;
    vite.push(message.text());
    for (const listener of viteListeners) listener();
  });
  // A reload counts when the page requests its new document, before that loads; a same-document
  // navigation (history.pushState) requests nothing.
  let reloads = 0;
  const navigationListeners = new Set();
  page.on("request", (request) => {
    if (!request.isNavigationRequest() || request.frame() !== page.mainFrame()) return;
    reloads += 1;
    for (const listener of navigationListeners) listener();
  });
  // Waits until Vite has answered a save: a reload (then its load), or quiet after Vite's last
  // message (`quietMs`, `firstMs` if it sent none yet). The answer is event driven, so a slow
  // reload is still counted and a hot swap costs no fixed wait.
  const settle = ({ quietMs = 1_500, firstMs = 4_000, maxMs = 20_000 } = {}) =>
    new Promise((resolve) => {
      let quiet;
      const cap = setTimeout(() => finish(), maxMs);
      const finish = (reloaded) => {
        clearTimeout(quiet);
        clearTimeout(cap);
        viteListeners.delete(onVite);
        navigationListeners.delete(onNavigate);
        if (!reloaded) return resolve();
        // The old document is still the loaded one here: wait for the new one's load.
        void page
          .waitForEvent("load", { timeout: 30_000 })
          .catch(() => {})
          .then(resolve);
      };
      const arm = (ms) => {
        clearTimeout(quiet);
        quiet = setTimeout(() => finish(), ms);
      };
      const onVite = () => arm(quietMs);
      const onNavigate = () => finish(true);
      viteListeners.add(onVite);
      navigationListeners.add(onNavigate);
      arm(firstMs);
    });
  await page.goto(`http://127.0.0.1:${port}/agent-pane/?mock`);
  const reloadsBefore = reloads;
  const editor = () => page.locator(".ProseMirror").first();
  // A full reload destroys the page's context mid-read: wait for the new page, then read again.
  const inPage = async (fn, arg) => {
    for (let attempt = 0; ; attempt += 1) {
      try {
        return await page.evaluate(fn, arg);
      } catch (error) {
        if (attempt === 3) throw error;
        await page.waitForLoadState("load");
      }
    }
  };
  const repliesDone = () => inPage((reply) => document.body.innerText.split(reply).length - 1, LAST_REPLY);

  // Each edit gets its own turn (about 3.5 s of scripted stream), started just before the save
  // and with the next message typed, so every edit lands mid-turn however long the one before took.
  let n = 0;
  for (const probe of PROBES) {
    n += 1;
    const original = await fs.readFile(path.join(webviews, probe.file), "utf8");
    const edited = probe.edit(original, n);
    if (edited === original) throw new Error(`${probe.name}: the edit no longer applies to ${probe.file}`);
    const prompt = `${PROMPT} (${n})`;
    await editor().waitFor({ timeout: 60_000 });
    const repliesBefore = await repliesDone();
    await editor().click();
    await page.keyboard.type(prompt);
    await page.keyboard.press("Enter");
    await page.getByText(prompt).first().waitFor();
    await editor().click();
    await page.keyboard.type(DRAFT);
    await inPage(() => (window.__hotReloadProbe = "same page"));
    const viteBefore = vite.length;
    const reloadsAtWrite = reloads;
    // This turn's last reply has not arrived yet: the edit lands mid-turn.
    const midTurn = (await repliesDone()) === repliesBefore;
    const started = performance.now();
    await write(probe.file, edited);
    let shown = true;
    await page.waitForFunction(probe.seen, n, { timeout: 15_000 }).catch(() => (shown = false));
    const ms = Math.round(performance.now() - started);
    // A reload can follow the update (Vite invalidates up the importers first): let it land.
    await settle();
    const now = await inPage(
      ({ draft, prompt }) => ({
        samePage: window.__hotReloadProbe === "same page",
        draftKept: (document.querySelector(".ProseMirror")?.textContent ?? "").includes(draft),
        transcriptKept: document.body.innerText.includes(prompt),
      }),
      { draft: DRAFT, prompt },
    );
    // The turn that was streaming when the code changed still finishes in the same page.
    let turnFinished = true;
    await page
      .waitForFunction(
        ({ reply, count }) => document.body.innerText.split(reply).length - 1 > count,
        { reply: LAST_REPLY, count: repliesBefore },
        { timeout: 20_000 },
      )
      .catch(() => (turnFinished = false));
    results.push({
      probe: probe.name,
      file: probe.file,
      midTurn,
      shown,
      ms,
      ...now,
      reloaded: reloads > reloadsAtWrite,
      turnFinished,
      vite: vite.slice(viteBefore),
    });
  }
  const live = { results, reloads: reloads - reloadsBefore };

  for (const row of results)
    console.log(
      `${row.probe} (${row.file}, saved ${row.midTurn ? "mid-turn" : "after the turn"}): ${row.shown ? `shown in ${row.ms} ms` : "never shown"}, ` +
        `reloaded ${row.reloaded}, same page ${row.samePage}, draft kept ${row.draftKept}, transcript kept ${row.transcriptKept}, ` +
        `turn finished ${row.turnFinished}` +
        (row.vite.length ? `\n    ${row.vite.join("\n    ")}` : ""),
    );
  console.log(`page reloads: ${live.reloads}`);

  const auditRows = [];
  if (audit) {
    await restore();
    await settle();
    // Every pane component module the page loaded; touching one sends Vite's update for it.
    const loaded = [...server.moduleGraph.idToModuleMap.keys()]
      .filter((id) => id.startsWith(path.join(webviews, pane)) && id.endsWith(".tsx") && !/\.(test|gallery)\./.test(id))
      .sort();
    for (const id of loaded) {
      const file = path.relative(webviews, id);
      await editor().waitFor({ timeout: 60_000 });
      await inPage(() => (window.__hotReloadProbe = "same page"));
      const before = reloads;
      const original = await fs.readFile(id, "utf8");
      await write(file, `${original}\n// hot-reload probe\n`);
      await settle();
      const reloaded = reloads > before || (await inPage(() => window.__hotReloadProbe !== "same page"));
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
  const ok =
    results.every(
      (row) =>
        row.midTurn &&
        row.shown &&
        !row.reloaded &&
        row.samePage &&
        row.draftKept &&
        row.transcriptKept &&
        row.turnFinished,
    ) && errors.length === 0;
  process.exitCode = ok ? 0 : 1;
} finally {
  await restore();
  await browser?.close();
  await server.close();
}
