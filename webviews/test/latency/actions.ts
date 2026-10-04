// The named actions the latency harness measures, per page. Each action's predicate is the
// VISIBLE response to the input (what the user sees change), not a later result: a source switch
// responds when the source control shows the new source, not when the new diff has loaded.
import type { Page } from "playwright";
import type { LatencyAction, LatencyPageSpec } from "./measure";

const settle = (ms: number) => async (page: Page) => {
  await page.waitForTimeout(ms);
};

/** In-page helpers the predicates use (installed by `prepare`). */
const HELPERS = `(() => {
  const w = window;
  if (w.__lh) return;
  w.__lh = {
    tree() { return document.querySelector("file-tree-container")?.shadowRoot ?? null; },
    treeRow(path) { return w.__lh.tree()?.querySelector('[data-item-path="' + path + '"]') ?? null; },
    header(name) {
      return Array.from(document.querySelectorAll(".file-header")).find(
        (h) => h.querySelector(".file-header-name")?.textContent === name) ?? null;
    },
    diffTypes() {
      return Array.from(document.querySelectorAll("#viewer diffs-container"))
        .map((h) => h.shadowRoot?.querySelector("pre[data-diff-type]")?.getAttribute("data-diff-type"))
        .filter(Boolean);
    },
    overflows() {
      return Array.from(document.querySelectorAll("#viewer diffs-container"))
        .map((h) => h.shadowRoot?.querySelector("pre[data-overflow]")?.getAttribute("data-overflow"))
        .filter(Boolean);
    },
    headerAtTop(name) {
      const h = w.__lh.header(name);
      const root = document.querySelector(".code-view-root");
      if (!h || !root) return false;
      return Math.abs(h.getBoundingClientRect().top - root.getBoundingClientRect().top) < 48;
    },
  };
})()`;

async function helpers(page: Page): Promise<void> {
  await page.evaluate(HELPERS);
}

async function attr(page: Page, selector: string, name: string): Promise<string | null> {
  return page.evaluate(([s, n]) => document.querySelector(s)?.getAttribute(n) ?? null, [selector, name] as const);
}

const js = JSON.stringify;

/** What the next `input` acts on, chosen by `prepare`. */
const targets = new WeakMap<Page, string>();
const targetOf = (page: Page) => targets.get(page) ?? "";

