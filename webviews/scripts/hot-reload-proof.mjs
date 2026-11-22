// Proves the web UI hot-reloads while it is in use: the dev server `web-overlay.sh server --local`
// runs (vite.config.ts, `/agent-pane/`), the agent pane on the in-page mock daemon with a turn
// streaming and a draft typed, then real source edits. Each edit must show up in the open page
// without a page reload, with the draft and the transcript kept.
//   node scripts/hot-reload-proof.mjs [--audit] [out dir]
// --audit also touches every component file the pane loaded and reports which ones hot-swap
// and which ones reload the page (a reload drops the draft and the scroll position).
// --replay=BASE..HEAD saves a real change instead: the copy starts with BASE's version of every
// webviews file the commits change, then each file is saved as HEAD has it, one at a time (new
// files first, then edits, the ones that drop an export after the ones that don't, so importers
// change before what they imported goes, then deletions), with a draft typed and the transcript shown, and each
// save is reported as hot-applied or reloaded. It skips the probes and the audit.
// The edits go to a copy of this checkout in a temporary directory, never to the checkout itself:
// a save you make while it runs is never touched. The copy is deleted before the script exits.
import path from "node:path";
import os from "node:os";
import fs from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createServer } from "vite";
import { chromium } from "playwright";

const ownWebviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
// What the pane's dev server reads from the repository: webviews and the files outside it that
// its runtime imports.
const SOURCES = ["webviews", "config", "schemas", "web/data", "Resources/markdown-viewer"];
const args = process.argv.slice(2);
const replay = args.find((arg) => arg.startsWith("--replay="))?.slice("--replay=".length);
const audit = args.includes("--audit") && !replay;
const out = path.resolve(args.find((arg) => !arg.startsWith("--")) ?? path.join(ownWebviews, "dist/hot-reload-proof"));
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

// The copy: the checkout's SOURCES as they are now, generated files included, with its installed
// node_modules linked in.
const scratch = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), "cmux-hot-reload-proof-")));
const remove = () => fs.rm(scratch, { recursive: true, force: true });
for (const [signal, code] of [
  ["SIGINT", 130],
  ["SIGTERM", 143],
])
  process.on(signal, () => remove().finally(() => process.exit(code)));
const webviews = path.join(scratch, "webviews");

// Each edited file of the copy and its text before the first edit.
const files = new Map();
async function write(file, edit) {
  const absolute = path.join(webviews, file);
  const now = await fs.readFile(absolute, "utf8");
  const text = edit(now);
  if (text === now) throw new Error(`the edit no longer applies to ${file}`);
  if (!files.has(absolute)) files.set(absolute, now);
  await fs.writeFile(absolute, text);
}
/// Puts back each file of the copy this script edited, for the next edit to start clean.
async function restore() {
  for (const [absolute, original] of files) await fs.writeFile(absolute, original);
  files.clear();
}

