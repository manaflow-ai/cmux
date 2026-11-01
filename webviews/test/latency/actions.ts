// The named actions the latency harness measures, per page. Each action's predicate is the
// VISIBLE response to the input (what the user sees change), not a later result: a source switch
// responds when the source control shows the new source, not when the new diff has loaded.
import type { Page } from "playwright";
import type { Instrumentation, LatencyAction, LatencyPageSpec } from "./measure";
import { measureRailFlow, RAIL_DRAG_CASE } from "./rail-flow";
import { measureRailSweep } from "./rail-sweep";

/** After a run (not measured): resolves once the page holds still, 10 painted frames with no DOM
 *  change and nothing animating (a new session streaming its patch, a slide, a menu closing), so
 *  the next run starts on an idle page. The runner installs the painted-frame helpers. */
async function quiet(page: Page): Promise<void> {
  await page.evaluate(async () => {
    let changed = true;
    const observer = new MutationObserver(() => (changed = true));
    observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
    let held = 0;
    try {
      for (let frames = 0; held < 10 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        const moving = document
          .getAnimations()
          .some(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
        held = changed || moving ? 0 : held + 1;
        changed = false;
      }
      if (held < 10) throw new Error("page did not settle within 600 painted frames");
    } finally {
      observer.disconnect();
    }
  });
}

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
    settle: quiet,
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
        await quiet(page);
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
    settle: quiet,
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
    settle: quiet,
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
    settle: quiet,
  },
  {
    name: "sidebar toggle",
    async prepare(page) {
      // The panel slides at once; the diff column changes width two frames after the toggle.
      await page.waitForFunction(() => !document.querySelector<HTMLElement>("#files-sidebar")?.dataset.filesMotion);
      const hidden = await page.evaluate(() => document.body.dataset.filesHidden);
      const target = hidden === "true" ? "open" : "closed";
      return `document.querySelector("#files-sidebar")?.dataset.filesMotionTarget === ${js(target)}`;
    },
    async input(page) {
      await page.click("#files-toggle");
    },
    settle: quiet,
  },
  {
    name: "sidebar reverse",
    async prepare(page) {
      await page.waitForFunction(() => !document.querySelector<HTMLElement>("#files-sidebar")?.dataset.filesMotion);
      const hidden = await page.evaluate(() => document.body.dataset.filesHidden);
      // Start a slide, then reverse it once it has run 50 ms (the measured input). A loaded runner's
      // frame can outlast the slide; then the input toggles it back from rest, to the same target.
      await page.click("#files-toggle");
      await page.waitForFunction(() => {
        const panel = document.querySelector<HTMLElement>("#files-sidebar");
        return !panel?.dataset.filesMotion || Number(panel.getAnimations()[0]?.currentTime ?? 0) >= 50;
      });
      const target = hidden === "true" ? "closed" : "open";
      return `document.querySelector("#files-sidebar")?.dataset.filesMotionTarget === ${js(target)}`;
    },
    async input(page) {
      await page.click("#files-toggle");
    },
    settle: quiet,
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
    settle: quiet,
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
    settle: quiet,
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
    settle: quiet,
  },
  {
    name: "filter typing",
    async prepare(page) {
      await helpers(page);
      if ((await attr(page, "body", "data-files-hidden")) === "true") {
        await page.click("#files-toggle");
        await page.waitForFunction(() => !document.querySelector<HTMLElement>("#files-sidebar")?.dataset.filesMotion);
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
      await quiet(page);
      await page.fill("#file-filter-input", "");
      await quiet(page);
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
    settle: quiet,
  },
  {
    name: "open link target",
    async prepare(page) {
      if ((await attr(page, ".md-page", "data-mode")) !== "rich") {
        await page.click('.md-mode button:text-is("Rich text")');
        await page.waitForFunction(() => document.querySelector<HTMLElement>(".md-doc")?.hidden === false);
        await quiet(page);
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
    settle: quiet,
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
    settle: quiet,
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
    settle: quiet,
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
    settle: quiet,
  },
];

export const EMPTY_PAGE: LatencyPageSpec = {
  name: "empty state",
  path: "/test/latency/picker.html?view=empty",
  ready: `document.querySelector(".ve-recent") !== null`,
  actions: emptyActions,
};

// The real acpmux pane against its in-page mock daemon (test/latency/agent-pane.html). These
// measure the response that matters for desktop feel: opening a frequent picker, and opening the
// slash command menu from the composer. The mock still exercises the production reducer and
// renderers, while keeping network and daemon timing out of the input-to-paint measurement.
const agentPaneActions: LatencyAction[] = [
  {
    name: "model menu open",
    async prepare(page) {
      await page.waitForSelector(".acpmux-model .acpmux-picker-button");
      await page.keyboard.press("Escape");
      return `document.querySelector(".acpmux-quick-menu") !== null`;
    },
    async input(page) {
      await page.click(".acpmux-model .acpmux-picker-button");
    },
    async settle(page) {
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => document.querySelector(".acpmux-quick-menu") === null);
      await quiet(page);
    },
  },
  {
    name: "slash menu open",
    async prepare(page) {
      const editor = ".acpmux-composer [contenteditable='true']";
      await page.waitForSelector(editor);
      await page.focus(editor);
      await page.keyboard.press("ControlOrMeta+A");
      await page.keyboard.press("Backspace");
      await page.keyboard.press("Escape");
      return `document.querySelector(".acpmux-slash-menu") !== null`;
    },
    async input(page) {
      await page.keyboard.press("/");
    },
    async settle(page) {
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => document.querySelector(".acpmux-slash-menu") === null);
      await quiet(page);
    },
  },
  {
    // Leo 2026-10-21: a pasted screenshot showed up in the composer late. The response is its chip
    // in the strip, not the finished thumbnail: a full-screen Retina capture (3456×2234 PNG, a few
    // MB of window chrome, text and photo-like noise), pasted on the prompt as WebKit delivers it.
    name: "paste screenshot",
    async prepare(page) {
      const editor = ".acpmux-composer [contenteditable='true']";
      await page.waitForSelector(editor);
      await page.evaluate(async () => {
        const w = window as unknown as { __pasteShot?: File };
        if (w.__pasteShot) return;
        const canvas = document.createElement("canvas");
        canvas.width = 3456;
        canvas.height = 2234;
        const context = canvas.getContext("2d")!;
        const gradient = context.createLinearGradient(0, 0, canvas.width, canvas.height);
        gradient.addColorStop(0, "#1d2733");
        gradient.addColorStop(1, "#6b4f7a");
        context.fillStyle = gradient;
        context.fillRect(0, 0, canvas.width, canvas.height);
        let seed = 7;
        const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
        for (let block = 0; block < 900; block += 1) {
          context.fillStyle = `hsl(${Math.floor(random() * 360)} 40% ${20 + Math.floor(random() * 60)}%)`;
          context.fillRect(random() * canvas.width, random() * canvas.height, 20 + random() * 300, 8 + random() * 120);
        }
        context.font = "26px monospace";
        for (let line = 0; line < 70; line += 1) {
          context.fillStyle = line % 3 ? "#e6e6e6" : "#9fd3a5";
          context.fillText(
            `${line} const value = compute(${random().toString(36).slice(2)}) // ${"·".repeat(line % 40)}`,
            60,
            60 + line * 31,
          );
        }
        const photo = context.getImageData(1800, 1100, 900, 700);
        for (let at = 0; at < photo.data.length; at += 4) {
          const grain = random() * 255;
          photo.data[at] = grain;
          photo.data[at + 1] = (grain * 0.8) % 255;
          photo.data[at + 2] = 255 - grain;
        }
        context.putImageData(photo, 1800, 1100);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((made) => resolve(made!), "image/png"));
        w.__pasteShot = new File([blob], "image.png", { type: "image/png" });
      });
      await page.focus(editor);
      return `document.querySelector(".acpmux-attachments .acpmux-attachment") !== null`;
    },
    async input(page) {
      await page.evaluate(() => {
        const file = (window as unknown as { __pasteShot: File }).__pasteShot;
        const transfer = new DataTransfer();
        transfer.items.add(file);
        const event = new Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(event, "clipboardData", { value: transfer });
        document.querySelector(".acpmux-composer [contenteditable='true']")!.dispatchEvent(event);
      });
    },
    async settle(page) {
      // The read chip, then none: the next run starts from an empty strip.
      await page.waitForFunction(
        () =>
          !document.querySelector(".acpmux-attachment[aria-busy='true']") &&
          !!document.querySelector(".acpmux-attachment-remove"),
        undefined,
        { timeout: 15_000 },
      );
      await page.evaluate(() => {
        for (const remove of document.querySelectorAll<HTMLButtonElement>(".acpmux-attachment-remove")) remove.click();
      });
      await page.waitForFunction(() => document.querySelector(".acpmux-attachment") === null);
      await quiet(page);
    },
  },
];

