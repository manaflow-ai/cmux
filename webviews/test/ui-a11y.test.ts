// The ui wrapper and the migrated pages in real engines (headless Chromium and WebKit, Playwright),
// keyboard only, left to right and right to left, with axe-core at each open state
// (plans/cmux-next/a11y-foundation.md). Harness: test/browser/ui-a11y.html, served by the dev server.
// axe gate: zero WCAG 2.x A and AA violations, except Base UI's focus-guard spans (the plan's one
// waiver: on macOS WebKit they carry role=button for VoiceOver, on Chromium they are focusable and
// aria-hidden); those are counted and reported. axe's best-practice rules (landmarks, `region`)
// judge the whole page, not a widget, and are logged without gating.
//
// The engines come from `playwright install chromium webkit`. Where they are not installed (the
// Linux CI image), the browser cases are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import markdownStrings from "../src/pages/markdown/generated/strings.json";

setDefaultTimeout(120_000);
const webviews = path.resolve(import.meta.dir, "..");
const axeSource = fs.readFileSync(path.join(webviews, "node_modules/axe-core/axe.min.js"), "utf8");
const WAIVER = "[data-base-ui-focus-guard]";
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
    `ui-a11y: skipping ${engines
      .filter((engine) => !installed.includes(engine))
      .map(([name]) => name)
      .join(", ")} (run \`bunx playwright install chromium webkit\`)`,
  );
}

let server: ChildProcess | null = null;
let base = "";

