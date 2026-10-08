// The real diff viewer in real engines (headless Chromium and WebKit from
// Playwright), over a 2,000-file patch with two 20,000-line files
// (test/browser/diff-virtualization.html, served by the webviews dev server):
// - @pierre/diffs CodeView keeps the mounted files and line rows bounded by
//   the viewport wherever the viewer is scrolled;
// - jump-to-file lands an unmounted file's header at the top;
// - collapsing a file from its stuck header keeps that header at the top;
// - the header bar toggles on a click anywhere, not on its controls and not
//   after a drag-select, and from the keyboard;
// - a file row click in the files tree expands (and scrolls to) a collapsed
//   file, collapses a file whose header is in place, and otherwise scrolls
//   only, sharing the header bar's collapsed state.
//
// The engines come from `playwright install chromium webkit`. Where they are
// not installed (the Linux CI image), the browser cases are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("diff-virtualization.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  // An engine counts as installed when it launches.
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
      `diff-virtualization: skipping ${engines
        .filter((engine) => !installed.includes(engine))
        .map(([name]) => name)
        .join(", ")} (run \`bunx playwright install chromium webkit\`)`,
    );
  }

  const VIEWPORT = { width: 1200, height: 800 };
  // CodeView renders the viewport plus its 200px overscroll on each side.
  const OVERSCROLL = 200;
  const LINE_HEIGHT = 20;
  // Twice the ideal window leaves room for hunk batching across the mounted files.
  const MAX_ROWS = Math.ceil((VIEWPORT.height + OVERSCROLL * 2) / LINE_HEIGHT) * 2;
  const MAX_FILES = 16;

  let server: ChildProcess | null = null;
  let base = "";

  beforeAll(async () => {
    if (installed.length === 0) {
      return;
    }
    const port = await new Promise<number>((resolve) => {
      const probe = net.createServer().listen(0, "127.0.0.1", () => {
        const { port } = probe.address() as net.AddressInfo;
        probe.close(() => resolve(port));
      });
    });
    server = spawn(path.join(webviews, "node_modules/.bin/vp"), ["dev", "--port", String(port), "--strictPort"], {
      cwd: webviews,
      stdio: ["ignore", "pipe", "pipe"],
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
  });

  /** Mounted files and line rows, and how many of them lie outside the viewer. */
  function census() {
    let files = 0;
    let rows = 0;
    let nodes = 0;
    const count = (root: Document | ShadowRoot) => {
      for (const element of root.querySelectorAll("*")) {
        nodes += 1;
        if (element.shadowRoot) {
          count(element.shadowRoot);
        }
      }
    };
    count(document);
    for (const host of document.querySelectorAll("#viewer diffs-container")) {
      files += 1;
      rows += host.shadowRoot!.querySelectorAll("[data-line-index][data-line-type]:not([data-column-number])").length;
    }
    return { files, rows, nodes };
  }

  /** The named file's header relative to the viewer top, once it is laid out. */
  async function headerOffset(page: Page, name: string) {
    const find = (name: string) => {
      const viewer = document.querySelector(".code-view-root")!.getBoundingClientRect();
      const header = Array.from(document.querySelectorAll(".file-header")).find(
        (element) => element.querySelector(".file-header-name")?.textContent === name,
      );
      const rect = header?.getBoundingClientRect();
      if (header == null || rect == null || rect.height === 0) {
        return null;
      }
      return { offset: Math.round(rect.top - viewer.top), expanded: header.getAttribute("aria-expanded") };
    };
    // A file mounted by a jump, or laid out again after a collapse, renders its
    // header slot a few frames later.
    for (let tries = 0; tries < 50; tries += 1) {
      const found = await page.evaluate(find, name);
      if (found != null) {
        return found;
      }
      await page.waitForTimeout(100);
    }
    return null;
  }

  /** The center of `selector` inside the named file's header. */
  async function pointIn(page: Page, name: string, selector: string) {
    await headerOffset(page, name);
    const point = await page.evaluate(
      ([name, selector]) => {
        const header = Array.from(document.querySelectorAll(".file-header")).find(
          (element) => element.querySelector(".file-header-name")?.textContent === name,
        );
        const rect = header?.querySelector(selector)?.getBoundingClientRect();
        return rect == null
          ? null
          : { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, left: rect.x, right: rect.right };
      },
      [name, selector],
    );
    if (point == null) {
      throw new Error(`no ${selector} in the ${name} header`);
    }
    return point;
  }

  // CodeView turns pointer events off while it scrolls and back on 120 ms later.
  const POINTER_SETTLE_MS = 150;

  async function clickIn(page: Page, name: string, selector: string) {
    const point = await pointIn(page, name, selector);
    await page.waitForTimeout(POINTER_SETTLE_MS);
    await page.mouse.click(point.x, point.y);
    await page.waitForTimeout(300);
  }

  /** Clicks the files tree row of `name`, scrolling the tree's own list to it first. */
  async function clickTreeRow(page: Page, name: string, approximateRow: number) {
    for (let attempt = 0; attempt < 60; attempt += 1) {
      const point = await page.evaluate(
        ([name, approximateRow]) => {
          const all = (root: Document | ShadowRoot, out: Element[] = []) => {
            for (const element of root.querySelectorAll("*")) {
              out.push(element);
              if (element.shadowRoot) {
                all(element.shadowRoot, out);
              }
            }
            return out;
          };
          const elements = all(document);
          const row = elements.find(
            (element) =>
              element.getAttribute("data-type") === "item" &&
              element.getAttribute("data-item-path")?.endsWith(`/${name}`),
          );
          const rect = row?.getBoundingClientRect();
          if (rect != null && rect.height > 0 && rect.top > 140 && rect.bottom < innerHeight - 20) {
            return { x: rect.x + 40, y: rect.y + rect.height / 2 };
          }
          const list = elements.find((element) => element.getAttribute("data-file-tree-virtualized-scroll") === "true");
          if (list != null) {
            list.scrollTop = Math.max(0, Number(approximateRow) * 29 - 300);
          }
          return null;
        },
        [name, approximateRow] as const,
      );
      if (point != null) {
        await page.waitForTimeout(POINTER_SETTLE_MS);
        await page.mouse.click(point.x, point.y);
        await page.waitForTimeout(900);
        return;
      }
      await page.waitForTimeout(100);
    }
    throw new Error(`no tree row for ${name}`);
  }

  /** Jump to a file through the toolbar's jump-to-file palette. */
  async function jumpToFile(page: Page, name: string) {
    await page.click("button[aria-label='Jump to file']");
    await page.fill("input.jump-palette-input", name);
    await page.keyboard.press("Enter");
  }

  async function scrollViewer(page: Page, top: number) {
    await page.evaluate((top) => {
      document.querySelector(".code-view-root")!.scrollTop = top;
    }, top);
    // CodeView renders the new window on the next frame and reconciles
    // measured heights on the one after.
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    await page.waitForTimeout(200);
  }

  /** Pierre's CodeView instance (it publishes itself as `window.__INSTANCE`). */
  function topOf(page: Page, id: string) {
    return page.evaluate((id) => (window as any).__INSTANCE.getTopForItem(id) as number, id);
  }

  for (const [name, type] of engines) {
    describe.skipIf(!installed.some(([candidate]) => candidate === name))(`diff viewer in ${name}`, () => {
      let browser: Browser;
      let page: Page;

      beforeAll(async () => {
        browser = await type.launch({ headless: true });
        page = await browser.newPage({ viewport: VIEWPORT });
        const ready = () =>
          page.waitForFunction(() => document.getElementById("files-sidebar")?.dataset.fileCount === "2000", null, {
            timeout: 60_000,
          });
        // A fresh dev server optimizes dependencies on the first load and then
        // reloads the page once; load twice so the cases run on a settled page.
        await page.goto(`${base}/test/browser/diff-virtualization.html`);
        await ready();
        await page.waitForLoadState("networkidle");
        await page.goto(`${base}/test/browser/diff-virtualization.html`);
        await ready();
        await page.waitForTimeout(500);
      });

      afterAll(async () => {
        await browser?.close();
      });

      test("mounted files and line rows stay bounded by the viewport anywhere in the diff", async () => {
        const scrollHeight = await page.evaluate(() => document.querySelector(".code-view-root")!.scrollHeight);
        // 2,000 files are far taller than the viewport (each small file is ~600px).
        expect(scrollHeight).toBeGreaterThan(1_000_000);
        for (const fraction of [0, 0.0005, 0.25, 0.5, 0.9, 1]) {
          await scrollViewer(page, Math.round(scrollHeight * fraction));
          const mounted = await page.evaluate(census);
          expect(mounted.files).toBeGreaterThan(0);
          expect(mounted.files).toBeLessThanOrEqual(MAX_FILES);
          expect(mounted.rows).toBeLessThanOrEqual(MAX_ROWS);
          // The tree is virtualized too: the whole page stays in the low thousands.
          expect(mounted.nodes).toBeLessThan(12_000);
        }
      });

      test("jump-to-file lands an unmounted file's header at the top of the viewer", async () => {
        await scrollViewer(page, 0);
        expect(await page.evaluate(() => document.querySelector("#viewer")!.textContent?.includes("file1500.ts"))).toBe(
          false,
        );
        await jumpToFile(page, "file1500.ts");
        await page.waitForTimeout(1200);
        expect((await headerOffset(page, "file1500.ts"))?.offset).toBe(0);
        expect((await page.evaluate(census)).files).toBeLessThanOrEqual(MAX_FILES);
      });

      test("collapsing a file from its stuck header keeps that header at the top", async () => {
        await scrollViewer(page, 0);
        await clickIn(page, "huge1.ts", ".file-review-load");
        expect((await headerOffset(page, "huge1.ts"))?.expanded).toBe("true");
        // Deep inside the 20,000-line file: its header is stuck and few rows are mounted.
        const huge1Top = await topOf(page, "big/huge1.ts");
        await scrollViewer(page, huge1Top + 40_000);
        expect((await page.evaluate(census)).rows).toBeLessThanOrEqual(MAX_ROWS);
        expect(await headerOffset(page, "huge1.ts")).toEqual({ offset: 0, expanded: "true" });

        await clickIn(page, "huge1.ts", ".file-header-stats");
        expect(await headerOffset(page, "huge1.ts")).toEqual({ offset: 0, expanded: "false" });
        expect(Math.round(await page.evaluate(() => document.querySelector(".code-view-root")!.scrollTop))).toBe(
          Math.round(huge1Top),
        );

        // Expanding it again from the bar restores the file in place.
        await clickIn(page, "huge1.ts", ".file-header-spacer");
        expect(await headerOffset(page, "huge1.ts")).toEqual({ offset: 0, expanded: "true" });
      });

      test("the header bar toggles on a click anywhere, not after a drag-select or on its controls", async () => {
        await scrollViewer(page, await topOf(page, "src/mod00/file0001.ts"));
        expect((await headerOffset(page, "file0001.ts"))?.expanded).toBe("true");

        // Drag across the file name: the path is selected and the file stays open.
        const name = await pointIn(page, "file0001.ts", ".file-header-name");
        await page.waitForTimeout(POINTER_SETTLE_MS);
        await page.mouse.move(name.left + 1, name.y);
        await page.mouse.down();
        await page.mouse.move(name.right - 1, name.y, { steps: 8 });
        await page.mouse.up();
        await page.waitForTimeout(200);
        expect((await page.evaluate(() => window.getSelection()?.toString() ?? "")).trim()).not.toBe("");
        expect((await headerOffset(page, "file0001.ts"))?.expanded).toBe("true");

        // A plain click on the name toggles, even with that selection still there.
        await clickIn(page, "file0001.ts", ".file-header-name");
        expect((await headerOffset(page, "file0001.ts"))?.expanded).toBe("false");
        await clickIn(page, "file0001.ts", ".file-header-additions");
        expect((await headerOffset(page, "file0001.ts"))?.expanded).toBe("true");

        // The Viewed control keeps its own action (marking viewed collapses the file).
        await clickIn(page, "file0001.ts", ".file-review-viewed");
        expect(
          await page.evaluate(() =>
            Array.from(document.querySelectorAll(".file-header"))
              .find((element) => element.querySelector(".file-header-name")?.textContent === "file0001.ts")
              ?.querySelector(".file-review-viewed")
              ?.getAttribute("aria-pressed"),
          ),
        ).toBe("true");
        expect((await headerOffset(page, "file0001.ts"))?.expanded).toBe("false");
        await clickIn(page, "file0001.ts", ".file-review-viewed");

        // Keyboard: the bar is one focusable toggle.
        await page.evaluate(() =>
          Array.from(document.querySelectorAll<HTMLElement>(".file-header"))
            .find((element) => element.querySelector(".file-header-name")?.textContent === "file0001.ts")
            ?.focus(),
        );
        const before = (await headerOffset(page, "file0001.ts"))?.expanded;
        await page.keyboard.press("Enter");
        expect((await headerOffset(page, "file0001.ts"))?.expanded).not.toBe(before);
        await page.keyboard.press("Space");
        expect((await headerOffset(page, "file0001.ts"))?.expanded).toBe(before);
      });

      test("a file row in the tree expands, collapses in place, or scrolls, like its header bar", async () => {
        // Collapse an unmounted file from its bar, then go back to the top.
        await jumpToFile(page, "file1700.ts");
        await page.waitForTimeout(1200);
        await clickIn(page, "file1700.ts", ".file-header-spacer");
        expect((await headerOffset(page, "file1700.ts"))?.expanded).toBe("false");
        await scrollViewer(page, 0);
        expect(await page.evaluate(() => document.querySelector("#viewer")!.textContent?.includes("file1700.ts"))).toBe(
          false,
        );

        // Collapsed (and unmounted): the tree row expands it and scrolls it to the top.
        const row = 1700 + 2 + 2 + 17;
        await clickTreeRow(page, "file1700.ts", row);
        expect(await headerOffset(page, "file1700.ts")).toEqual({ offset: 0, expanded: "true" });
        await page.waitForTimeout(500);
        // No jump once the expanded height is measured.
        expect(await headerOffset(page, "file1700.ts")).toEqual({ offset: 0, expanded: "true" });

        // Expanded and in place: the tree row collapses it and the bar stays put.
        await clickTreeRow(page, "file1700.ts", row);
        expect(await headerOffset(page, "file1700.ts")).toEqual({ offset: 0, expanded: "false" });
        // The bar and the tree share the state: the bar expands it again.
        await clickIn(page, "file1700.ts", ".file-header-spacer");
        expect(await headerOffset(page, "file1700.ts")).toEqual({ offset: 0, expanded: "true" });

        // Expanded but elsewhere: the tree row scrolls to it only.
        await clickTreeRow(page, "file1690.ts", row - 10);
        expect(await headerOffset(page, "file1690.ts")).toEqual({ offset: 0, expanded: "true" });

        // The tree selection follows the file in view.
        await scrollViewer(page, await topOf(page, "src/mod03/file0300.ts"));
        await page.waitForTimeout(400);
        expect(
          await page.evaluate(() => {
            const find = (root: Document | ShadowRoot): string | null => {
              for (const element of root.querySelectorAll("*")) {
                if (element.hasAttribute("data-item-selected")) {
                  return element.getAttribute("data-item-path");
                }
                if (element.shadowRoot) {
                  const found = find(element.shadowRoot);
                  if (found != null) {
                    return found;
                  }
                }
              }
              return null;
            };
            return find(document);
          }),
        ).toBe("src/mod03/file0300.ts");
      });
    });
  }
});
