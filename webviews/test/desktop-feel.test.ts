// DESKTOP-FEEL (R139) in real engines (headless Chromium and WebKit from Playwright), on the diff
// viewer (test/browser/desktop-feel.html) and the markdown editor (/markdown on the dev server):
// - content selects: a diff line's code, a file bar's path, markdown prose and a code block;
// - chrome does not: the toolbar, the files tree, the markdown toolbar;
// - the filter field and the editor stay usable (the editor stays editable);
// - images, icons and links do not drag; the page does not rubber-band;
// - focus rings show for keyboard focus only;
// - a file drop never navigates the page.
// Page zoom (pinch, smart magnification) is the host's (PageWKWebView, PageDesktopDefaultsTests).
//
// The engines come from `playwright install chromium webkit`. Where they are not installed (the
// Linux CI image), the browser cases are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";

setDefaultTimeout(120_000);
const webviews = path.resolve(import.meta.dir, "..");
const engines: [string, BrowserType][] = [
  ["chromium", chromium],
  ["webkit", webkit],
];
const installed: [string, BrowserType][] = [];
for (const engine of engines) {
  try {
    const browser = await engine[1].launch({ headless: true });
    await browser.close();
    installed.push(engine);
  } catch {
    // Not installed here.
  }
}
if (installed.length < engines.length) {
  console.warn(
    `desktop-feel: skipping ${engines
      .filter((engine) => !installed.includes(engine))
      .map(([name]) => name)
      .join(", ")} (run \`bunx playwright install chromium webkit\`)`,
  );
}

const MARKDOWN = `# Desktop feel

The prose paragraph of the desktop feel fixture.

\`\`\`ts
const fenced = "code block text";
\`\`\`
`;

let server: ChildProcess | null = null;
let base = "";
let markdownFile = "";
let markdownRoot = "";
let readOnlyRoot = "";
let readOnlyFile = "";

beforeAll(async () => {
  if (installed.length === 0) return;
  markdownRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-desktop-feel-")));
  markdownFile = path.join(markdownRoot, "desktop-feel.md");
  fs.writeFileSync(markdownFile, MARKDOWN);
  // Outside the dev server's root, a file opens read only: the editor is not contenteditable, so
  // only `.selectable` keeps its text selectable.
  readOnlyRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "cmux-desktop-feel-ro-")));
  readOnlyFile = path.join(readOnlyRoot, "read-only.md");
  fs.writeFileSync(readOnlyFile, MARKDOWN);
  const port = await new Promise<number>((resolve) => {
    const probe = net.createServer().listen(0, "127.0.0.1", () => {
      const { port } = probe.address() as net.AddressInfo;
      probe.close(() => resolve(port));
    });
  });
  server = spawn(path.join(webviews, "node_modules/.bin/vp"), ["dev", "--port", String(port), "--strictPort"], {
    cwd: webviews,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      CMUX_MARKDOWN_DEV_ROOT: markdownRoot,
      CMUX_MARKDOWN_DEV_FILE: markdownFile,
      CMUX_MARKDOWN_DEV_READONLY_ROOTS: readOnlyRoot,
    },
  });
  base = `http://127.0.0.1:${port}`;
  await new Promise<void>((resolve, reject) => {
    const onData = (chunk: Buffer) => (String(chunk).includes(`${port}`) ? resolve() : undefined);
    server!.stdout!.on("data", onData);
    server!.stderr!.on("data", onData);
    server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
  });
}, 60_000);

afterAll(() => {
  server?.kill();
  for (const root of [markdownRoot, readOnlyRoot]) if (root) fs.rmSync(root, { recursive: true, force: true });
});

/** The selected text, including a selection inside a shadow root (the diff lines). */
function selectedText(): string {
  const roots: (Document | ShadowRoot)[] = [document];
  for (const host of document.querySelectorAll("*")) if (host.shadowRoot) roots.push(host.shadowRoot);
  for (const root of roots) {
    const selection = (root as Document & { getSelection?: () => Selection | null }).getSelection?.();
    const text = selection?.toString() ?? "";
    if (text !== "") return text;
  }
  return "";
}

/**
 * Drags across `rect` as a person selecting text, from `start` (a fraction of its width) to its
 * right edge. A diff line starts a little in: its left edge is the comment button's hover target.
 */