export const AGENT_PANE_PAGE: LatencyPageSpec = {
  name: "agent pane",
  path: "/test/latency/agent-pane.html?mock",
  ready:
    `document.querySelector(".acpmux-model .acpmux-picker-button") !== null && ` +
    `document.querySelector(".acpmux-composer [contenteditable='true']") !== null`,
  actions: agentPaneActions,
};

const composerEditor = ".acpmux-composer [contenteditable='true']";
const profiled = ["longTasks", "reactCommits"] as const;
// WebKit does not expose the Long Tasks API. Keep React commit evidence required there,
// while Chromium requires both sources.
const requiredProfiled = (engine: string): Instrumentation[] =>
  engine === "chromium" ? [...profiled] : ["reactCommits"];
const shown = (selector: string) => `(() => {
  const node = document.querySelector(${js(selector)});
  if (!node) return false;
  const box = node.getBoundingClientRect();
  return box.width > 0 && box.height > 0 && box.bottom > 0 && box.top < innerHeight &&
    box.right > 0 && box.left < innerWidth && getComputedStyle(node).visibility !== "hidden" &&
    Number(getComputedStyle(node).opacity) > 0;
})()`;

async function clearComposer(page: Page): Promise<void> {
  await page.focus(composerEditor);
  await page.keyboard.press("ControlOrMeta+A");
  await page.keyboard.press("Backspace");
  await page.keyboard.press("Escape");
}

