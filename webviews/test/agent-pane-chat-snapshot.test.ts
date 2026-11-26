// l10n-allow-file: test fixture markup, not shipped UI.
// A chat's page after a relaunch draws what it last showed in its document's first frame, before
// the bundle runs (Leo, 2026-11-07: "we need to make these after-restart things load a lot faster";
// no split-half reveal). The page writes its visible window (chatSnapshot/capture.ts), the host
// serves it back as `__snapshot/chat.js`, and the first classic script draws it (boot.ts) in a
// shadow root under the page's own rules. These hold, in real Chromium:
// - the copy is on screen before the live page draws the chat, at the same boxes as the page it was
//   written from (header, rows, a scrolled transcript, the composer and its text), also when the
//   host's answer (loaded async, never waited on) comes after the bundle started;
// - a copy that comes after the live page drew the chat draws nothing;
// - the live page takes over in one frame: no frame shows both or neither, and nothing moves;
// - a copy written for another viewport draws the pane's chrome only: the composer with its hat, its
//   context ring and its mode and model pills, laid out at the new size where the live page draws them,
//   and no transcript rows (Leo, 2026-11-22: "agent chat skeleton for composer area not good enough.
//   doesnt include hat, context, permissions, etc still. nor cached view of those things").
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { chromium, type Browser, type BrowserContext, type Page, type Route } from "playwright";
import { snapshotCss } from "../scripts/agent-pane/snapshotCss.mjs";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-chat-snapshot.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-chat-snapshot: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat snapshot", () => test("chromium", () => {}));
    return;
  }
  const source = path.resolve(import.meta.dir, "../src/agent-session/acpmux/chatSnapshot");
  const work = mkdtempSync(path.join(tmpdir(), "chat-snapshot-test-"));

  async function bundle(entry: string, format: "iife" | "esm"): Promise<string> {
    const built = await Bun.build({ entrypoints: [entry], format, target: "browser" });
    if (!built.success) throw new Error(built.logs.map(String).join("\n"));
    return await built.outputs[0]!.text();
  }

  // The page's rules: `html`, `body` and `:root` selectors, a look attribute and a theme variable
  // the host sets before page code runs, and an agent variable only the page's theme event sets.
  const CSS = `
    :root { --gap: 12px; }
    html, body { margin: 0; height: 100%; }
    html[data-look="roomy"] .header { height: 48px; }
    body .header { background: var(--cmux-surface); }
    #root { position: relative; height: 100%; font: 14px/20px sans-serif; }
    .header { height: 30px; padding: 0 var(--gap); }
    .acpmux-scroll { position: absolute; top: 48px; bottom: 80px; left: 0; right: 0; overflow-y: auto; }
    .acpmux-spacer { position: relative; height: 4000px; }
    .acpmux-row { position: absolute; left: var(--agent-indent, 0px); right: 0; height: 40px; }
    .composer { position: absolute; bottom: 0; left: 0; right: 0; height: 80px; }
    .composer textarea { width: 300px; height: 40px; }
    .hat { position: absolute; left: 8px; right: 8px; top: -28px; height: 24px; display: flex; justify-content: space-between; }
    .foot { position: absolute; left: 8px; right: 8px; bottom: 4px; height: 24px; display: flex; gap: 8px; align-items: center; }
    .mode-pill { width: 140px; height: 20px; }
    .foot-gap { flex: 1; }
    .ring { width: 16px; height: 16px; border-radius: 50%; }
    .model-pill { width: 120px; height: 20px; }
    @media (min-width: 1px) { :root .acpmux-row { padding-left: 4px; } }
    .acpmux-dock { position: absolute; bottom: 80px; left: 0; right: 0; }
    .acpmux-dock .ask { height: 91px; }
    .acpmux-dock .acpmux-composer { height: 20px; }
  `;
  /// `dock`: a bottom stack over the composer, with an ask in it ("ask") or none ("bare").
  const MARKUP = (dock?: "ask" | "bare") => {
    const rows = Array.from(
      { length: 100 },
      (_, at) => `<article class="acpmux-row" data-row-id="r${at}" style="top:${at * 40}px">row ${at}</article>`,
    ).join("");
    const stack = dock
      ? `<div class="acpmux-dock">${dock === "ask" ? '<div class="ask">Trust this folder?</div>' : ""}<div class="acpmux-composer"></div></div>`
      : "";
    return `<div class="header">Chat title</div><div class="acpmux-scroll"><div class="acpmux-spacer">${rows}</div></div>${stack}<div class="composer"><div class="hat"><span class="hat-label">5 subagents running</span><span class="hat-tuck">^</span></div><div class="prompt" contenteditable="true"></div><textarea></textarea><div class="foot"><span class="mode-pill">Bypass permissions</span><span class="foot-gap"></span><span class="ring"></span><span class="model-pill">Opus 5.5 Medium</span></div></div>`;
  };
  /// The live page's first draw of a kept tail cut inside one busy turn: its last three rows, at the
  /// bottom of a view they do not fill (VirtualTranscript keeps a short tail at the view's end), with
  /// the older history still to load. The view is 600 - 48 - 80 = 472 px tall.
  const SHORT_MARKUP = () => {
    const rows = [97, 98, 99]
      .map(
        (at, index) =>
          `<article class="acpmux-row" data-row-id="r${at}" style="top:${352 + index * 40}px">row ${at}</article>`,
      )
      .join("");
    return `<div class="header">Chat title</div><div class="acpmux-scroll"><div class="acpmux-spacer" style="height:472px">${rows}</div></div><div class="composer"><div class="prompt" contenteditable="true"></div><textarea></textarea></div>`;
  };
  /// The person's theme.css, which the page adds once the host sends it (paneTheme.ts).
  const USER_CSS = "#root .header { height: 52px; }";
  const HTML_ATTRIBUTES = `data-look="roomy" style="--cmux-surface: rgb(10, 20, 30);"`;
  // As the app serves the page (build-agent-pane-web.sh): its rules linked as pane.css, and the copy's
  // (the same rules for its shadow tree) as pane-copy.css beside it.
  /// `attributes`: `<html>`'s, as the host's theme left them before page code ran.
  const htmlDocument = (body: string, attributes = HTML_ATTRIBUTES) =>
    `<!doctype html><html ${attributes}><head><link rel="stylesheet" id="cmux-pane-styles" href="/pane.css" data-copy="pane-copy.css"></head><body>${body}</body></html>`;
  const COPY_CSS = snapshotCss(CSS);
  /// Serves the page's two sheets; false for any other request.
  const servesSheet = (route: Route): boolean => {
    const { pathname } = new URL(route.request().url());
    if (pathname !== "/pane.css" && pathname !== "/pane-copy.css") return false;
    void route.fulfill({ contentType: "text/css", body: pathname === "/pane.css" ? CSS : COPY_CSS });
    return true;
  };
  /// A context whose pages get the page's sheets.
  async function newContext(width: number, height: number): Promise<BrowserContext> {
    const context = await browser.newContext({ viewport: { width, height } });
    await context.route("http://chat.test/*.css", (route) =>
      servesSheet(route) ? undefined : route.fulfill({ status: 404, body: "" }),
    );
    return context;
  }

  let browser: Browser;
  let boot = "";
  let capture = "";
  let live = "";
  beforeAll(async () => {
    boot = await bundle(path.join(source, "boot.ts"), "iife");
    const captureEntry = path.join(work, "capture-entry.ts");
    writeFileSync(
      captureEntry,
      `import { captureSnapshot } from ${JSON.stringify(path.join(source, "capture.ts"))};\n(globalThis as any).captureSnapshot = captureSnapshot;\n`,
    );
    capture = await bundle(captureEntry, "iife");
    // The bundle's stand-in: its first line reads what shows, then it renders the same chat under
    // the copy (as React does) and takes over (App.tsx `swapChatSnapshot`).
    const liveEntry = path.join(work, "live-entry.ts");
    writeFileSync(
      liveEntry,
      `import { reportChatSnapshot, swapChatSnapshot } from ${JSON.stringify(path.join(source, "live.ts"))};
const w = window as any;
w.reports = [];
// The live page's layout shifts from its first frame (the composer-area check reads them after the swap).
w.shifts = [];
new PerformanceObserver((list) => {
  for (const entry of list.getEntries() as any[])
    w.shifts.push({ value: entry.value, sources: (entry.sources ?? []).map((s: any) => s.node?.className ?? String(s.node)) });
}).observe({ type: "layout-shift", buffered: true } as any);
reportChatSnapshot(async (method, params) => {
  w.reports.push({ method, params, shown: !!document.querySelector("cmux-chat-snapshot") });
});
// The page draws the chat itself once the host's answer came (the handshake and the rows' read take
// longer than it, as at launch), or at once (\`drawFirst\`: the answer comes after the page drew).
const booted = () => w.__cmuxChatSnapshotShown !== undefined || w.__cmuxChatSnapshotMiss !== undefined;
// holdDraw keeps the page from drawing the chat at all, so the copy stays up (a slow first screen).
const wait = () => (!w.holdDraw && (w.drawFirst || booted()) ? draw() : requestAnimationFrame(wait));
requestAnimationFrame(wait);
function draw() {
const host = document.querySelector("cmux-chat-snapshot");
const box = (el: Element | null | undefined) => { const r = el!.getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; };
const copy = host?.shadowRoot;
const CHROME = [".hat-label", ".mode-pill", ".ring", ".model-pill", ".composer textarea"];
const chrome = (scope: ParentNode) => CHROME.map((selector) => { const el = scope.querySelector(selector); return el ? box(el) : null; });
w.atBundle = host && copy ? {
  chrome: chrome(copy),
  chromeOnly: copy.querySelector("[data-cmux-snapshot-chrome-only]") !== null,
  rowVisible: copy.querySelector(".acpmux-row") ? getComputedStyle(copy.querySelector(".acpmux-row")!).visibility : null,
  shown: true,
  header: box(copy.querySelector(".header")),
  // Written at the latest row, the copy leaves r60 out (out of view).
  row: copy.querySelector('[data-row-id="r60"]') ? box(copy.querySelector('[data-row-id="r60"]')) : null,
  last: copy.querySelector('[data-row-id="r99"]') ? box(copy.querySelector('[data-row-id="r99"]')) : null,
  composer: box(copy.querySelector(".composer textarea")),
  text: copy.querySelector(".composer .prompt")!.textContent,
  field: (copy.querySelector(".composer textarea") as HTMLTextAreaElement).value,
  scrollTop: copy.querySelector(".acpmux-scroll")!.scrollTop,
  rows: copy.querySelectorAll(".acpmux-row").length,
  headerColor: getComputedStyle(copy.querySelector(".header")!).backgroundColor,
  indent: getComputedStyle(copy.querySelector(".acpmux-row")!).left,
} : { shown: false };
const root = document.getElementById("root")!;
const user = document.createElement("style");
user.textContent = w.userCss;
document.head.append(user);
root.innerHTML = w.liveMarkup;
// askLate: the stack's ask comes that many frames after the chat drew (a folder's trust, answered later).
if (w.askLate) {
  let left = w.askLate;
  const later = () => {
    if (--left > 0) return requestAnimationFrame(later);
    const ask = document.createElement("div");
    ask.className = "ask";
    root.querySelector(".acpmux-dock")!.prepend(ask);
  };
  requestAnimationFrame(later);
}
document.documentElement.style.setProperty("--agent-indent", "20px");
root.querySelector(".prompt")!.textContent = "draft text";
const scroller = root.querySelector(".acpmux-scroll")!;
// \`atEnd\`: the live transcript keeps its latest row at its end, as VirtualTranscript does when it follows.
scroller.scrollTop = w.atEnd ? scroller.scrollHeight - scroller.clientHeight : 2000;
w.frames = [];
const watch = () => {
  const shownHost = document.querySelector("cmux-chat-snapshot");
  w.frames.push({ host: !!shownHost, opacity: root.style.opacity, chrome: chrome(shownHost?.shadowRoot ?? root), ask: !!root.querySelector(".acpmux-dock .ask") });
  if (w.frames.length < (w.askLate ? 14 : 6)) requestAnimationFrame(watch);
};
requestAnimationFrame(() => {
  // The swap's frame callback is queued before the watch's, so the watch reads what that frame paints.
  swapChatSnapshot();
  watch();
  requestAnimationFrame(() => requestAnimationFrame(() => {
    w.afterSwap = { header: box(root.querySelector(".header")), row: root.querySelector('[data-row-id="r60"]') ? box(root.querySelector('[data-row-id="r60"]')) : null, composer: box(root.querySelector(".composer textarea")), ...(w.atEnd ? { last: box(root.querySelector('[data-row-id="r99"]')) } : {}) };
    w.chromeAfterSwap = chrome(root);
  }));
});
}
`,
    );
    live = await bundle(liveEntry, "esm");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    rmSync(work, { recursive: true, force: true });
  });

  /// The page the chat was written from: the chat scrolled to row 50, a draft in the composer, and
  /// the agent theme's variable set as the page's theme event sets it.
  async function written(
    page: Page,
    attributes = HTML_ATTRIBUTES,
    dock?: "ask" | "bare",
    { atEnd = false }: { atEnd?: boolean } = {},
  ): Promise<Record<string, unknown>> {
    await page.route("http://chat.test/a.html", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: htmlDocument(`<main id="root">${MARKUP(dock)}</main>`, attributes),
      }),
    );
    await page.goto("http://chat.test/a.html");
    await page.addScriptTag({ content: capture });
    await page.evaluate((css) => ((window as any).userCss = css), USER_CSS);
    return await page.evaluate((atEnd) => {
      document.documentElement.style.setProperty("--agent-indent", "20px");
      const user = document.createElement("style");
      user.id = "acpmux-user-theme";
      user.textContent = (window as any).userCss;
      document.head.append(user);
      // The composer's draft is the prompt editor's markup; a field's typed text is never written.
      document.querySelector(".prompt")!.textContent = "draft text";
      document.querySelector("textarea")!.value = "typed in a field";
      const scroller = document.querySelector(".acpmux-scroll")!;
      scroller.scrollTop = atEnd ? scroller.scrollHeight - scroller.clientHeight : 2000;
      const box = (el: Element | null) => {
        const r = el!.getBoundingClientRect();
        return [r.x, r.y, r.width, r.height];
      };
      return {
        snapshot: (globalThis as any).captureSnapshot(document, "theme-1"),
        header: box(document.querySelector(".header")),
        row: box(document.querySelector('[data-row-id="r60"]')),
        composer: box(document.querySelector(".composer textarea")),
      };
    }, atEnd);
  }

  /// The next launch's document, served the snapshot as the host serves it.
  /// `holdUntil` holds the host's answer back (a busy main thread at launch) until the bundle ran or
  /// the page drew the chat; `drawFirst` has the page draw it before the answer comes.
  async function relaunched(
    page: Page,
    snapshot: unknown,
    theme = "theme-1",
    {
      holdUntil,
      drawFirst = false,
      holdDraw = false,
      attributes = HTML_ATTRIBUTES,
      dock,
      askLate = 0,
      atEnd = false,
      short = false,
    }: {
      holdUntil?: "bundle" | "drawn";
      drawFirst?: boolean;
      holdDraw?: boolean;
      attributes?: string;
      dock?: "ask" | "bare";
      askLate?: number;
      atEnd?: boolean;
      short?: boolean;
    } = {},
  ): Promise<void> {
    await page.route("http://chat.test/**", (route) => {
      const url = new URL(route.request().url());
      if (servesSheet(route)) return;
      if (url.pathname === "/b.html")
        return route.fulfill({
          contentType: "text/html",
          body: htmlDocument(
            `<main id="root"></main><script src="/fixture.js"></script><script async src="/__snapshot/chat.js"></script><script src="/chat-snapshot.js"></script><script type="module" src="/pane.js"></script>`,
            attributes,
          ),
        });
      if (url.pathname === "/fixture.js")
        return route.fulfill({
          contentType: "text/javascript",
          body: `self.liveMarkup=${JSON.stringify(short ? SHORT_MARKUP() : MARKUP(dock))};self.fullMarkup=${JSON.stringify(MARKUP(dock))};self.userCss=${JSON.stringify(USER_CSS)};self.drawFirst=${drawFirst};self.holdDraw=${holdDraw};self.askLate=${askLate};self.atEnd=${atEnd};`,
        });
      if (url.pathname === "/__snapshot/chat.js")
        return (
          holdUntil === undefined
            ? Promise.resolve()
            : page
                .waitForFunction(
                  (until) => (window as any)[until === "bundle" ? "reports" : "afterSwap"] !== undefined,
                  holdUntil,
                )
                .then(() => undefined)
        ).then(() =>
          route.fulfill({
            contentType: "text/javascript",
            body: `self.__cmuxChatSnapshot=${JSON.stringify(snapshot)};self.__cmuxChatSnapshotTheme=${JSON.stringify(theme)};self.__cmuxChatSnapshotBoot?.();`,
          }),
        );
      if (url.pathname === "/chat-snapshot.js") return route.fulfill({ contentType: "text/javascript", body: boot });
      if (url.pathname === "/pane.js") return route.fulfill({ contentType: "text/javascript", body: live });
      return route.fulfill({ status: 404, body: "" });
    });
    await page.goto("http://chat.test/b.html");
    if (holdDraw) {
      await page.waitForFunction(() => (window as any).__cmuxChatSnapshotShown !== undefined);
      return;
    }
    await page.waitForFunction(
      () =>
        ((window as any).afterSwap !== undefined || (window as any).atBundle?.shown === false) &&
        ((window as any).__cmuxChatSnapshotShown !== undefined || (window as any).__cmuxChatSnapshotMiss !== undefined),
    );
  }

  test("the copy shows before the bundle runs, where the chat was, and the live page takes over in one frame", async () => {
    const context = await newContext(800, 600);
    const writer = await context.newPage();
    const before = await written(writer);
    const snapshot = before.snapshot as { html: string; height: number };
    expect(snapshot).toBeDefined();
    // The visible window only: the rows out of view are not in it.
    expect(snapshot.html).not.toContain('data-row-id="r10"');
    expect(snapshot.html).not.toContain('data-row-id="r99"');
    const page = await context.newPage();
    await relaunched(page, snapshot);
    const atBundle = (await page.evaluate(() => (window as any).atBundle)) as Record<string, unknown>;
    expect(atBundle.shown).toBe(true);
    // The person's theme.css drew the header taller, and the copy draws it so too.
    expect((before.header as number[])[3]).toBe(52);
    expect(atBundle.header).toEqual(before.header);
    expect(atBundle.row).toEqual(before.row);
    expect(atBundle.composer).toEqual(before.composer);
    expect(atBundle.text).toBe("draft text");
    expect(atBundle.field).toBe("");
    expect(snapshot.html).not.toContain("typed in a field");
    expect(atBundle.scrollTop).toBe(2000);
    expect(atBundle.rows as number).toBeLessThan(20);
    expect(atBundle.headerColor).toBe("rgb(10, 20, 30)");
    expect(atBundle.indent).toBe("20px");
    const frames = (await page.evaluate(() => (window as any).frames)) as { host: boolean; opacity: string }[];
    // Each frame shows the copy over a clear live root, or the live root alone: never both, never neither.
    for (const frame of frames) expect(frame.host ? frame.opacity === "0" : frame.opacity === "").toBe(true);
    expect(frames[0]!.host).toBe(true);
    expect(frames.findIndex((frame) => !frame.host)).toBe(1);
    const afterSwap = (await page.evaluate(() => (window as any).afterSwap)) as Record<string, unknown>;
    expect(afterSwap).toEqual({ header: before.header, row: before.row, composer: before.composer });
    await context.close();
  });

  // Leo, 2026-11-14: "too much render shift when the thing restarts to update". The relaunch-shift bench
  // saw a folder's trust ask come into the stack 50 ms after the swap and draw every row up by 91 px.
  test("the copy stays until the live page lays out what it shows, then goes in one frame", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage(), HTML_ATTRIBUTES, "ask");
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { dock: "bare", askLate: 4 });
    await page.waitForFunction(() => (window as any).frames?.length >= 14);
    const frames = (await page.evaluate(() => (window as any).frames)) as { host: boolean; ask: boolean }[];
    const gone = frames.findIndex((frame) => !frame.host);
    // Held past the first frame, while the live stack had no ask; the first frame without the copy has it.
    expect(gone).toBeGreaterThan(1);
    expect(frames[gone]!.ask).toBe(true);
    for (const frame of frames.slice(0, gone)) expect(frame.host).toBe(true);
    for (const frame of frames.slice(gone)) expect(frame.host).toBe(false);
    const report = (await page.evaluate(() => (window as any).__cmuxChatSnapshotShown)) as Record<string, number>;
    expect(report.swappedAt).toBeGreaterThan(report.at);
    await context.close();
  });

  test("a copy whose part the live page never draws goes at the hold's end", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage(), HTML_ATTRIBUTES, "ask");
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { dock: "bare" });
    await page.waitForFunction(() => !document.querySelector("cmux-chat-snapshot"), undefined, { timeout: 3_000 });
    const shown = (await page.evaluate(() => (window as any).__cmuxChatSnapshotShown)) as Record<string, number>;
    // The hold (live.ts SWAP_MATCH_MS, 600 ms) and no longer, with a frame's slack.
    expect(shown.swappedAt! - shown.at).toBeLessThan(1_500);
    await context.close();
  });

  test("a press on the copy ends it and reaches nothing under it", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { holdDraw: true });
    expect(await page.evaluate(() => !!document.querySelector("cmux-chat-snapshot"))).toBe(true);
    // A live control the person can't see sits under the copy (a permission card's Allow).
    await page.evaluate(() => {
      const w = window as any;
      w.presses = [];
      const allow = document.createElement("button");
      allow.textContent = "Allow";
      allow.style.cssText = "position:fixed;left:100px;top:300px;width:200px;height:60px;";
      for (const name of ["pointerdown", "pointerup", "click"])
        allow.addEventListener(name, () => w.presses.push(name));
      window.addEventListener("keydown", (event) => w.presses.push(`key ${event.key}`));
      document.getElementById("root")!.append(allow);
    });
    await page.mouse.click(200, 330);
    expect(await page.evaluate(() => !!document.querySelector("cmux-chat-snapshot"))).toBe(false);
    expect(await page.evaluate(() => (window as any).presses)).toEqual([]);
    // Once the copy is gone, a press reaches the page as usual.
    await page.mouse.click(200, 330);
    await page.keyboard.press("a");
    expect(await page.evaluate(() => (window as any).presses)).toEqual(["pointerdown", "pointerup", "click", "key a"]);
    await context.close();
  });

  test("a press on the copy held past a second still reaches nothing under it", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { holdDraw: true });
    await page.evaluate(() => {
      const w = window as any;
      w.presses = [];
      const allow = document.createElement("button");
      allow.style.cssText = "position:fixed;left:100px;top:300px;width:200px;height:60px;";
      for (const name of ["pointerdown", "pointerup", "click"])
        allow.addEventListener(name, () => w.presses.push(name));
      document.getElementById("root")!.append(allow);
    });
    await page.mouse.move(200, 330);
    await page.mouse.down();
    // fixed-wait: the press is held past the old 1 s cut-off on purpose; the hold length is the behavior.
    await page.waitForTimeout(1_300);
    await page.mouse.up();
    expect(await page.evaluate(() => (window as any).presses)).toEqual([]);
    await page.mouse.click(200, 330);
    expect(await page.evaluate(() => (window as any).presses)).toEqual(["pointerdown", "pointerup", "click"]);
    await context.close();
  });

  test("a key held on the copy reaches nothing under it, its repeats and release too", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { holdDraw: true });
    await page.evaluate(() => {
      const w = window as any;
      w.keys = [];
      for (const name of ["keydown", "keyup"])
        document.addEventListener(name, (event) => w.keys.push(`${name} ${(event as KeyboardEvent).key}`));
    });
    await page.keyboard.down("Enter");
    // A held key's repeats: keydown again with the same code, before the release.
    await page.keyboard.down("Enter");
    await page.keyboard.down("Enter");
    await page.keyboard.up("Enter");
    expect(await page.evaluate(() => (window as any).keys)).toEqual([]);
    await page.keyboard.press("Enter");
    expect(await page.evaluate(() => (window as any).keys)).toEqual(["keydown Enter", "keyup Enter"]);
    await context.close();
  });

  test("once the live page took over, the first press reaches it", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot);
    expect(await page.evaluate(() => !!document.querySelector("cmux-chat-snapshot"))).toBe(false);
    await page.evaluate(() => {
      const w = window as any;
      w.presses = [];
      const button = document.createElement("button");
      button.style.cssText = "position:fixed;left:100px;top:300px;width:200px;height:60px;";
      for (const name of ["pointerdown", "pointerup", "click"])
        button.addEventListener(name, () => w.presses.push(name));
      window.addEventListener("keydown", (event) => w.presses.push(`key ${event.key}`));
      document.getElementById("root")!.append(button);
    });
    await page.mouse.click(200, 330);
    await page.keyboard.press("a");
    expect(await page.evaluate(() => (window as any).presses)).toEqual(["pointerdown", "pointerup", "click", "key a"]);
    await context.close();
  });

  test("a key on the copy ends it and reaches nothing under it", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { holdDraw: true });
    await page.evaluate(() => {
      const w = window as any;
      w.keys = [];
      document.addEventListener("keydown", (event) => w.keys.push(event.key));
    });
    await page.keyboard.press("Enter");
    expect(await page.evaluate(() => !!document.querySelector("cmux-chat-snapshot"))).toBe(false);
    expect(await page.evaluate(() => (window as any).keys)).toEqual([]);
    await context.close();
  });

  test("a write while the copy still covers the live root keeps a visible root", async () => {
    const context = await newContext(800, 600);
    const page = await context.newPage();
    await page.route("http://chat.test/a.html", (route) =>
      route.fulfill({ contentType: "text/html", body: htmlDocument(`<main id="root">${MARKUP()}</main>`) }),
    );
    await page.goto("http://chat.test/a.html");
    await page.addScriptTag({ content: capture });
    const html = (await page.evaluate(() => {
      document.getElementById("root")!.style.opacity = "0";
      return (globalThis as any).captureSnapshot(document, "theme-1").html;
    })) as string;
    expect(html.startsWith('<main id="root">')).toBe(true);
    expect(html).not.toContain("opacity");
    await context.close();
  });

  test("a block scrolled inside a shadow root draws at its offset", async () => {
    const context = await newContext(800, 600);
    const writer = await context.newPage();
    await writer.route("http://chat.test/a.html", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: htmlDocument(`<main id="root">${MARKUP()}<div id="code"></div></main>`),
      }),
    );
    await writer.goto("http://chat.test/a.html");
    await writer.addScriptTag({ content: capture });
    const snapshot = await writer.evaluate(() => {
      const shadow = document.getElementById("code")!.attachShadow({ mode: "open" });
      shadow.innerHTML = `<div class="wide" style="width:200px;overflow-x:auto;white-space:pre">${"x".repeat(400)}</div>`;
      shadow.querySelector(".wide")!.scrollLeft = 150;
      return (globalThis as any).captureSnapshot(document, "theme-1");
    });
    const page = await context.newPage();
    await relaunched(page, snapshot, "theme-1", { holdDraw: true });
    const left = await page.evaluate(
      () =>
        document
          .querySelector("cmux-chat-snapshot")!
          .shadowRoot!.querySelector("#code")!
          .shadowRoot!.querySelector(".wide")!.scrollLeft,
    );
    expect(left).toBe(150);
    await context.close();
  });

  test("rows placed past a million pixels down a long chat draw where the page drew them", async () => {
    // Leo, 2026-11-24, on a revive: "tons of layout shifts". The style attribute writes a length with six
    // significant digits, so a 6000-turn chat's rows (`top: 1026212.5px`) read `top: 1.02621e+06px`, and the
    // copy drew each up to 5 px off the live page it gave way to.
    const context = await newContext(800, 600);
    const writer = await context.newPage();
    await writer.route("http://chat.test/a.html", (route) =>
      route.fulfill({ contentType: "text/html", body: htmlDocument(`<main id="root">${MARKUP()}</main>`) }),
    );
    await writer.goto("http://chat.test/a.html");
    await writer.addScriptTag({ content: capture });
    // Each row in view and its drawn top, to 1/64 px (layout's unit), in the page or the copy's root.
    const READ_ROWS = `window.readRows = (scope) => Array.from(scope.querySelectorAll(".acpmux-row"))
      .map((row) => [row.dataset.rowId, Math.round(row.getBoundingClientRect().top * 64) / 64])
      .filter(([, top]) => top > -40 && top < 600);`;
    await writer.addScriptTag({ content: READ_ROWS });
    const { snapshot, drawn } = await writer.evaluate(() => {
      const base = 1_026_212.5;
      document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height = `${base + 100 * 41.75 + 3.25}px`;
      document.querySelectorAll<HTMLElement>(".acpmux-row").forEach((row, at) => {
        row.style.top = `${base + at * 41.75}px`;
      });
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = scroller.scrollHeight;
      const w = window as any;
      return { snapshot: w.captureSnapshot(document, "theme-1"), drawn: w.readRows(document) };
    });
    expect(drawn.length).toBeGreaterThan(5);
    expect(snapshot.html).not.toMatch(/\de\+0\d/);
    const page = await context.newPage();
    await relaunched(page, snapshot, "theme-1", { holdDraw: true });
    await page.addScriptTag({ content: READ_ROWS });
    const copied = await page.evaluate(() =>
      (window as any).readRows(document.querySelector("cmux-chat-snapshot")!.shadowRoot!),
    );
    expect(copied).toEqual(drawn);
    await context.close();
  });

  test("a box's checked state is written as it shows, both ways", async () => {
    const context = await newContext(800, 600);
    const page = await context.newPage();
    const boxes = `<input type="checkbox" id="was-on" checked><input type="checkbox" id="was-off">`;
    await page.route("http://chat.test/a.html", (route) =>
      route.fulfill({ contentType: "text/html", body: htmlDocument(`<main id="root">${MARKUP()}${boxes}</main>`) }),
    );
    await page.goto("http://chat.test/a.html");
    await page.addScriptTag({ content: capture });
    const html = (await page.evaluate(() => {
      (document.getElementById("was-on") as HTMLInputElement).checked = false;
      (document.getElementById("was-off") as HTMLInputElement).checked = true;
      return (globalThis as any).captureSnapshot(document, "theme-1").html;
    })) as string;
    expect(html).toContain('<input type="checkbox" id="was-on">');
    expect(html).toContain('<input type="checkbox" id="was-off" checked="">');
    await context.close();
  });

  test("a copy drawn under another theme draws nothing", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-2");
    expect(await page.evaluate(() => (window as any).atBundle.shown)).toBe(false);
    await context.close();
  });

  test("a copy written under another theme of the same appearance draws, in this theme's colors", async () => {
    // Nearly every update changes the theme's key (a token added or tuned): the copy was refused, and a
    // chat with no saved picture showed its loading state (Leo, 2026-11-14: "the agent chat after a bit").
    const context = await newContext(800, 600);
    const before = await written(
      await context.newPage(),
      `data-look="roomy" style="--cmux-surface: rgb(10, 20, 30); color-scheme: dark;"`,
    );
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-2", {
      holdDraw: true,
      attributes: `data-glass="plain" style="--cmux-surface: rgb(200, 0, 0); color-scheme: dark;"`,
    });
    const stand = await page.evaluate(() => {
      const html = document
        .querySelector("cmux-chat-snapshot")!
        .shadowRoot!.querySelector("cmux-snapshot-html") as HTMLElement;
      return {
        surface: html.style.getPropertyValue("--cmux-surface").trim(),
        look: html.getAttribute("data-look"),
        glass: html.getAttribute("data-glass"),
      };
    });
    expect(stand).toEqual({ surface: "rgb(200, 0, 0)", look: "roomy", glass: "plain" });
    await context.close();
  });

  test("under the theme it was written in, the copy keeps its own look attributes", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    // The host's document-start attributes, which the page replaces with its own once it runs.
    await relaunched(page, before.snapshot, "theme-1", {
      holdDraw: true,
      attributes: `data-look="plain" style="--cmux-surface: rgb(10, 20, 30);"`,
    });
    const look = await page.evaluate(() =>
      document
        .querySelector("cmux-chat-snapshot")!
        .shadowRoot!.querySelector("cmux-snapshot-html")!
        .getAttribute("data-look"),
    );
    expect(look).toBe("roomy");
    await context.close();
  });

  test("a copy written in another appearance draws nothing", async () => {
    const context = await newContext(800, 600);
    const before = await written(
      await context.newPage(),
      `style="--cmux-surface: rgb(10, 20, 30); color-scheme: dark;"`,
    );
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-2", {
      attributes: `style="--cmux-surface: rgb(250, 250, 250); color-scheme: light;"`,
    });
    expect(await page.evaluate(() => (window as any).atBundle.shown)).toBe(false);
    expect(await page.evaluate(() => (window as any).__cmuxChatSnapshotMiss)).toBe("theme");
    await context.close();
  });

  for (const [label, width, height] of [
    ["narrower (the sidebar came back wider)", 700, 600],
    ["wider", 900, 600],
    ["far shorter", 800, 400],
  ] as const)
    test(`a copy written at another size draws the composer's whole chrome where the live page draws it, ${label}, with no rows and no layout shift`, async () => {
      // Leo, 2026-11-22: "agent chat skeleton for composer area not good enough. doesnt include hat,
      // context, permissions, etc still. nor cached view of those things".
      const context = await newContext(800, 600);
      const before = await written(await context.newPage());
      const other = await newContext(width, height);
      const page = await other.newPage();
      await relaunched(page, before.snapshot);
      const atBundle = (await page.evaluate(() => (window as any).atBundle)) as {
        shown: boolean;
        chromeOnly: boolean;
        rowVisible: string | null;
        chrome: (number[] | null)[];
      };
      // The first frame the bundle sees is the copy: the hat, the mode pill, the ring, the model pill and
      // the field, all there; the transcript's rows, placed for 800 px, draw nothing.
      expect(atBundle.shown).toBe(true);
      expect(atBundle.chromeOnly).toBe(true);
      expect(atBundle.rowVisible).toBe("hidden");
      for (const rect of atBundle.chrome) expect(rect).not.toBeNull();
      expect(await page.evaluate(() => (window as any).__cmuxChatSnapshotShown.chromeOnly)).toBe(true);
      // The live composer, drawn under it at this size, sits exactly where the copy drew it.
      const afterSwap = (await page.evaluate(() => (window as any).chromeAfterSwap)) as number[][];
      expect(afterSwap).toEqual(atBundle.chrome as number[][]);
      // Every painted frame through the swap: the copy, then the live page, with the composer's chrome at
      // the same rects.
      const frames = (await page.evaluate(() => (window as any).frames)) as {
        host: boolean;
        opacity: string;
        chrome: number[][];
      }[];
      expect(frames[0]!.host).toBe(true);
      expect(frames.some((frame) => !frame.host)).toBe(true);
      for (const frame of frames) {
        expect(frame.host ? frame.opacity === "0" : frame.opacity === "").toBe(true);
        expect(frame.chrome).toEqual(afterSwap);
      }
      // The browser's own layout-shift entries on the live page from its first frame through the swap.
      const shifts = (await page.evaluate(() => (window as any).shifts)) as { value: number }[];
      console.log(
        `composer-restart-skeleton ${width}x${height}: layout shifts ${shifts.length}, score ${shifts.reduce((sum, shift) => sum + shift.value, 0)}`,
      );
      expect(shifts).toEqual([]);
      await context.close();
      await other.close();
    });

  test("a copy written at the same size draws its rows (not chrome only)", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot);
    const atBundle = (await page.evaluate(() => (window as any).atBundle)) as Record<string, unknown>;
    expect(atBundle.chromeOnly).toBe(false);
    expect(atBundle.rowVisible).toBe("visible");
    await context.close();
  });

  test("a copy the host answers after the bundle started still draws before the page, and shows the page", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { holdUntil: "bundle" });
    const atBundle = (await page.evaluate(() => (window as any).atBundle)) as Record<string, unknown>;
    expect(atBundle.shown).toBe(true);
    expect(atBundle.row).toEqual(before.row);
    // The host hears it when the copy draws, not when the bundle starts.
    const reports = (await page.evaluate(() => (window as any).reports)) as unknown[];
    expect(reports).toEqual([{ method: "pane.painted", params: { drewKeptTail: true, copy: true }, shown: true }]);
    await context.close();
  });

  test("a copy the host answers after the page drew the chat draws nothing", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { holdUntil: "drawn", drawFirst: true });
    expect(await page.evaluate(() => (window as any).__cmuxChatSnapshotMiss)).toBe(
      "late: the page drew the chat first",
    );
    expect(await page.evaluate(() => !!document.querySelector("cmux-chat-snapshot"))).toBe(false);
    expect(await page.evaluate(() => document.getElementById("root")!.style.opacity)).toBe("");
    expect(await page.evaluate(() => (window as any).reports)).toEqual([]);
    await context.close();
  });

  test("the page's other sheets are carried only as far as the copy uses them", async () => {
    const context = await newContext(800, 600);
    const page = await context.newPage();
    await page.route("http://chat.test/a.html", (route) =>
      route.fulfill({ contentType: "text/html", body: htmlDocument(`<main id="root">${MARKUP()}</main>`) }),
    );
    await page.goto("http://chat.test/a.html");
    await page.addScriptTag({ content: capture });
    const styles = (await page.evaluate(() => {
      // A chunk's viewer rules, faces for a font the chat uses and one it does not, and keyframes.
      const chunk = document.createElement("style");
      chunk.textContent = [
        ".diff-viewer .hunk { color: red; }",
        "#root .header, .markdown-only { color: blue; }",
        ".composer:not(.hidden) textarea { border: 1px solid; }",
        "a[href$='.pdf'] { color: green; }",
        "@media (min-width: 1px) { .diff-viewer { margin: 1px; } .acpmux-row { margin: 2px; } }",
        "@font-face { font-family: 'Used Face'; src: url(data:font/woff2;base64,AAAA); }",
        "@font-face { font-family: 'Unused Face'; src: url(data:font/woff2;base64,BBBB); }",
        ".header { font-family: 'Used Face'; animation: glow 1s; }",
        "@keyframes glow { to { opacity: 1; } }",
        "@keyframes never { to { opacity: 0; } }",
      ].join("\n");
      document.head.append(chunk);
      return (globalThis as any).captureSnapshot(document, "theme-1").styles as string[];
    })) as string[];
    const text = styles.join("\n");
    expect(text).not.toContain("diff-viewer");
    expect(text).toContain(".markdown-only");
    expect(text).toContain(".composer:not(.hidden) textarea");
    expect(text).toContain(".pdf");
    expect(text).toContain(".acpmux-row { margin: 2px; }");
    expect(text).toContain("Used Face");
    expect(text).not.toContain("Unused Face");
    expect(text).toContain("@keyframes glow");
    expect(text).not.toContain("@keyframes never");
    await context.close();
  });

  test("a copy drawn a tab row taller still draws, laid out at the new height", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage());
    const shorter = await newContext(800, 572);
    const page = await shorter.newPage();
    await relaunched(page, before.snapshot);
    const atBundle = (await page.evaluate(() => (window as any).atBundle)) as Record<string, number[] | boolean>;
    expect(atBundle.shown).toBe(true);
    // The header stays where it was; the composer sits at the new bottom, as the live page's does.
    expect(atBundle.header).toEqual(before.header as number[]);
    expect((atBundle.composer as number[])[1]).toBe((before.composer as number[])[1]! - 28);
    const afterSwap = (await page.evaluate(() => (window as any).afterSwap)) as Record<string, number[]>;
    expect(afterSwap.composer).toEqual(atBundle.composer as number[]);
    expect(afterSwap.header).toEqual(atBundle.header as number[]);
    await context.close();
    await shorter.close();
  });

  test("a live page whose rows do not reach the view's top keeps the copy up until an older page fills it", async () => {
    const context = await newContext(800, 600);
    const before = await written(await context.newPage(), HTML_ATTRIBUTES, undefined, { atEnd: true });
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { atEnd: true, short: true });
    // The page drew the kept tail and asked to take over: its three rows would leave 352 px empty
    // above them where the copy shows rows (Leo, 2026-11-22: "the top half of the chat blanked out
    // for like 10 seconds"), so the copy stays, frame after frame.
    const held = await page.evaluate(
      () =>
        new Promise<boolean[]>((resolve) => {
          const seen: boolean[] = [];
          const look = () => {
            seen.push(!!document.querySelector("cmux-chat-snapshot"));
            // raf-read: reads the DOM the frame will paint (the copy's element), no pixels, as the swap's own frame callback sets it.
            if (seen.length < 10) requestAnimationFrame(look);
            else resolve(seen);
          };
          requestAnimationFrame(look);
        }),
    );
    expect(held.every(Boolean)).toBe(true);
    // The older page lands: the rows fill the view, and the copy goes in that frame, never a frame
    // with both or neither, and no frame of the live page shows the band.
    const frames = await page.evaluate(
      () =>
        new Promise<{ host: boolean; opacity: string; band: number }[]>((resolve) => {
          const w = window as any;
          const root = document.getElementById("root")!;
          const seen: { host: boolean; opacity: string; band: number }[] = [];
          const look = () => {
            const scroller = root.querySelector(".acpmux-scroll")!;
            const top = Math.min(
              ...Array.from(scroller.querySelectorAll(".acpmux-row"), (row) => row.getBoundingClientRect().top),
            );
            seen.push({
              host: !!document.querySelector("cmux-chat-snapshot"),
              opacity: root.style.opacity,
              band: Math.max(0, top - scroller.getBoundingClientRect().top),
            });
            // raf-read: reads the DOM and boxes the frame will paint, no pixels, after the swap's own frame callback.
            if (seen.length < 6) requestAnimationFrame(look);
            else resolve(seen);
          };
          root.innerHTML = w.fullMarkup;
          const scroller = root.querySelector(".acpmux-scroll")!;
          scroller.scrollTop = scroller.scrollHeight - scroller.clientHeight;
          // Read after the page's own frame callback for the change (its observer asks for one at the
          // next microtask): `look` then sees what that frame paints.
          queueMicrotask(() => requestAnimationFrame(look));
        }),
    );
    for (const frame of frames) expect(frame.host ? frame.opacity === "0" : frame.opacity === "").toBe(true);
    expect(frames[0]!.host).toBe(false);
    for (const frame of frames) expect(frame.band).toBe(0);
    await context.close();
  });

  test("a short chat whose copy showed the same room above its rows takes over at once", async () => {
    const context = await newContext(800, 600);
    const writer = await context.newPage();
    await writer.route("http://chat.test/a.html", (route) =>
      route.fulfill({ contentType: "text/html", body: htmlDocument(`<main id="root">${SHORT_MARKUP()}</main>`) }),
    );
    await writer.goto("http://chat.test/a.html");
    await writer.addScriptTag({ content: capture });
    const snapshot = await writer.evaluate(() => (globalThis as any).captureSnapshot(document, "theme-1"));
    expect(snapshot).toBeDefined();
    const page = await context.newPage();
    await relaunched(page, snapshot, "theme-1", { short: true });
    const frames = (await page.evaluate(() => (window as any).frames)) as { host: boolean }[];
    expect(frames[0]!.host).toBe(true);
    expect(frames.findIndex((frame) => !frame.host)).toBe(1);
    await context.close();
  });

  test("a transcript written at its latest row draws there a tab row shorter, as the live page then does", async () => {
    // Leo, 2026-11-16, after a restart: "it layout shifted as it drew". At its saved offset, the copy drew
    // the rows 28 px lower than the live page, which keeps its latest row at the end.
    const context = await newContext(800, 600);
    const before = await written(await context.newPage(), HTML_ATTRIBUTES, undefined, { atEnd: true });
    const shorter = await newContext(800, 572);
    const page = await shorter.newPage();
    await relaunched(page, before.snapshot, "theme-1", { atEnd: true });
    const atBundle = (await page.evaluate(() => (window as any).atBundle)) as Record<string, number[] | boolean>;
    expect(atBundle.shown).toBe(true);
    const afterSwap = (await page.evaluate(() => (window as any).afterSwap)) as Record<string, number[]>;
    expect(atBundle.last).toEqual(afterSwap.last);
    expect(afterSwap.composer).toEqual(atBundle.composer as number[]);
    await context.close();
    await shorter.close();
  });

  test("no field's text is written: a sign-in key in a controlled input, a password, a textarea, in shadow roots too", async () => {
    const context = await newContext(800, 600);
    const page = await context.newPage();
    await page.route("http://chat.test/a.html", (route) =>
      route.fulfill({ contentType: "text/html", body: htmlDocument(`<main id="root">${MARKUP()}</main>`) }),
    );
    await page.goto("http://chat.test/a.html");
    await page.addScriptTag({ content: capture });
    const snapshot = (await page.evaluate(() => {
      const KEY = "sk-ant-api03-SECRETKEY";
      // As React renders `<input value={key}>`: the attribute and the property both carry it.
      const card = document.createElement("form");
      card.className = "cloud-sign-in";
      card.innerHTML =
        `<input type="text" class="key" value="${KEY}"><input type="password" value="${KEY}">` +
        `<input autocomplete="one-time-code" value="${KEY}"><textarea>${KEY}</textarea>` +
        `<input type="checkbox" value="remember" checked><button type="submit">Sign in</button>`;
      (card.querySelector(".key") as HTMLInputElement).value = KEY;
      const host = document.createElement("div");
      const shadow = host.attachShadow({ mode: "open" });
      shadow.innerHTML = `<input value="${KEY}"><textarea>${KEY}</textarea><button onclick="steal()">x</button>`;
      const root = document.getElementById("root")!;
      root.prepend(card, host);
      return (globalThis as any).captureSnapshot(document, "theme-1");
    })) as Record<string, unknown>;
    expect(snapshot).toBeDefined();
    expect(JSON.stringify(snapshot)).not.toContain("SECRETKEY");
    expect(snapshot.html as string).toContain('class="cloud-sign-in"');
    expect(snapshot.html as string).toContain('value="remember"');
    expect(snapshot.html as string).toContain('shadowrootmode="open"');
    expect(snapshot.html as string).not.toContain("onclick");
    await context.close();
  });
});