beforeAll(async () => {
  if (installed.length === 0) return;
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

/** What has focus as a screen reader hears it: the element, or the row its activedescendant names. */
function focused(page: Page) {
  return page.evaluate(() => {
    const element = document.activeElement as HTMLElement | null;
    const name = (node: Element | null) => (node?.getAttribute("aria-label") ?? node?.textContent ?? "").trim();
    const id = element?.getAttribute("aria-activedescendant");
    const active = id ? document.getElementById(id) : null;
    return {
      role: element?.getAttribute("role") ?? element?.tagName.toLowerCase() ?? "",
      name: name(element),
      active: active ? name(active) : null,
      activeTitle: active?.getAttribute("title") ?? null,
      activeExists: id ? active !== null : null,
    };
  });
}

const result = (page: Page) => page.evaluate(() => document.getElementById("result")!.textContent);
const visible = (page: Page, selector: string) =>
  page.evaluate(
    (selector) =>
      [...document.querySelectorAll(selector)]
        .filter((node) => node.getClientRects().length > 0 && getComputedStyle(node).visibility !== "hidden")
        .map((node) => (node.textContent ?? "").trim()),
    selector,
  );
const settle = (page: Page, ms = 150) => page.waitForTimeout(ms);
/** The visible hint texts once they equal `want` (hints load on first use, then wait 500 ms). */
async function hints(page: Page, want: string[]) {
  await page
    .waitForFunction(
      (want) =>
        JSON.stringify(
          [...document.querySelectorAll(".ui-tooltip")]
            .filter((node) => node.getClientRects().length > 0)
            .map((node) => (node.textContent ?? "").trim()),
        ) === JSON.stringify(want),
      want,
      { timeout: 4000 },
    )
    .catch(() => {});
  return visible(page, ".ui-tooltip");
}

/** axe violations at this state, the waiver's nodes counted apart. */
async function axe(page: Page, state: string, log: AxeLog) {
  await page.evaluate(axeSource);
  const found = await page.evaluate(async (waiver) => {
    const run = await (
      window as unknown as {
        axe: {
          run(
            context: unknown,
            options: unknown,
          ): Promise<{
            violations: Array<{ id: string; impact: string; tags: string[]; nodes: Array<{ target: string[] }> }>;
          }>;
        };
      }
    ).axe.run(document, {
      resultTypes: ["violations"],
    });
    const gating = (tags: string[]) => tags.some((tag) => /^wcag2\d*a{1,2}$/.test(tag));
    const isWaived = (target: string[]) => {
      const element = document.querySelector(target.join(" "));
      return element?.matches(waiver) ?? false;
    };
    const kept: string[] = [];
    const advisory: string[] = [];
    let waived = 0;
    for (const violation of run.violations) {
      if (!gating(violation.tags)) {
        advisory.push(violation.id);
        continue;
      }
      for (const node of violation.nodes) {
        // The waived guard spans, and a menu whose only offending children are those spans.
        const guardOnly =
          violation.id === "aria-required-children" &&
          document.querySelector(node.target.join(" "))?.querySelector(":scope > " + waiver) !== null;
        if (isWaived(node.target) || guardOnly) waived += 1;
        else kept.push(`${violation.id} (${violation.impact}) ${node.target.join(" ")}`);
      }
    }
    return { kept, waived, advisory: [...new Set(advisory)] };
  }, WAIVER);
  log.push({ state, ...found });
  return found.kept;
}

type AxeLog = Array<{ state: string; kept: string[]; waived: number; advisory: string[] }>;

async function open(browser: Browser, query: string): Promise<Page> {
  const page = await browser.newPage({ reducedMotion: "reduce" });
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  (page as unknown as { errors: string[] }).errors = errors;
  await page.goto(`${base}/test/browser/ui-a11y.html?${query}`);
  await page.waitForSelector("#root *");
  return page;
}

const report: Record<string, { waived: number; states: number; advisory: string[] }> = {};
afterAll(() => {
  if (Object.keys(report).length)
    console.log(`ui-a11y axe (waived focus-guard nodes, advisory rules): ${JSON.stringify(report)}`);
});

for (const [engine, type] of installed) {
  for (const rtl of [false, true]) {
    const tag = `${engine}${rtl ? " rtl" : ""}`;
    const dir = rtl ? "&rtl" : "";
    const inlineEnd = rtl ? "ArrowLeft" : "ArrowRight";
    const inlineStart = rtl ? "ArrowRight" : "ArrowLeft";
    const md = (markdownStrings as Record<string, Record<string, string>>)[rtl ? "ar" : "en"];

    describe(`ui a11y (${tag})`, () => {
      let browser: Browser;
      const log: AxeLog = [];
      beforeAll(async () => {
        browser = await type.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
        report[tag] = {
          waived: log.reduce((sum, entry) => sum + entry.waived, 0),
          states: log.length,
          advisory: [...new Set(log.flatMap((entry) => entry.advisory))],
        };
      });

      test("menu with a submenu: keys, typeahead, Escape per level, focus return, page portal, axe", async () => {
        const page = await open(browser, `case=widgets${dir}`);
        expect(await axe(page, "widgets", log)).toEqual([]);
        await page.keyboard.press("Tab");
        expect((await focused(page)).name).toBe("Source");
        await page.keyboard.press("Enter");
        await settle(page);
        expect(await focused(page)).toMatchObject({ role: "menuitem", name: "Working tree" });
        expect(
          await page.evaluate(() => document.getElementById("page")!.contains(document.querySelector('[role="menu"]'))),
        ).toBe(true);
        expect(await axe(page, "menu", log)).toEqual([]);
        await page.keyboard.press("c");
        await settle(page);
        expect((await focused(page)).name).toStartWith("Committed");
        await page.keyboard.press(inlineEnd);
        await settle(page, 300);
        expect((await focused(page)).name).toBe("HEAD~1");
        expect(await axe(page, "submenu", log)).toEqual([]);
        await page.keyboard.press("Escape");
        await settle(page, 300);
        expect((await focused(page)).name).toStartWith("Committed");
        expect(await visible(page, '[role="menu"]')).toHaveLength(1);
        await page.keyboard.press(inlineEnd);
        await settle(page, 300);
        await page.keyboard.press("ArrowDown");
        await page.keyboard.press("Enter");
        await settle(page, 300);
        expect(await result(page)).toBe("source: HEAD~2");
        expect((await focused(page)).name).toBe("Source");
        expect(await visible(page, '[role="menu"]')).toHaveLength(0);
        expect((page as unknown as { errors: string[] }).errors).toEqual([]);
        await page.close();
      });

      test("toolbar: one Tab stop, arrows follow direction, tooltips on keyboard focus, Escape hides", async () => {
        const page = await open(browser, `case=widgets${dir}`);
        await page.keyboard.press("Tab");
        await page.keyboard.press("Tab");
        await settle(page, 800);
        expect((await focused(page)).name).toBe("Split view");
        expect(await hints(page, ["Split view"])).toEqual(["Split view"]);
        expect(await axe(page, "toolbar tooltip", log)).toEqual([]);
        await page.keyboard.press(inlineEnd);
        await settle(page, 300);
        expect((await focused(page)).name).toBe("Unified view");
        expect(await hints(page, ["Unified view"])).toEqual(["Unified view"]);
        await page.keyboard.press("Escape");
        await settle(page, 300);
        expect(await hints(page, [])).toEqual([]);
        await page.keyboard.press(inlineStart);
        await page.keyboard.press("Enter");
        expect(await result(page)).toBe("tool: Split view");
        await page.keyboard.press("Tab");
        await settle(page);
        // One Tab leaves the toolbar for the recent list.
        expect((await focused(page)).role).toBe("listbox");
        await page.close();
      });

      test("recent list: arrows, End, typeahead and Return", async () => {
        const page = await open(browser, `case=widgets${dir}`);
        for (let index = 0; index < 3; index += 1) await page.keyboard.press("Tab");
        expect(await focused(page)).toMatchObject({ role: "listbox", active: expect.stringContaining("alpha") });
        await page.keyboard.press("End");
        expect((await focused(page)).active).toContain("charlie");
        await page.keyboard.press("Home");
        await page.keyboard.press("b");
        await page.keyboard.press("b");
        expect((await focused(page)).active).toContain("bravo");
        await page.keyboard.press("Enter");
        expect(await result(page)).toBe("open: /Users/me/fun/bravo");
        await page.close();
      });

      test("path picker: combobox, Locations, path mode, drill keys, Cmd-Up, virtualized level, axe", async () => {
        const page = await open(browser, `case=picker${dir}`);
        await page.waitForFunction(() => document.querySelector(".ve-picker-name")?.textContent === "scratch");
        let state = await focused(page);
        expect(state).toMatchObject({ role: "combobox", active: expect.stringContaining("scratch") });
        expect(
          await page.evaluate(() =>
            document.getElementById("page")!.contains(document.querySelector('[role="dialog"]')),
          ),
        ).toBe(true);
        expect(await axe(page, "picker", log)).toEqual([]);
        // Up into Locations (Recent, Home, Desktop, Documents, Downloads), then Return opens Home.
        for (let index = 0; index < 4; index += 1) await page.keyboard.press("ArrowUp");
        state = await focused(page);
        expect(state.activeTitle).toBe("/Users/me");
        await page.keyboard.press("Enter");
        await page.waitForFunction(() => document.querySelector(".ve-crumb[aria-current]")?.textContent === "~");
        // Path mode: type a path, the inline-end arrow enters, Cmd-Up goes back up.
        await page.keyboard.type("~/fu");
        await page.waitForFunction(
          () =>
            [...document.querySelectorAll('[data-row="entry"] .ve-picker-name')].map((n) => n.textContent).join() ===
            "fun/",
        );
        await page.keyboard.press(inlineEnd);
        await page.waitForFunction(
          () => (document.querySelector(".ve-picker-field") as HTMLInputElement).value === "~/fun/",
        );
        await page.waitForFunction(() => document.querySelector(".ve-crumb[aria-current]")?.textContent === "fun");
        expect(await axe(page, "picker path mode", log)).toEqual([]);
        await page.keyboard.press("Meta+ArrowUp");
        await page.waitForFunction(
          () => (document.querySelector(".ve-picker-field") as HTMLInputElement).value === "~/",
        );
        // A big level (2,000 folders, capped at the picker's 300 rows) renders only what is visible
        // plus the highlighted row.
        await page.keyboard.type("big/");
        await page.waitForFunction(() => document.querySelector(".ve-crumb[aria-current]")?.textContent === "big");
        // An empty segment: the first row is "Go to ~/big/"; Return goes there and clears the field.
        await page.keyboard.press("Enter");
        await page.waitForFunction(() => (document.querySelector(".ve-picker-field") as HTMLInputElement).value === "");
        await page.waitForFunction(
          () => document.querySelector('[data-row="entry"] .ve-picker-name')?.textContent === "folder-0000",
        );
        await page.keyboard.press("End");
        await settle(page, 300);
        state = await focused(page);
        expect(state).toMatchObject({ active: "folder-0299", activeExists: true });
        const census = await page.evaluate(() => {
          const id = document.activeElement!.getAttribute("aria-activedescendant")!;
          const row = document.getElementById(id)!;
          return {
            rows: document.querySelectorAll(".ve-picker-row").length,
            posinset: row.getAttribute("aria-posinset"),
            setsize: row.getAttribute("aria-setsize"),
          };
        });
        expect(census.rows).toBeLessThan(120);
        // Locations show only at the start folder, so the run is the level's 300 rows.
        expect(census).toMatchObject({ posinset: "300", setsize: "300" });
        expect(await axe(page, "picker virtualized", log)).toEqual([]);
        await page.keyboard.press("Escape"); // empty query: cancels
        await settle(page);
        expect(await result(page)).toBe("cancel");
        expect((page as unknown as { errors: string[] }).errors).toEqual([]);
        await page.close();
      });

      test("markdown: toolbar keys and tooltips, link popover, hover card on the caret, axe", async () => {
        const page = await open(browser, `case=markdown${dir}`);
        await page.waitForFunction(() => (window as unknown as { __ready?: boolean }).__ready === true);
        expect(await axe(page, "markdown", log)).toEqual([]);
        await page.keyboard.press("Tab");
        await settle(page, 800);
        expect((await focused(page)).name).toBe(md["nav.back"]);
        expect(await hints(page, [md["nav.back"]])).toEqual([md["nav.back"]]);
        await page.keyboard.press(inlineEnd);
        expect((await focused(page)).name).toBe(md["nav.forward"]);
        await page.keyboard.press(inlineEnd);
        await page.keyboard.press(inlineEnd);
        expect((await focused(page)).name).toBe(md["mode.source"]);
        await page.keyboard.press("Enter");
        expect(await result(page)).toBe("mode: source");
        await page.keyboard.press(inlineStart);
        await page.keyboard.press("Space");
        expect(await result(page)).toBe("mode: rich");
        // The link popover (the app's `link` command): focus in the field, inside the page.
        await page.click(".md-doc h2");
        // Select the heading's text (the editor reads the DOM selection).
        await page.evaluate(() => {
          const text = document.querySelector(".md-doc h2")!.firstChild!;
          const range = document.createRange();
          range.setStart(text, 0);
          range.setEnd(text, 3);
          getSelection()!.removeAllRanges();
          getSelection()!.addRange(range);
        });
        await settle(page);
        await page.evaluate(() => (window as unknown as { __openLink(): void }).__openLink());
        await settle(page);
        expect(await focused(page)).toMatchObject({ role: "combobox", name: "Link URL or path" });
        expect(
          await page.evaluate(() =>
            document.getElementById("page")!.contains(document.querySelector(".md-link-popover")),
          ),
        ).toBe(true);
        await page.keyboard.type("#get");
        await page.waitForFunction(() => document.querySelectorAll(".md-link-suggestions li").length === 1);
        expect(await axe(page, "link popover", log)).toEqual([]);
        await page.keyboard.press("ArrowDown");
        expect((await focused(page)).active).toBe("#getting-started");
        await page.keyboard.press("Enter");
        await settle(page);
        expect(await page.evaluate(() => document.querySelector(".md-link-popover"))).toBe(null);
        expect(await page.evaluate(() => (window as unknown as { __snapshot(): string }).__snapshot())).toContain(
          "[API](#getting-started)",
        );
        // Escape cancels and returns focus to the editor.
        await page.evaluate(() => (window as unknown as { __openLink(): void }).__openLink());
        await settle(page);
        await page.keyboard.press("Escape");
        await settle(page);
        expect(await page.evaluate(() => document.querySelector(".md-link-popover"))).toBe(null);
        expect(await page.evaluate(() => document.activeElement?.classList.contains("ProseMirror"))).toBe(true);
        // The hover card shows for the link around the caret, not only under the pointer. (Left to
        // right only: the English sample's caret keys are visual inside a right-to-left page.)
        if (!rtl) {
          await page.click(".md-doc p");
          // The caret at the paragraph start (Home is not line start on macOS WebKit), then arrows.
          await page.evaluate(() => {
            const range = document.createRange();
            range.setStart(document.querySelector(".md-doc p")!.firstChild!, 0);
            range.collapse(true);
            getSelection()!.removeAllRanges();
            getSelection()!.addRange(range);
          });
          await settle(page);
          for (let index = 0; index < 6; index += 1) await page.keyboard.press("ArrowRight");
          await settle(page, 600);
          expect(await visible(page, ".md-link-card .md-link-card-target")).toEqual(["/w/docs/guide.md"]);
          expect(await page.evaluate(() => document.querySelector(".md-link-card")?.getAttribute("role"))).toBe(
            "tooltip",
          );
          expect(await axe(page, "hover card", log)).toEqual([]);
        }
        expect((page as unknown as { errors: string[] }).errors).toEqual([]);
        await page.close();
      });
    });
  }
}