async function flowChat(page: Page): Promise<void> {
  await page.evaluate("window.__latencyFlows.restoreChat()");
  await page.waitForSelector(composerEditor);
  await page.waitForFunction(() => !document.querySelector(".nt-screen"));
  await page.keyboard.press("Escape");
  if (await page.$("aside.acpmux-session-info")) {
    await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("toggleSessionInfo"));
    await page.waitForSelector("aside.acpmux-session-info", { state: "detached" });
  }
  await clearComposer(page);
  await quiet(page);
}

function pickerOpen(id: string, name: string, trigger: string, popup: string, keyboard = false): LatencyAction {
  return {
    id,
    name,
    metricType: "target_painted",
    requiredInstrumentation: requiredProfiled,
    async prepare(page) {
      await flowChat(page);
      await page.waitForSelector(trigger);
      if (keyboard) await page.focus(trigger);
      return shown(popup);
    },
    async input(page) {
      if (keyboard) await page.keyboard.press("ArrowDown");
      else await page.click(trigger);
    },
    async settle(page) {
      await page.keyboard.press("Escape");
      await page.waitForSelector(popup, { state: "detached" });
      await quiet(page);
    },
  };
}

function composerMenu(id: string, name: string, key: string, popup: string): LatencyAction {
  return {
    id,
    name,
    metricType: "target_painted",
    requiredInstrumentation: requiredProfiled,
    async prepare(page) {
      await flowChat(page);
      await page.focus(composerEditor);
      return shown(popup);
    },
    async input(page) {
      await page.keyboard.press(key);
    },
    async settle(page) {
      await clearComposer(page);
      await page.waitForSelector(popup, { state: "detached" });
      await quiet(page);
    },
  };
}