// The diff viewer: test/latency/diff.html (240 files, host delay 40 ms).
const diffActions: LatencyAction[] = [
  {
    name: "source switch",
    async prepare(page) {
      await helpers(page);
      const label = await page.evaluate(() => document.querySelector(".source-pill-label")?.textContent ?? "");
      const target = label === "Unstaged" ? "branch" : "unstaged";
      await page.click("#source-menu-button");
      await page.waitForSelector(`[data-source-id="${target}"]`);
      targets.set(page, target);
      const expected = target === "branch" ? "Branch" : "Unstaged";
      return `document.querySelector(".source-pill-label")?.textContent === ${js(expected)}`;
    },
    async input(page) {
      const target = targetOf(page);
      await page.click(`[data-source-id="${target}"]`);
    },
    // A new session streams a new patch; let it finish before the next run.
    settle: settle(900),
  },
  {
    name: "branch change",
    async prepare(page) {
      await helpers(page);
      if ((await page.$("#base-picker-button")) == null) {
        // The previous action left the page on a working-tree source; go back to Branch.
        await page.click("#source-menu-button");
        await page.click('[data-source-id="branch"]');
        await page.waitForSelector("#base-picker-button");
        await page.waitForTimeout(900);
      }
      const current = await page.evaluate(() => document.querySelector(".base-picker-ref")?.textContent ?? "");
      const target = current === "origin/main" ? "feat-cmux-next" : "origin/main";
      await page.click("#base-picker-button");
      await page.waitForSelector(".base-picker-row");
      targets.set(page, target);
      return `document.querySelector(".base-picker-ref")?.textContent === ${js(target)}`;
    },
    async input(page) {
      const target = targetOf(page);
      await page.click(`.base-picker-row:has(.base-picker-row-primary:text-is("${target}"))`);
    },
    settle: settle(900),
  },
  {
    name: "toggle file",
    async prepare(page) {
      await helpers(page);
      await page.waitForSelector(".file-header");
      const collapsed = await page.evaluate(() =>
        document.querySelector(".file-header")!.getAttribute("data-collapsed"),
      );
      const name = await page.evaluate(() => document.querySelector(".file-header .file-header-name")!.textContent!);
      targets.set(page, name);
      return `window.__lh.header(${js(name)})?.getAttribute("data-collapsed") === ${js(collapsed === "true" ? "false" : "true")}`;
    },
    async input(page) {
      const name = targetOf(page);
      await page.click(`.file-header:has(.file-header-name:text-is("${name}")) .file-header-stats`);
    },
    settle: settle(150),
  },
  {
    name: "toggle viewed",
    async prepare(page) {
      await helpers(page);
      const name = await page.evaluate(() => document.querySelector(".file-header .file-header-name")!.textContent!);
      const pressed = await page.evaluate(
        (n) =>
          Array.from(document.querySelectorAll(".file-header"))
            .find((h) => h.querySelector(".file-header-name")?.textContent === n)
            ?.querySelector(".file-review-viewed")
            ?.getAttribute("aria-pressed") ?? "false",
        name,
      );
      targets.set(page, name);
      return `window.__lh.header(${js(name)})?.querySelector(".file-review-viewed")?.getAttribute("aria-pressed") === ${js(pressed === "true" ? "false" : "true")}`;
    },
    async input(page) {
      const name = targetOf(page);
      await page.click(`.file-header:has(.file-header-name:text-is("${name}")) .file-review-viewed`);
    },
    settle: settle(150),
  },
  {
    name: "sidebar toggle",
    async prepare(page) {
      const hidden = await page.evaluate(() => document.body.dataset.filesHidden);
      return `document.body.dataset.filesHidden === ${js(hidden === "true" ? "false" : "true")}`;
    },
    async input(page) {
      await page.click("#files-toggle");
    },
    settle: settle(350),
  },
  {
    name: "layout toggle",
    async prepare(page) {
      await helpers(page);
      const types = (await page.evaluate("window.__lh.diffTypes()")) as string[];
      const target = types[0] === "split" ? "single" : "split";
      return `(() => { const t = window.__lh.diffTypes(); return t.length > 0 && t.every((x) => x === ${js(target)}); })()`;
    },
    async input(page) {
      await page.click("#layout-toggle");
    },
    settle: settle(250),
  },
  {
    name: "word-wrap toggle",
    async prepare(page) {
      await helpers(page);
      const values = (await page.evaluate("window.__lh.overflows()")) as string[];
      const target = values[0] === "wrap" ? "scroll" : "wrap";
      return `(() => { const t = window.__lh.overflows(); return t.length > 0 && t.every((x) => x === ${js(target)}); })()`;
    },
    async input(page) {
      await page.click("#wrap-toggle");
    },
    settle: settle(250),
  },
  {
    name: "jump to file",
    async prepare(page) {
      await helpers(page);
      await page.keyboard.press("Escape");
      const atTop = (await page.evaluate(`window.__lh.headerAtTop("file150.ts")`)) as boolean;
      const target = atTop ? "file030.ts" : "file150.ts";
      await page.click("#jump-to-file-button");
      await page.waitForSelector(".jump-palette-input");
      await page.fill(".jump-palette-input", target.replace(".ts", ""));
      await page.waitForSelector(`.jump-palette-row-active:has(.jump-palette-name:text-is("${target}"))`);
      return `window.__lh.headerAtTop(${js(target)})`;
    },
    async input(page) {
      await page.keyboard.press("Enter");
    },
    settle: settle(300),
  },
  {
    name: "filter typing",
    async prepare(page) {
      await helpers(page);
      if ((await attr(page, "body", "data-files-hidden")) === "true") {
        await page.click("#files-toggle");
        await page.waitForTimeout(350);
      }
      await page.fill("#file-filter-input", "");
      await page.waitForFunction(() =>
        Boolean(
          document
            .querySelector("file-tree-container")
            ?.shadowRoot?.querySelector('[data-item-path="src/area00/file000.ts"]'),
        ),
      );
      await page.focus("#file-filter-input");
      // "7" keeps file007, file017, ... and drops file000.
      return `!window.__lh.treeRow("src/area00/file000.ts") && Boolean(window.__lh.tree()?.querySelector('[data-item-path$="7.ts"]'))`;
    },
    async input(page) {
      await page.keyboard.press("7");
    },
    async settle(page) {
      await page.waitForTimeout(150);
      await page.fill("#file-filter-input", "");
      await page.waitForTimeout(250);
    },
  },
];