await fs.mkdir(out, { recursive: true });
let server;
let browser;
const results = [];
try {
  const root = path.dirname(ownWebviews);
  const skip = new Set([path.join(ownWebviews, "node_modules"), path.join(ownWebviews, "dist")]);
  for (const source of SOURCES)
    await fs.cp(path.join(root, source), path.join(scratch, source), {
      recursive: true,
      filter: (from) => !skip.has(from),
    });
  await fs.symlink(path.join(ownWebviews, "node_modules"), path.join(webviews, "node_modules"), "dir");
  // --replay: each changed file with HEAD's text (undefined: HEAD deletes it); the copy gets BASE's.
  const saves = [];
  if (replay) {
    const [base, head] = replay.split("..");
    const git = (...gitArgs) => execFileSync("git", ["-C", root, ...gitArgs], { encoding: "utf8", maxBuffer: 1 << 28 });
    const exported = (text) =>
      new Set([
        ...[
          ...text.matchAll(/^export\s+(?:async\s+)?(?:const|let|function|class|type|interface|enum)\s+([\w$]+)/gm),
        ].map((match) => match[1]),
        ...[...text.matchAll(/^export\s+(?:type\s+)?\{([^}]*)\}/gm)].flatMap((match) =>
          match[1].split(",").map((name) =>
            name
              .trim()
              .split(/\s+as\s+/)
              .pop(),
          ),
        ),
      ]);
    const changed = git("diff", "--name-status", "--no-renames", base, head, "--", "webviews")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map((line) => line.split("\t"));
    for (const [status, file] of changed) {
      const before = status === "A" ? undefined : git("show", `${base}:${file}`);
      const text = status === "D" ? undefined : git("show", `${head}:${file}`);
      const inCopy = path.join(scratch, file);
      if (before === undefined) await fs.rm(inCopy, { force: true });
      else await fs.writeFile(inCopy, before);
      const drops =
        before !== undefined && text !== undefined && [...exported(before)].some((name) => !exported(text).has(name));
      saves.push({ status, file, text, rank: status === "A" ? 0 : status === "D" ? 3 : drops ? 2 : 1 });
    }
    saves.sort((a, b) => a.rank - b.rank);
  }
  server = await createServer({
    configFile: path.join(webviews, "vite.config.ts"),
    root: webviews,
    cacheDir: path.join(scratch, "vite-cache"),
    // node_modules resolves to this checkout's real path, outside the copy.
    server: {
      port: 0,
      strictPort: false,
      host: "127.0.0.1",
      fs: { allow: [scratch, path.join(ownWebviews, "node_modules")] },
    },
    logLevel: "warn",
  });
  await server.listen();
  const { port } = server.httpServer.address();
  browser = await chromium.launch({
    executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || undefined,
    args: ["--no-sandbox"],
    // Our own handlers delete the copy first; Playwright's would exit before they finish.
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
  for (const probe of replay ? [] : PROBES) {
    n += 1;
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
    await write(probe.file, (text) => probe.edit(text, n));
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
      await write(file, (text) => `${text}\n// hot-reload probe\n`);
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

  const replayRows = [];
  for (const save of saves) {
    // A save that broke the page (a build error) leaves no composer: load it again to go on.
    if (
      !(await editor()
        .waitFor({ timeout: 10_000 })
        .then(() => true)
        .catch(() => false))
    ) {
      await page.reload();
      await editor().waitFor({ timeout: 60_000 });
    }
    // A reload before this save took the draft and the transcript: lay them down again.
    if (!(await inPage((prompt) => document.body.innerText.includes(prompt), PROMPT))) {
      await editor().click();
      await page.keyboard.type(PROMPT);
      await page.keyboard.press("Enter");
      await page.getByText(PROMPT).first().waitFor();
    }
    if (
      !(await inPage((draft) => (document.querySelector(".ProseMirror")?.textContent ?? "").includes(draft), DRAFT))
    ) {
      await editor().click();
      await page.keyboard.type(DRAFT);
    }
    await inPage(() => (window.__hotReloadProbe = "same page"));
    const reloadsAtWrite = reloads;
    const errorsAtWrite = errors.length;
    const viteBefore = vite.length;
    const absolute = path.join(scratch, save.file);
    if (save.text === undefined) await fs.rm(absolute, { force: true });
    else {
      await fs.mkdir(path.dirname(absolute), { recursive: true });
      await fs.writeFile(absolute, save.text);
    }
    await settle();
    const broke = !(await editor()
      .waitFor({ timeout: 5_000 })
      .then(() => true)
      .catch(() => false));
    const now = await inPage(
      ({ draft, prompt }) => ({
        samePage: window.__hotReloadProbe === "same page",
        draftKept: (document.querySelector(".ProseMirror")?.textContent ?? "").includes(draft),
        transcriptKept: document.body.innerText.includes(prompt),
      }),
      { draft: DRAFT, prompt: PROMPT },
    );
    replayRows.push({
      ...save,
      text: undefined,
      broke,
      // A file the page never loaded (a test, a script) can't show anything: reported, not counted.
      loaded: (server.moduleGraph.getModulesByFile(absolute)?.size ?? 0) > 0,
      reloaded: reloads > reloadsAtWrite,
      ...now,
      pageErrors: errors.slice(errorsAtWrite),
      vite: vite.slice(viteBefore),
    });
  }
  for (const row of replayRows)
    console.log(
      `replay ${row.status} ${row.file}: ${row.broke ? "broke the page" : !row.loaded && !row.reloaded ? "not in the page" : row.reloaded || !row.samePage ? "reloaded the page" : "hot-applied"}, ` +
        `draft kept ${row.draftKept}, transcript kept ${row.transcriptKept}` +
        (row.pageErrors.length ? `, page errors: ${row.pageErrors.join(" | ")}` : "") +
        (row.vite.some((line) => line.includes("Could not Fast Refresh"))
          ? `\n    ${row.vite.filter((line) => line.includes("Could not Fast Refresh")).join("\n    ")}`
          : ""),
    );
  if (replay) {
    const counted = replayRows.filter((row) => row.loaded || row.reloaded);
    const hot = counted.filter((row) => !row.broke && !row.reloaded && row.samePage);
    console.log(`replay ${replay}: ${hot.length} of ${counted.length} saves the page loads hot-applied`);
  }

  const report = { port, live, audit: auditRows, replay: replayRows, pageErrors: errors, vite };
  await fs.writeFile(path.join(out, "report.json"), `${JSON.stringify(report, null, 2)}\n`);
  console.log(out);
  const ok = replay
    ? replayRows.every((row) => !row.broke && !row.reloaded && row.samePage && row.draftKept && row.transcriptKept)
    : results.every(
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
  await browser?.close();
  await server?.close();
  await remove();
}