const flowActions: LatencyAction[] = [
  pickerOpen(
    "chat.picker.model.pointer",
    "model picker open (pointer)",
    ".acpmux-model .acpmux-picker-button",
    ".acpmux-model .acpmux-mp",
  ),
  pickerOpen(
    "chat.picker.model.keyboard",
    "model picker open (keyboard)",
    ".acpmux-model .acpmux-picker-button",
    ".acpmux-model .acpmux-mp",
    true,
  ),
  pickerOpen(
    "chat.picker.access.open",
    "access picker open",
    ".acpmux-access .acpmux-picker-button",
    ".acpmux-access-menu",
  ),
  pickerOpen(
    "chat.menu.add.open",
    "add menu open",
    ".acpmux-composer-plus .acpmux-picker-button",
    ".acpmux-composer-plus [role='listbox']",
  ),
  composerMenu("chat.menu.slash.open", "slash menu open", "/", ".acpmux-slash-menu:not(.acpmux-mention-menu)"),
  composerMenu("chat.menu.mention.open", "mention menu open", "@", ".acpmux-mention-menu"),
  {
    id: "chat.type.character",
    name: "type a character",
    metricType: "target_painted",
    requiredInstrumentation: requiredProfiled,
    async prepare(page) {
      await flowChat(page);
      return `document.querySelector(${js(composerEditor)})?.textContent === "x"`;
    },
    async input(page) {
      await page.keyboard.press("x");
    },
    async settle(page) {
      await clearComposer(page);
      await quiet(page);
    },
  },
  {
    id: "chat.send",
    name: "send prompt",
    metricType: "target_painted",
    requiredInstrumentation: requiredProfiled,
    async prepare(page) {
      await flowChat(page);
      const text = `Latency prompt ${Date.now()}`;
      await page.keyboard.insertText(text);
      await quiet(page);
      return `Array.from(document.querySelectorAll(".cv-user__bubble")).some((node) => {
        if (node.textContent?.trim() !== ${js(text)}) return false;
        const row = node.closest(".acpmux-row");
        if (row && Number(getComputedStyle(row).opacity) === 0) return false;
        const box = node.getBoundingClientRect();
        const scroll = node.closest(".acpmux-scroll")?.getBoundingClientRect();
        return scroll && box.width > 0 && box.height > 0 && box.bottom > Math.max(0, scroll.top) &&
          box.top < Math.min(innerHeight, scroll.bottom);
      })`;
    },
    async input(page) {
      await page.keyboard.press("Enter");
    },
    settle: quiet,
  },
  ...([true, false] as const).map((open): LatencyAction => ({
    id: `chat.session-info.${open ? "open" : "close"}`,
    name: `Session Info (${open ? "open" : "close"}, pointer)`,
    metricType: "target_painted",
    requiredInstrumentation: requiredProfiled,
    async prepare(page) {
      await flowChat(page);
      if (!open) {
        await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("toggleSessionInfo"));
        await page.waitForSelector("aside.acpmux-session-info[data-presence='shown']");
        await quiet(page);
      }
      return open
        ? shown("aside.acpmux-session-info[data-presence='shown']")
        : `document.querySelector("aside.acpmux-session-info") === null`;
    },
    async input(page) {
      await page.click("button.acpmux-session-info-toggle");
    },
    settle: quiet,
  })),
  {
    id: "chat.session-info.command",
    name: "toggleSessionInfo (web command)",
    metricType: "target_painted",
    requiredInstrumentation: requiredProfiled,
    async prepare(page) {
      await flowChat(page);
      return shown("aside.acpmux-session-info[data-presence='shown']");
    },
    async input(page) {
      // The same bridge used by the native palette, with native command lookup/IPC excluded.
      await page.evaluate(
        "window.__latency.markInput('session-info-command'); window.cmuxAcpmuxBridge.command('toggleSessionInfo')",
      );
    },
    settle: quiet,
  },
  {
    id: "chat.new-tab.open",
    name: "openNewTab (web adoption)",
    metricType: "target_painted",
    requiredInstrumentation: requiredProfiled,
    async prepare(page) {
      await flowChat(page);
      return shown(".nt-screen .nt-field");
    },
    async input(page) {
      await page.evaluate("window.__latency.markInput('new-tab-adoption'); window.__latencyFlows.openNewTab()");
    },
    async settle(page) {
      await flowChat(page);
    },
  },
];

export const CHAT_FLOWS_PAGE: LatencyPageSpec = {
  name: "chat flows",
  path: "/test/latency/flows.html?mock&recents=demo",
  ready: `document.documentElement.dataset.latencyFlowsReady === "true"`,
  actions: flowActions,
};

function longScroll(resident: boolean): LatencyAction {
  return {
    id: `chat.scroll.3000.${resident ? "resident" : "paged"}`,
    name: `3000-turn scroll (${resident ? "resident mixed rows" : "paged heavy history tail"})`,
    metricType: "target_painted",
    requiredInstrumentation: requiredProfiled,
    async prepare(page) {
      await page.waitForSelector(".acpmux-scroll");
      await page.evaluate(() => {
        const scroll = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroll.scrollTop = scroll.scrollHeight;
      });
      await quiet(page);
      const from = await page.locator(".acpmux-scroll").evaluate((node) => node.scrollTop);
      if (from < 600) throw new Error("long transcript does not have a scrollable history");
      await page.locator(".acpmux-scroll").hover();
      return `(() => {
        const scroll = document.querySelector(".acpmux-scroll");
        if (!scroll || scroll.scrollTop > ${from - 400}) return false;
        const viewport = scroll.getBoundingClientRect();
        return Array.from(scroll.querySelectorAll(".acpmux-row")).some((row) => {
          const box = row.getBoundingClientRect();
          return row.textContent?.trim() && Number(getComputedStyle(row).opacity) > 0 && box.width > 0 && box.height > 0 &&
            box.bottom > Math.max(0, viewport.top) && box.top < Math.min(innerHeight, viewport.bottom);
        });
      })()`;
    },
    async input(page) {
      await page.mouse.wheel(0, -600);
    },
    settle: quiet,
  };
}

export const LONG_CHAT_PAGES: LatencyPageSpec[] = [false, true].map((resident) => ({
  name: `chat 3000 ${resident ? "resident" : "paged"}`,
  path: `/test/latency/flows.html?mock&turns=3000${resident ? "&resident" : ""}`,
  ready: `document.documentElement.dataset.latencyFlowsReady === "true"`,
  actions: [longScroll(resident)],
}));