async function dragAcross(page: Page, rect: { x: number; y: number; width: number; height: number }, start = 0) {
  await page.evaluate(() => document.getSelection()?.removeAllRanges());
  const y = rect.y + rect.height / 2;
  await page.mouse.move(rect.x + Math.max(2, rect.width * start), y);
  await page.mouse.down();
  await page.mouse.move(rect.x + rect.width / 2, y, { steps: 5 });
  await page.mouse.move(rect.x + rect.width - 2, y, { steps: 5 });
  await page.mouse.up();
  return page.evaluate(selectedText);
}

async function rectOf(page: Page, find: () => Element | Range | null | undefined) {
  for (let tries = 0; tries < 100; tries += 1) {
    const handle = await page.evaluateHandle(find);
    const rect = await handle.evaluate((target) => {
      const box = target?.getBoundingClientRect();
      return box && box.width > 0 ? { x: box.x, y: box.y, width: box.width, height: box.height } : null;
    });
    await handle.dispose();
    if (rect) return rect;
    await page.waitForTimeout(100);
  }
  throw new Error(`nothing laid out for ${find.toString()}`);
}

/** A file drop on the page: whether the layer refused it and the page stayed where it was. */
async function dropFile(page: Page) {
  return page.evaluate(() => {
    const before = location.href;
    const data = new DataTransfer();
    data.items.add(new File(["dropped"], "dropped.txt", { type: "text/plain" }));
    const over = new DragEvent("dragover", { bubbles: true, cancelable: true, dataTransfer: data });
    document.body.dispatchEvent(over);
    const drop = new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: data });
    document.body.dispatchEvent(drop);
    return { overRefused: over.defaultPrevented, dropRefused: drop.defaultPrevented, same: location.href === before };
  });
}

