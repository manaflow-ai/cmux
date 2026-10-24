// The named actions the latency harness measures, per page. Each action's predicate is the
// VISIBLE response to the input (what the user sees change), not a later result: a source switch
// responds when the source control shows the new source, not when the new diff has loaded.
import type { Page } from "playwright";
import type { LatencyAction, LatencyPageSpec } from "./measure";

/** After a run (not measured): resolves once the page holds still, 10 painted frames with no DOM
 *  change and nothing animating (a new session streaming its patch, a slide, a menu closing), so
 *  the next run starts on an idle page. The runner installs the painted-frame helpers. */
async function quiet(page: Page): Promise<void> {
  await page.evaluate(async () => {
    let changed = true;
    const observer = new MutationObserver(() => (changed = true));
    observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
    for (let held = 0, frames = 0; held < 10 && frames < 600; frames += 1) {
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
    observer.disconnect();
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
      return `document.querySelector(".acpmux-model .acpmux-mp") !== null`;
    },
    async input(page) {
      await page.click(".acpmux-model .acpmux-picker-button");
    },
    async settle(page) {
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => document.querySelector(".acpmux-model .acpmux-mp") === null);
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

export const PAGES: LatencyPageSpec[] = [
  DIFF_PAGE,
  MARKDOWN_PAGE,
  PICKER_PAGE,
  EMPTY_PAGE,
  AGENT_PANE_PAGE,
  SETTINGS_PAGE,
];