export const RAIL_DRAG_PAGE: LatencyPageSpec = {
  name: "chat rail",
  path: "/test/latency/flows.html?mock&turns=3000&resident",
  ready: `document.documentElement.dataset.latencyFlowsReady === "true"`,
  actions: [RAIL_DRAG_CASE.metric, RAIL_DRAG_CASE.frameMetric].map((metricType) => ({
    id: metricType === RAIL_DRAG_CASE.metric ? RAIL_DRAG_CASE.id : `${RAIL_DRAG_CASE.id}.cadence`,
    name: metricType === RAIL_DRAG_CASE.metric ? "rail drag target paint" : "rail drag frame cadence",
    metricType,
    requiredInstrumentation: requiredProfiled,
    measureRun: measureRailFlow,
    settle: quiet,
  })),
};

// The session rail at 3,000 prompts (Leo: "on the left, faster scroll and hover, scrollable"; "ultra
// fast ultra responsive"), on the same resident chat as the rail drag. Each case starts with the
// transcript and the rail list at their ends, the pointer off the rail and the hover cards' group
// cold. A hover arms the probe on its `pointerover` (the probe's default inputs are presses, keys
// and wheels: without it a hover never starts the clock and every run timed out at 5 s).
const RAIL_LIST = ".acpmux-minimap__list";
const RAIL_CARD = ".acpmux-minimap__card";
/** Past the rail card's leave grace and the hover group's warmth (ui/hoverIntent.ts). */
const RAIL_COOL_MS = 800;
const RAIL_WHEEL_STEPS = 10;
const RAIL_WHEEL_DELTA = 100;
/** How far above the hovered tick a click case's target is, in rows: 150 px of transcript and more. */
const RAIL_CLICK_ROWS = 15;

type RailTick = { index: number; x: number; y: number };
const railTicks = new WeakMap<Page, RailTick>();

/** What the rail shows now, for an error that says why a case could not start. */
const railState = (page: Page) =>
  page
    .evaluate(() => {
      const rail = document.querySelector(".acpmux-minimap__rail");
      const list = document.querySelector<HTMLElement>(".acpmux-minimap__list");
      return JSON.stringify({
        rail: !!rail,
        occluded: rail?.hasAttribute("data-occluded") ?? null,
        ticks: document.querySelectorAll("[data-tick]").length,
        list: list ? [list.scrollTop, list.scrollHeight, list.clientHeight] : null,
        card: !!document.querySelector(".acpmux-minimap__card"),
        sessionInfo: !!document.querySelector("aside.acpmux-session-info"),
      });
    })
    .catch((error: unknown) => `unreadable: ${String(error)}`);

async function railAway(page: Page): Promise<void> {
  const size = page.viewportSize() ?? { width: 1280, height: 800 };
  await page.mouse.move(size.width - 4, 4);
  await page.waitForFunction((card) => !document.querySelector(card), RAIL_CARD, { timeout: 5_000 });
  await quiet(page);
}

/** Puts the transcript and the rail list at their ends; the tick `above` rows over the one in the
 *  middle of the rail's view, clear of its fades. */
async function railRestTick(page: Page, above = 0): Promise<RailTick> {
  try {
    // The flows fixture opens Session Info. On older builds the rail stepped aside for it; closed,
    // every build draws the rail beside the text, so every arm measures the same rail.
    if (await page.$("aside.acpmux-session-info")) {
      await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("toggleSessionInfo"));
      await page.waitForSelector("aside.acpmux-session-info", { state: "detached", timeout: 5_000 });
    }
    await page.waitForSelector(RAIL_LIST, { state: "attached", timeout: 10_000 });
    await page.evaluate((selector) => {
      const transcript = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      transcript.scrollTop = transcript.scrollHeight;
      const list = document.querySelector<HTMLElement>(selector)!;
      list.scrollTop = list.scrollHeight;
    }, RAIL_LIST);
    await railAway(page);
    // fixed-wait: the hover group stays warm this long after a card hides; a cold first hover is measured
    await page.waitForTimeout(RAIL_COOL_MS);
    return await page.evaluate(
      ([selector, rows]) => {
        const list = document.querySelector<HTMLElement>(selector)!;
        const box = list.getBoundingClientRect();
        const ticks = [...list.querySelectorAll<HTMLElement>("[data-tick]")].filter((tick) => {
          const rect = tick.getBoundingClientRect();
          return rect.height > 0 && rect.top >= box.top + 48 && rect.bottom <= box.bottom - 48;
        });
        if (ticks.length <= rows) throw new Error(`only ${ticks.length} rail ticks clear of the fades`);
        const tick = ticks[Math.floor(ticks.length / 2) - rows]!;
        const rect = tick.getBoundingClientRect();
        const at = { index: Number(tick.dataset.tick), x: rect.left + 8, y: rect.top + rect.height / 2 };
        const top = document.elementFromPoint(at.x, at.y);
        if (!top?.closest("[data-tick]")) throw new Error(`the point over tick ${at.index} hits ${top?.className}`);
        return at;
      },
      [RAIL_LIST, Math.floor(above)] as const,
    );
  } catch (error) {
    throw new Error(
      `rail not ready (${String((error as Error).message ?? error).split("\n")[0]}): ${await railState(page)}`,
    );
  }
}