for (const [name, engine] of installed) {
  describe(`desktop feel (${name})`, () => {
    let browser: Browser;
    let page: Page;

    beforeAll(async () => {
      browser = await engine.launch({ headless: true });
    });

    afterAll(async () => {
      await browser?.close();
    });

    test("diff viewer: lines and paths select, chrome does not", async () => {
      page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
      await page.goto(`${base}/test/browser/desktop-feel.html`);
      await page.waitForFunction(() =>
        Array.from(document.querySelectorAll("diffs-container")).some((host) =>
          host.shadowRoot?.querySelector("[data-line][data-line-type='change-addition']"),
        ),
      );
      expect(await page.evaluate(() => document.documentElement.hasAttribute("data-cmux-desktop"))).toBe(true);

      // The word `value_N` of the first added line, from a range over its text.
      const word = await rectOf(page, () => {
        for (const host of document.querySelectorAll("diffs-container")) {
          const line = host.shadowRoot?.querySelector("[data-line][data-line-type='change-addition']");
          const walker = line && document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
          for (let node = walker?.nextNode(); node; node = walker!.nextNode()) {
            const at = node.textContent!.indexOf("value_");
            if (at < 0) continue;
            const range = document.createRange();
            range.setStart(node, at);
            range.setEnd(node, at + "value_".length);
            return range;
          }
        }
        return null;
      });
      // A double-click selects the word. A drag does too in WebKit; headless Chromium never extends
      // a drag selection inside Pierre's shadow root, with or without this layer.
      await page.evaluate(() => document.getSelection()?.removeAllRanges());
      await page.mouse.dblclick(word.x + word.width / 2, word.y + word.height / 2);
      expect(await page.evaluate(selectedText)).toContain("value_");
      if (name === "webkit") expect(await dragAcross(page, word)).toContain("value");

      const filePath = await rectOf(page, () => document.querySelector(".file-header-path .file-header-name"));
      expect(await dragAcross(page, filePath)).toContain(".ts");

      const toolbar = await rectOf(page, () => document.querySelector("#toolbar"));
      expect(await dragAcross(page, toolbar)).toBe("");

      const styles = await page.evaluate(() => {
        const select = (element: Element | null) =>
          element ? getComputedStyle(element).webkitUserSelect || getComputedStyle(element).userSelect : null;
        const drag = (selector: string) =>
          Array.from(document.querySelectorAll(selector)).map(
            (element) => getComputedStyle(element).getPropertyValue("-webkit-user-drag") || "none",
          );
        return {
          toolbar: select(document.querySelector("#toolbar")),
          sidebar: select(document.querySelector("#files-sidebar")),
          header: select(document.querySelector(".file-header")),
          path: select(document.querySelector(".file-header-path")),
          filter: select(document.querySelector("#file-filter-input")),
          dragsOK: [...drag("img"), ...drag("svg"), ...drag("a")].every((value) => value === "none"),
          overscroll: [document.documentElement, document.body].map(
            (element) => getComputedStyle(element).overscrollBehaviorY,
          ),
        };
      });
      expect(styles).toEqual({
        toolbar: "none",
        sidebar: "none",
        header: "none",
        path: "text",
        filter: "text",
        dragsOK: true,
        overscroll: ["none", "none"],
      });
      expect(await dropFile(page)).toEqual({ overRefused: true, dropRefused: true, same: true });
    });

    test("diff viewer: focus rings show for keyboard focus only", async () => {
      // A file bar is a focusable control (it toggles the file); a pointer click gives it no ring.
      const bar = await rectOf(page, () => document.querySelector(".file-header-caret"));
      await page.mouse.click(bar.x + bar.width / 2, bar.y + bar.height / 2);
      const pointer = await page.evaluate(() => {
        const focused = document.activeElement as HTMLElement;
        return { visible: focused.matches(":focus-visible"), outline: getComputedStyle(focused).outlineStyle };
      });
      await page.keyboard.press("Tab");
      const keyboard = await page.evaluate(() => (document.activeElement as HTMLElement).matches(":focus-visible"));
      expect({ pointerRing: pointer.visible || pointer.outline !== "none", keyboardRing: keyboard }).toEqual({
        pointerRing: false,
        keyboardRing: true,
      });
      await page.close();
    });

    test("markdown editor: the document and code blocks select and edit, the toolbar does not", async () => {
      page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
      await page.goto(`${base}/markdown?file=${encodeURIComponent(markdownFile)}`);
      await page.waitForSelector(".md-doc .ProseMirror p");
      expect(await page.evaluate(() => document.documentElement.hasAttribute("data-cmux-desktop"))).toBe(true);

      const prose = await rectOf(page, () =>
        Array.from(document.querySelectorAll(".md-doc .ProseMirror p")).find((p) => p.textContent?.includes("prose")),
      );
      expect(await dragAcross(page, prose)).toContain("prose");

      const code = await rectOf(page, () =>
        Array.from(document.querySelectorAll(".md-doc pre, .md-doc code")).find((element) =>
          element.textContent?.includes("code block text"),
        ),
      );
      expect(await dragAcross(page, code)).toContain("fenced");

      const fileName = await rectOf(page, () => document.querySelector(".md-toolbar .md-file"));
      expect(await dragAcross(page, fileName)).toBe("");

      expect(
        await page.evaluate(() => ({
          editable: (document.querySelector(".md-doc .ProseMirror") as HTMLElement).isContentEditable,
          toolbar: getComputedStyle(document.querySelector(".md-toolbar")!).webkitUserSelect,
          overscroll: getComputedStyle(document.documentElement).overscrollBehaviorY,
        })),
      ).toEqual({ editable: true, toolbar: "none", overscroll: "none" });
      expect(await dropFile(page)).toEqual({ overRefused: true, dropRefused: true, same: true });
      await page.close();
    });

    test("markdown editor, read only: the document still selects, the page around it does not", async () => {
      page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
      await page.goto(`${base}/markdown?file=${encodeURIComponent(readOnlyFile)}`);
      await page.waitForSelector(".md-page[data-read-only='true'] .md-doc .ProseMirror p");
      const prose = await rectOf(page, () =>
        Array.from(document.querySelectorAll(".md-doc .ProseMirror p")).find((p) => p.textContent?.includes("prose")),
      );
      expect(await dragAcross(page, prose)).toContain("prose");
      const note = await rectOf(page, () => document.querySelector(".md-note"));
      expect(await dragAcross(page, note)).toBe("");
      expect(
        await page.evaluate(() => ({
          editable: (document.querySelector(".md-doc .ProseMirror") as HTMLElement).isContentEditable,
          body: getComputedStyle(document.body).webkitUserSelect,
        })),
      ).toEqual({ editable: false, body: "none" });
      await page.close();
    });
  });
}
