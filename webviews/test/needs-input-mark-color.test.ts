// "Needs your input" is one colour everywhere (Leo 2026-10-21: the pill's dot was grey in one place
// and yellow in another for the same state). Every webview mark for a chat that waits on the user
// takes the theme's attention colour, which the app ships as `--agent-warning`
// (AgentPaneTheme.swift: `"warning": css(tokens.attention)`), the same Palette.attention the native
// sidebar, tab strip and priority rows draw. A theme whose accent is grey makes the accent and the
// attention colour differ, so a mark that took the accent reads as idle. This loads the real
// stylesheets in Chromium, in the order the app imports them, and reads each mark's computed colour.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("needs-input-mark-color.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("needs-input-mark-color: skipping (run `bunx playwright install chromium`)");
    describe.skip("needs input mark colour", () => test("chromium", () => {}));
    return;
  }
  const src = path.resolve(import.meta.dir, "../src/agent-session");
  const css = [
    "shared/styles.css",
    "acpmux/styles.css",
    "acpmux/summary/summary.css",
    "acpmux/offer/suggestedTasks.css",
    "acpmux/started/startedSessions.css",
    // NeedsYou.tsx imports its sheet last, after the app's own.
    "acpmux/needsYou/needsYou.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");

  // Each surface that marks "needs your input", and which of its properties carries the mark.
  const marks = [
    [
      "question card pill dot",
      `<span class="acpmux-question-status"><span class="acpmux-question-status-dot"></span></span>`,
      ".acpmux-question-status-dot",
      "background",
    ],
    ["question card pill text", `<span class="acpmux-question-status"></span>`, ".acpmux-question-status", "color"],
    [
      "Needs your input jump pill",
      `<span class="acpmux-jump-latest acpmux-needs-you-pill"><span class="acpmux-needs-you-dot"></span></span>`,
      ".acpmux-needs-you-pill .acpmux-needs-you-dot",
      "background",
    ],
    [
      "Needs you header badge",
      `<span class="acpmux-needs-you-count"><span class="acpmux-needs-you-dot"></span></span>`,
      ".acpmux-needs-you-count .acpmux-needs-you-dot",
      "background",
    ],
    [
      "sidebar session mark",
      `<span class="acpmux-session-mark acpmux-session-mark-input"></span>`,
      ".acpmux-session-mark-input",
      "color",
    ],
    [
      "Chief dock status",
      `<span class="acpmux-chief-dock-status" data-status="attention"></span>`,
      ".acpmux-chief-dock-status",
      "color",
    ],
    [
      "floating chat status",
      `<span class="acpmux-floating-status" data-status="attention"></span>`,
      ".acpmux-floating-status",
      "background",
    ],
    ["home list dot", `<span class="acpmux-home-dot"></span>`, ".acpmux-home-dot", "background"],
    [
      "started chat status line",
      `<span class="acpmux-session-status" data-status="waiting"></span>`,
      ".acpmux-session-status",
      "color",
    ],
    [
      "summary agent state",
      `<span class="acpmux-summary-agent" data-status="waiting"><span class="acpmux-summary-agent__state"></span></span>`,
      ".acpmux-summary-agent__state",
      "color",
    ],
    [
      "suggested task dot",
      `<span class="acpmux-task-started" data-state="waiting"><span class="acpmux-task-dot"></span></span>`,
      ".acpmux-task-dot",
      "background",
    ],
  ] as const;

  // A grey accent (the bug's theme) and a light one, each with a yellow attention colour.
  const themes = [
    { name: "grey accent", accent: "rgb(142, 142, 147)", warning: "rgb(255, 204, 0)" },
    { name: "blue accent", accent: "rgb(10, 132, 255)", warning: "rgb(230, 160, 20)" },
  ] as const;

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  for (const theme of themes) {
    test(`every needs-input mark is the attention colour: ${theme.name}`, async () => {
      const p = await browser!.newPage();
      const style = `--agent-accent:${theme.accent};--cmux-accent:${theme.accent};--agent-warning:${theme.warning};--agent-muted:rgb(120, 120, 120);--agent-danger:rgb(255, 59, 48)`;
      const body = marks.map(([name, html]) => `<div data-mark="${name}">${html}</div>`).join("");
      await p.setContent(`<style>${css}</style><div class="acpmux-shell" style="${style}">${body}</div>`);
      const looks = await p.evaluate(
        (list) =>
          list.map(([name, , selector, prop]) => {
            const el = document.querySelector<HTMLElement>(`[data-mark="${name}"] ${selector}`)!;
            const look = prop === "background" ? getComputedStyle(el).backgroundColor : getComputedStyle(el).color;
            return [name, look] as const;
          }),
        marks as unknown as [string, string, string, string][],
      );
      await p.close();
      expect(Object.fromEntries(looks)).toEqual(Object.fromEntries(marks.map(([name]) => [name, theme.warning])));
    });
  }
});