function railHover(id: string, name: string, predicate: (index: number) => string): LatencyAction {
  return {
    id,
    name,
    metricType: "target_painted",
    inputEvent: "pointerover",
    requiredInstrumentation: requiredProfiled,
    async prepare(page) {
      const tick = await railRestTick(page);
      railTicks.set(page, tick);
      return predicate(tick.index);
    },
    async input(page) {
      const tick = railTicks.get(page)!;
      await page.mouse.move(tick.x, tick.y);
    },
    settle: railAway,
  };
}

export const RAIL_POINTER_PAGE: LatencyPageSpec = {
  name: "chat rail pointer",
  path: "/test/latency/flows.html?mock&turns=3000&resident",
  ready: `document.documentElement.dataset.latencyFlowsReady === "true"`,
  actions: [
    railHover(
      "chat.rail.hover.tick",
      "rail hover lights the tick",
      (index) => `document.querySelector('[data-tick="${index}"]')?.getAttribute("data-tone") === "active"`,
    ),
    railHover("chat.rail.hover.card", "rail hover opens the preview card", () => shown(RAIL_CARD)),
    {
      id: "chat.rail.wheel",
      name: "rail wheel scroll",
      metricType: "scroll_frame_time",
      requiredInstrumentation: requiredProfiled,
      async prepare(page) {
        const tick = await railRestTick(page);
        // The pointer rests on the rail, and the card its hover opens has opened, before the wheel.
        await page.mouse.move(tick.x, tick.y);
        await quiet(page);
        const from = await page.evaluate(
          (selector) => document.querySelector<HTMLElement>(selector)!.scrollTop,
          RAIL_LIST,
        );
        const travel = RAIL_WHEEL_STEPS * RAIL_WHEEL_DELTA;
        if (from < travel + 100) throw new Error(`rail list at ${from} has too little history to wheel through`);
        return `document.querySelector(${js(RAIL_LIST)}).scrollTop <= ${from - travel + RAIL_WHEEL_DELTA / 2}`;
      },
      async input(page) {
        for (let step = 0; step < RAIL_WHEEL_STEPS; step += 1) {
          await page.mouse.wheel(0, -RAIL_WHEEL_DELTA);
          await page.evaluate(() => window.cmuxPaintFrame());
        }
      },
      settle: railAway,
    },
    {
      id: "chat.rail.click",
      name: "rail click lands the prompt",
      metricType: "target_painted",
      requiredInstrumentation: requiredProfiled,
      async prepare(page) {
        const tick = await railRestTick(page, RAIL_CLICK_ROWS);
        // The pointer rests on the tick first, as a person's does before a click (not measured).
        await page.mouse.move(tick.x, tick.y);
        await quiet(page);
        railTicks.set(page, tick);
        // Landed: the prompt's bubble drawn LANDING_OFFSET (35 px) below the transcript's top.
        return `(() => {
          const view = document.querySelector(".acpmux-scroll")?.getBoundingClientRect();
          const bubble = document.querySelector('.acpmux-row[data-row-id="synthetic-user-${tick.index}"] .cv-user__bubble');
          if (!view || !bubble) return false;
          const at = bubble.getBoundingClientRect().top - view.top;
          return at > 0 && at < 120;
        })()`;
      },
      async input(page) {
        await page.mouse.down();
        await page.mouse.up();
      },
      settle: railAway,
    },
  ],
};

// The rail hover sweep (rail-sweep.ts): the pointer crosses up to 120 ticks of the rail's view and
// back, one move per painted frame, on the 3,000-prompt chat and a typical 100-prompt one. Each move
// is timed to the frame that shows its tick lit and the card previewing its prompt.
const RAIL_SWEEP_TICKS = 120;
export const RAIL_SWEEP_PAGES: LatencyPageSpec[] = [3000, 100].map((turns) => ({
  name: `chat rail sweep ${turns}`,
  path: `/test/latency/flows.html?mock&turns=${turns}&resident`,
  ready: `document.documentElement.dataset.latencyFlowsReady === "true"`,
  actions: [
    {
      id: `chat.rail.hover.sweep.${turns}`,
      name: `rail hover sweep (${turns} prompts)`,
      metricType: "target_painted",
      requiredInstrumentation: requiredProfiled,
      measureRun: measureRailSweep(RAIL_SWEEP_TICKS),
      settle: railAway,
    },
  ],
}));