export const DIFF_PAGE: LatencyPageSpec = {
  name: "diff viewer",
  path: "/test/latency/diff.html",
  ready: `document.body.dataset.streamFileCount === "240" && document.querySelector(".file-header") !== null`,
  actions: diffActions,
};

// The markdown editor: test/latency/markdown.html (two linked files, host delay 40 ms).
const markdownActions: LatencyAction[] = [
  {
    name: "mode switch",
    async prepare(page) {
      const mode = await attr(page, ".md-page", "data-mode");
      const target = mode === "source" ? "rich" : "source";
      targets.set(page, target);
      return target === "source"
        ? `document.querySelector(".md-page")?.dataset.mode === "source" && document.querySelector("textarea.md-source") !== null`
        : `document.querySelector(".md-page")?.dataset.mode === "rich" && document.querySelector(".md-doc")?.hidden === false`;
    },
    async input(page) {
      await page.click(`.md-mode button:text-is("${targetOf(page) === "source" ? "Source" : "Rich text"}")`);
    },
    settle: settle(200),
  },
  {
    name: "open link target",
    async prepare(page) {
      if ((await attr(page, ".md-page", "data-mode")) !== "rich") {
        await page.click('.md-mode button:text-is("Rich text")');
        await page.waitForTimeout(200);
      }
      const current = await page.evaluate(() => document.querySelector(".md-file")?.textContent ?? "");
      const target = current === "a.md" ? "b.md" : "a.md";
      await page.waitForSelector(`.ProseMirror a[href="${target}"]`);
      targets.set(page, target);
      return `document.querySelector(".md-file")?.textContent === ${js(target)}`;
    },
    async input(page) {
      await page.click(`.ProseMirror a[href="${targetOf(page)}"]`, { modifiers: ["Meta"] });
    },
    settle: settle(500),
  },
  {
    name: "edit state",
    async prepare(page) {
      if ((await attr(page, ".md-page", "data-mode")) !== "source") {
        await page.click('.md-mode button:text-is("Source")');
        await page.waitForSelector("textarea.md-source");
      }
      await page.waitForFunction(
        () => document.querySelector(".md-page")?.getAttribute("data-status") === "saved",
        undefined,
        {
          timeout: 5000,
        },
      );
      await page.focus("textarea.md-source");
      return `document.querySelector(".md-page")?.dataset.status === "edited" && document.querySelector(".md-status")?.textContent === "Edited"`;
    },
    async input(page) {
      await page.keyboard.press("x");
    },
    // The edit autosaves after a pause; wait for it so the next run starts from "saved".
    async settle(page) {
      await page.waitForFunction(
        () => document.querySelector(".md-page")?.getAttribute("data-status") === "saved",
        undefined,
        {
          timeout: 5000,
        },
      );
    },
  },
  {
    name: "save state",
    async prepare(page) {
      if ((await attr(page, ".md-page", "data-mode")) !== "source") {
        await page.click('.md-mode button:text-is("Source")');
        await page.waitForSelector("textarea.md-source");
      }
      await page.focus("textarea.md-source");
      await page.keyboard.press("y");
      await page.waitForFunction(() => document.querySelector(".md-page")?.getAttribute("data-status") === "edited");
      return `document.querySelector(".md-page")?.dataset.status !== "edited"`;
    },
    async input(page) {
      await page.keyboard.press("Meta+s");
    },
    async settle(page) {
      await page.waitForFunction(
        () => document.querySelector(".md-page")?.getAttribute("data-status") === "saved",
        undefined,
        {
          timeout: 5000,
        },
      );
    },
  },
];

export const MARKDOWN_PAGE: LatencyPageSpec = {
  name: "markdown",
  path: "/test/latency/markdown.html",
  ready: `document.querySelector(".md-page")?.getAttribute("data-status") === "saved" && document.querySelector(".ProseMirror a") !== null`,
  actions: markdownActions,
};

const pickerRowName = `document.querySelector('.ve-picker-row[aria-selected="true"] .ve-picker-name')?.textContent`;
const crumbNow = `document.querySelector('.ve-crumb[aria-current="location"]')?.textContent`;

