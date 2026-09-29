// Reference backend that runs aside-dialect scenarios on real Playwright
// (headless Google Chrome, throwaway profile). Where Aside deviates from
// Playwright semantics, goldens take the Playwright value; see
// goldens/<dialect>/<scenario>.choices.json.
//
// Only Aside's browser globals are shimmed. snapshot()/annotatedScreenshot()
// are Aside representations with no Playwright equivalent, so they return
// placeholders here and those keys always come from the Aside reference.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

function loadPlaywright() {
  const dirs = [
    process.env.PARITY_PLAYWRIGHT_DIR,
    "/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules",
  ].filter(Boolean);
  for (const d of dirs) {
    try {
      return require(path.join(d, "playwright"));
    } catch {}
  }
  return require("playwright");
}

export async function runPlaywright(code) {
  const { chromium } = loadPlaywright();
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "parity-pw-"));
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext({ acceptDownloads: true, viewport: { width: 1280, height: 800 } });
  const lines = [];
  const g = {
    page: undefined,
    tabs: [],
    console: { log: (...a) => lines.push(a.map(String).join(" ")) },
  };
  const ids = new WeakMap();
  let nextId = 1;
  const idOf = (p) => {
    if (!ids.has(p)) ids.set(p, String(nextId++).padStart(32, "0"));
    return ids.get(p);
  };
  // Aside addresses snapshot refs as bare selectors ("e5", "f1e2").
  const refPattern = /^(f\d+)?e\d+$/;
  const patchRefs = (p) => {
    if (p.__parityRefs) return p;
    const locator = p.locator.bind(p);
    p.locator = (sel, o) => locator(refPattern.test(sel) ? `aria-ref=${sel}` : sel, o);
    p.__parityRefs = true;
    return p;
  };
  const setPage = (p) => {
    patchRefs(p);
    g.page = p;
    if (!g.tabs.includes(p)) g.tabs.push(p);
    return p;
  };
  const api = {
    openTab: async (url) => {
      const p = await context.newPage();
      await p.goto(url);
      return setPage(p);
    },
    closeTab: async (p) => {
      await p.close();
      g.tabs = g.tabs.filter((t) => t !== p);
      g.page = g.tabs.at(-1);
    },
    listBrowserTabs: async () =>
      Promise.all(
        context.pages().map(async (p) => ({
          active: p === g.page,
          faviconUrl: "",
          focusedWindow: false,
          id: `tab:${idOf(p)}`,
          targetId: idOf(p),
          title: await p.title(),
          url: p.url(),
          windowId: 1,
        })),
      ),
    attachBrowserTab: async (targetId) => setPage(context.pages().find((p) => idOf(p) === targetId)),
    attachActiveBrowserTab: async () => g.page,
    // Playwright's own AI snapshot. Aside's format descends from it; the Aside
    // recording still owns snapshot keys unless a choices file says otherwise.
    snapshot: async (p, opts = {}) => {
      const r = await p._snapshotForAI({ track: "parity" });
      const tree = typeof r === "string" ? r : r.full;
      return { tree, diff: typeof r === "string" ? tree : (r.incremental ?? tree), options: opts };
    },
    annotatedScreenshot: async (p) => ({ base64Image: (await p.screenshot()).toString("base64") }),
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    fetch: (url, init) => context.request.fetch(url, init).then((r) => ({
      ok: r.ok(),
      status: r.status(),
      json: () => r.json(),
      text: () => r.text(),
      arrayBuffer: async () => (await r.body()).buffer,
      headers: { get: (k) => r.headers()[k.toLowerCase()] ?? null },
    })),
    fs: {
      mkdir: (p, o) => fs.promises.mkdir(path.resolve(work, p), o),
      writeFile: (p, d) => fs.promises.writeFile(path.resolve(work, p), d),
      readFile: (p, enc) => fs.promises.readFile(path.resolve(work, p), enc),
      stat: (p) => fs.promises.stat(path.resolve(work, p)),
    },
    path,
    Buffer,
  };
  // Playwright resolves relative upload paths against process.cwd().
  const prevCwd = process.cwd();
  process.chdir(work);
  try {
    const fn = new Function(
      "g",
      "api",
      `with (api) { with (g) { return (async () => {\n${code}\n})(); } }`,
    );
    await fn(g, api);
  } finally {
    process.chdir(prevCwd);
    await browser.close();
    fs.rmSync(work, { recursive: true, force: true });
  }
  return lines.join("\n");
}