// Settings (test/latency/settings.html, host delay 40 ms): a sidebar section switch, from the input
// to the first painted frame that shows the new section complete (its title and the host-read
// buttons at its end). Two sections with host reads alternate. "click" is a pointer that lands and
// clicks at once (no time to preload); "hover, then click" rests on the link first, as a person
// does before a click, so the router's intent preload can read the section ahead.
const SETTINGS_CYCLE = ["advanced", "general"] as const;
const settingsTarget = new WeakMap<Page, number>();
const nextSettingsSection = (page: Page) => {
  const index = ((settingsTarget.get(page) ?? -1) + 1) % SETTINGS_CYCLE.length;
  settingsTarget.set(page, index);
  return SETTINGS_CYCLE[index]!;
};
const settingsComplete = (section: string) =>
  `document.querySelector('[data-section=${js(section)}] h1') !== null && ` +
  `document.querySelector('[data-section-actions=${js(section)}] button') !== null`;
const settingsLink = (section: string) => `[data-section-link=${js(section)}]`;

const settingsActions: LatencyAction[] = [
  {
    name: "section switch (click)",
    async prepare(page) {
      await page.mouse.move(1, 1);
      const section = nextSettingsSection(page);
      targets.set(page, section);
      return settingsComplete(section);
    },
    async input(page) {
      await page.click(settingsLink(targetOf(page)));
    },
    settle: quiet,
  },
  {
    name: "section switch (hover, then click)",
    async prepare(page) {
      await page.mouse.move(1, 1);
      const section = nextSettingsSection(page);
      targets.set(page, section);
      await page.hover(settingsLink(section));
      // fixed-wait: a person's pointer rests on a link about this long before the click (not measured)
      await page.waitForTimeout(150);
      return settingsComplete(section);
    },
    async input(page) {
      await page.mouse.down();
      await page.mouse.up();
    },
    settle: quiet,
  },
];

export const SETTINGS_PAGE: LatencyPageSpec = {
  name: "settings",
  path: "/test/latency/settings.html?hostDelay=40#/settings/general",
  ready: `document.querySelector('[data-section="general"] [data-section-actions="general"] button') !== null`,
  actions: settingsActions,
};

/** Opening another chat with Session Info open, once per arm of the chat-switch-motion experiment
 *  (flows.harness.ts `switch=`): the frames from the switch until every part of its motion settled. */
function chatSwitch(arm: string): LatencyPageSpec {
  return {
    name: `chat switch ${arm}`,
    path: `/test/latency/flows.html?mock&switch=${arm}`,
    ready: `document.documentElement.dataset.latencyFlowsReady === "true"`,
    actions: [
      {
        id: `chat.switch.${arm}`,
        name: `open another chat (${arm} motion)`,
        metricType: "frame_time",
        requiredInstrumentation: requiredProfiled,
        async prepare(page) {
          await page.evaluate("window.__latencyFlows.restoreChat()");
          await page.waitForSelector(".acpmux-scroll .acpmux-row");
          if (!(await page.$("aside.acpmux-session-info")))
            await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("toggleSessionInfo"));
          await page.waitForSelector("aside.acpmux-session-info[data-presence='shown']");
          await quiet(page);
          const from = await page.evaluate(() => document.querySelector(".acpmux-thread-title")?.textContent ?? "");
          // Landed and settled: another title, rows drawn, and no part of the switch still moving.
          return `(() => {
            const title = document.querySelector(".acpmux-thread-title")?.textContent ?? "";
            if (title === ${js(from)} || !document.querySelector(".acpmux-scroll .acpmux-row")) return false;
            return !document.getAnimations().some((animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime));
          })()`;
        },
        async input(page) {
          await page.evaluate("window.__latency.markInput('chat-switch'); window.__latencyFlows.openOtherChat()");
        },
        async settle(page) {
          await page.evaluate("window.__latencyFlows.restoreChat()");
          await quiet(page);
        },
      },
    ],
  };
}

const GLASS_WHEEL_STEPS = 12;
const GLASS_WHEEL_DELTA = 120;

/** The 3,000-turn chat scrolled under its glass (composer, user bubbles, Session Info) over a
 *  picture, once per glass mode (flows.harness.ts `glass=`): the frame cost of each glass. */
