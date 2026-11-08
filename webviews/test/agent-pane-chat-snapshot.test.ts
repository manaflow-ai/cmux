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
// - a copy written for another viewport draws nothing.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
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
    @media (min-width: 1px) { :root .acpmux-row { padding-left: 4px; } }
  `;
  const MARKUP = () => {
    const rows = Array.from(
      { length: 100 },
      (_, at) => `<article class="acpmux-row" data-row-id="r${at}" style="top:${at * 40}px">row ${at}</article>`,
    ).join("");
    return `<div class="header">Chat title</div><div class="acpmux-scroll"><div class="acpmux-spacer">${rows}</div></div><div class="composer"><div class="prompt" contenteditable="true"></div><textarea></textarea></div>`;
  };
  /// The person's theme.css, which the page adds once the host sends it (paneTheme.ts).
  const USER_CSS = "#root .header { height: 52px; }";
  const HTML_ATTRIBUTES = `data-look="roomy" style="--cmux-surface: rgb(10, 20, 30);"`;
  const htmlDocument = (body: string) =>
    `<!doctype html><html ${HTML_ATTRIBUTES}><head><style id="cmux-pane-styles">${CSS}</style></head><body>${body}</body></html>`;

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
w.atBundle = host && copy ? {
  shown: true,
  header: box(copy.querySelector(".header")),
  row: box(copy.querySelector('[data-row-id="r60"]')),
  composer: box(copy.querySelector(".composer textarea")),
  text: copy.querySelector(".composer .prompt")!.textContent,
  field: (copy.querySelector(".composer textarea") as HTMLTextAreaElement).value,
  scrollTop: copy.querySelector(".acpmux-scroll")!.scrollTop,
  rows: copy.querySelectorAll(".acpmux-row").length,
  headerColor: getComputedStyle(copy.querySelector(".header")!).backgroundColor,
  indent: getComputedStyle(copy.querySelector('[data-row-id="r60"]')!).left,
} : { shown: false };
const root = document.getElementById("root")!;
const user = document.createElement("style");
user.textContent = w.userCss;
document.head.append(user);
root.innerHTML = w.liveMarkup;
document.documentElement.style.setProperty("--agent-indent", "20px");
root.querySelector(".prompt")!.textContent = "draft text";
root.querySelector(".acpmux-scroll")!.scrollTop = 2000;
w.frames = [];
const watch = () => {
  w.frames.push({ host: !!document.querySelector("cmux-chat-snapshot"), opacity: root.style.opacity });
  if (w.frames.length < 6) requestAnimationFrame(watch);
};
requestAnimationFrame(() => {
  // The swap's frame callback is queued before the watch's, so the watch reads what that frame paints.
  swapChatSnapshot();
  watch();
  requestAnimationFrame(() => requestAnimationFrame(() => {
    w.afterSwap = { header: box(root.querySelector(".header")), row: box(root.querySelector('[data-row-id="r60"]')), composer: box(root.querySelector(".composer textarea")) };
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
  async function written(page: Page): Promise<Record<string, unknown>> {
    await page.route("http://chat.test/a.html", (route) =>
      route.fulfill({ contentType: "text/html", body: htmlDocument(`<main id="root">${MARKUP()}</main>`) }),
    );
    await page.goto("http://chat.test/a.html");
    await page.addScriptTag({ content: capture });
    await page.evaluate((css) => ((window as any).userCss = css), USER_CSS);
    return await page.evaluate(() => {
      document.documentElement.style.setProperty("--agent-indent", "20px");
      const user = document.createElement("style");
      user.id = "acpmux-user-theme";
      user.textContent = (window as any).userCss;
      document.head.append(user);
      // The composer's draft is the prompt editor's markup; a field's typed text is never written.
      document.querySelector(".prompt")!.textContent = "draft text";
      document.querySelector("textarea")!.value = "typed in a field";
      document.querySelector(".acpmux-scroll")!.scrollTop = 2000;
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
    });
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
    }: { holdUntil?: "bundle" | "drawn"; drawFirst?: boolean; holdDraw?: boolean } = {},
  ): Promise<void> {
    await page.route("http://chat.test/**", (route) => {
      const url = new URL(route.request().url());
      if (url.pathname === "/b.html")
        return route.fulfill({
          contentType: "text/html",
          body: htmlDocument(
            `<main id="root"></main><script src="/fixture.js"></script><script async src="/__snapshot/chat.js"></script><script src="/chat-snapshot.js"></script><script type="module" src="/pane.js"></script>`,
          ),
        });
      if (url.pathname === "/fixture.js")
        return route.fulfill({
          contentType: "text/javascript",
          body: `self.liveMarkup=${JSON.stringify(MARKUP())};self.userCss=${JSON.stringify(USER_CSS)};self.drawFirst=${drawFirst};self.holdDraw=${holdDraw};`,
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
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
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

  test("a press on the copy ends it and reaches nothing under it", async () => {
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
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

  test("once the live page took over, the first press reaches it", async () => {
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
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
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
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
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
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

  test("a box's checked state is written as it shows, both ways", async () => {
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
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
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-2");
    expect(await page.evaluate(() => (window as any).atBundle.shown)).toBe(false);
    await context.close();
  });

  test("a copy written at another size draws nothing", async () => {
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
    const before = await written(await context.newPage());
    const other = await browser.newContext({ viewport: { width: 700, height: 600 } });
    const page = await other.newPage();
    await relaunched(page, before.snapshot);
    expect(await page.evaluate(() => (window as any).atBundle.shown)).toBe(false);
    expect(await page.evaluate(() => document.getElementById("root")!.style.opacity)).toBe("");
    await context.close();
    await other.close();
  });

  test("a copy the host answers after the bundle started still draws before the page, and shows the page", async () => {
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
    const before = await written(await context.newPage());
    const page = await context.newPage();
    await relaunched(page, before.snapshot, "theme-1", { holdUntil: "bundle" });
    const atBundle = (await page.evaluate(() => (window as any).atBundle)) as Record<string, unknown>;
    expect(atBundle.shown).toBe(true);
    expect(atBundle.row).toEqual(before.row);
    // The host hears it when the copy draws, not when the bundle starts.
    const reports = (await page.evaluate(() => (window as any).reports)) as unknown[];
    expect(reports).toEqual([{ method: "pane.painted", params: { drewKeptTail: true }, shown: true }]);
    await context.close();
  });

  test("a copy the host answers after the page drew the chat draws nothing", async () => {
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
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
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
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
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
    const before = await written(await context.newPage());
    const shorter = await browser.newContext({ viewport: { width: 800, height: 572 } });
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

  test("no field's text is written: a sign-in key in a controlled input, a password, a textarea, in shadow roots too", async () => {
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
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