/** A fresh picker at ~/dir01 with its rows shown and the field focused and empty. */
async function freshPicker(page: Page): Promise<void> {
  await page.evaluate("window.__showPicker()");
  await page.waitForFunction(() => {
    const field = document.querySelector<HTMLInputElement>(".ve-picker-field");
    const crumb = document.querySelector('.ve-crumb[aria-current="location"]')?.textContent;
    return field?.value === "" && crumb === "dir01" && document.querySelectorAll(".ve-picker-row").length >= 40;
  });
  await page.focus(".ve-picker-field");
}

// The in-page folder picker: test/latency/picker.html?view=picker (40 folders and 60 files a level; folder mode lists the folders).
const pickerActions: LatencyAction[] = [
  {
    name: "typing",
    async prepare(page) {
      await freshPicker(page);
      return `document.querySelectorAll(".ve-picker-row").length > 0 && Array.from(document.querySelectorAll(".ve-picker-row .ve-picker-name")).every((n) => n.textContent.includes("3"))`;
    },
    async input(page) {
      await page.keyboard.press("3");
    },
  },
  {
    name: "enter",
    async prepare(page) {
      await freshPicker(page);
      const name = (await page.evaluate(pickerRowName)) as string;
      return `${crumbNow} === ${js(name)}`;
    },
    async input(page) {
      await page.keyboard.press("Tab");
    },
    settle: settle(150),
  },
  {
    name: "up",
    async prepare(page) {
      await freshPicker(page);
      return `${crumbNow} === "~"`;
    },
    async input(page) {
      await page.keyboard.press("Backspace");
    },
    settle: settle(150),
  },
  {
    name: "choose",
    async prepare(page) {
      await freshPicker(page);
      return `document.querySelector(".ve-picker") === null && document.querySelector(".chosen") !== null`;
    },
    async input(page) {
      await page.keyboard.press("Enter");
    },
  },
];

export const PICKER_PAGE: LatencyPageSpec = {
  name: "picker",
  path: "/test/latency/picker.html?view=picker",
  ready: `document.querySelector('.ve-picker[data-phase="ready"] .ve-picker-row') !== null`,
  actions: pickerActions,
};

const recentSelected = `document.querySelector('.ve-recent[aria-selected="true"] .ve-recent-name')?.textContent`;

// The diff empty state: test/latency/picker.html?view=empty (30 recent repositories).
const emptyActions: LatencyAction[] = [
  {
    name: "down",
    async prepare(page) {
      await page.evaluate("window.__showEmpty()");
      await page.waitForSelector(".ve-recent-list");
      await page.focus(".ve-recent-list");
      return `${recentSelected} === "repo1"`;
    },
    async input(page) {
      await page.keyboard.press("ArrowDown");
    },
  },
  {
    name: "enter",
    async prepare(page) {
      await page.evaluate("window.__showEmpty()");
      await page.waitForSelector(".ve-recent-list");
      await page.focus(".ve-recent-list");
      return `document.querySelector(".ve-step .ve-recent-name")?.textContent === "repo0"`;
    },
    async input(page) {
      await page.keyboard.press("Enter");
    },
  },
  {
    name: "choose",
    async prepare(page) {
      await page.evaluate("window.__showEmpty()");
      await page.waitForSelector(".ve-recent-list");
      await page.focus(".ve-recent-list");
      await page.keyboard.press("Enter");
      await page.waitForSelector(".ve-step .ve-radio:checked");
      await page.focus(".ve-step .ve-radio:checked");
      // The visible response to Open is the opening state, before the host answers.
      return `Array.from(document.querySelectorAll(".ve-step .ve-button-primary")).some((b) => b.disabled)`;
    },
    async input(page) {
      await page.keyboard.press("Enter");
    },
    settle: settle(150),
  },
];

export const EMPTY_PAGE: LatencyPageSpec = {
  name: "empty state",
  path: "/test/latency/picker.html?view=empty",
  ready: `document.querySelector(".ve-recent") !== null`,
  actions: emptyActions,
};

export const PAGES: LatencyPageSpec[] = [DIFF_PAGE, MARKDOWN_PAGE, PICKER_PAGE, EMPTY_PAGE];