function glassScroll(mode: string): LatencyPageSpec {
  return {
    name: `chat glass ${mode}`,
    path: `/test/latency/flows.html?mock&turns=3000&resident&glass=${mode}`,
    ready: `document.documentElement.dataset.latencyFlowsReady === "true"`,
    actions: [
      {
        id: `chat.glass.${mode}.scroll`,
        name: `scroll under ${mode} glass`,
        metricType: "scroll_frame_time",
        requiredInstrumentation: requiredProfiled,
        async prepare(page) {
          await page.waitForSelector(".acpmux-scroll");
          await page.evaluate(() => {
            const scroll = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            scroll.scrollTop = scroll.scrollHeight;
          });
          await quiet(page);
          const from = await page.locator(".acpmux-scroll").evaluate((node) => node.scrollTop);
          const travel = GLASS_WHEEL_STEPS * GLASS_WHEEL_DELTA;
          if (from < travel + 100) throw new Error("long transcript does not have a scrollable history");
          await page.locator(".acpmux-scroll").hover();
          return `document.querySelector(".acpmux-scroll").scrollTop <= ${from - travel + GLASS_WHEEL_DELTA / 2}`;
        },
        async input(page) {
          for (let step = 0; step < GLASS_WHEEL_STEPS; step += 1) {
            await page.mouse.wheel(0, -GLASS_WHEEL_DELTA);
            await page.evaluate(() => window.cmuxPaintFrame());
          }
        },
        settle: quiet,
      },
    ],
  };
}

export const CHAT_SWITCH_PAGES: LatencyPageSpec[] = ["off", "fade", "stagger", "depth"].map(chatSwitch);
export const GLASS_PAGES: LatencyPageSpec[] = ["plain", "lens-flat", "lens", "prism", "svg"].map(glassScroll);

const LIVE_WHEEL_STEPS = 12;
const LIVE_WHEEL_DELTA = 120;

/** The 3,000-turn chat scrolled over a live background (flows.harness.ts `live=`; `none` draws
 *  none): what the background's loop costs the transcript's frames. */
function liveScroll(style: string): LatencyPageSpec {
  return {
    name: `chat live background ${style}`,
    path: `/test/latency/flows.html?mock&turns=3000&resident${style === "none" ? "" : `&live=${style}`}`,
    ready: `document.documentElement.dataset.latencyFlowsReady === "true"`,
    actions: [
      {
        id: `chat.live-background.${style}.scroll`,
        name: `scroll over live background (${style})`,
        metricType: "scroll_frame_time",
        requiredInstrumentation: requiredProfiled,
        async prepare(page) {
          await page.waitForSelector(".acpmux-scroll");
          await page.evaluate(() => {
            const scroll = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            scroll.scrollTop = scroll.scrollHeight;
          });
          await quiet(page);
          const from = await page.locator(".acpmux-scroll").evaluate((node) => node.scrollTop);
          const travel = LIVE_WHEEL_STEPS * LIVE_WHEEL_DELTA;
          if (from < travel + 100) throw new Error("long transcript does not have a scrollable history");
          await page.locator(".acpmux-scroll").hover();
          return `document.querySelector(".acpmux-scroll").scrollTop <= ${from - travel + LIVE_WHEEL_DELTA / 2}`;
        },
        async input(page) {
          for (let step = 0; step < LIVE_WHEEL_STEPS; step += 1) {
            await page.mouse.wheel(0, -LIVE_WHEEL_DELTA);
            await page.evaluate(() => window.cmuxPaintFrame());
          }
        },
        settle: quiet,
      },
    ],
  };
}

export const LIVE_BACKGROUND_PAGES: LatencyPageSpec[] = ["none", "aurora", "grain"].map(liveScroll);

export const PAGES: LatencyPageSpec[] = [
  DIFF_PAGE,
  MARKDOWN_PAGE,
  PICKER_PAGE,
  EMPTY_PAGE,
  AGENT_PANE_PAGE,
  CHAT_FLOWS_PAGE,
  ...LONG_CHAT_PAGES,
  SETTINGS_PAGE,
  RAIL_DRAG_PAGE,
  RAIL_POINTER_PAGE,
  ...RAIL_SWEEP_PAGES,
  // Experiment comparisons (design/glass.md, design/motion-and-polish.md in leo-workspace): run on
  // demand with CMUX_LATENCY_EXPERIMENTS=1, never in the CI scoreboard.
  ...(process.env.CMUX_LATENCY_EXPERIMENTS === "1" ? CHAT_SWITCH_PAGES : []),
  ...(process.env.CMUX_LATENCY_EXPERIMENTS === "1" ? GLASS_PAGES : []),
  ...(process.env.CMUX_LATENCY_EXPERIMENTS === "1" ? LIVE_BACKGROUND_PAGES : []),
];
