// l10n-allow-file: browser fixture selectors and diagnostics, not shipped UI.
// cmux-web-test-timeout: 600
//
// Every transcript line that opens something lights its words all the way through under the
// pointer, as a tool row's ("Ran 2 commands") do: its words go from their rest tone to the
// transcript's text tone, its glyph stays, and nothing moves. Leo, 2026-11-09, on "Scheduled check"
// lighting only its chevron: "this scheduled check thing isn't highlighted all the way through like
// other tool calls are". So every row kind is swept, not only that one: background turns
// ("Scheduled check", "Background update", "4 background tasks finished", a reaction's line),
// "Report from …", a sub-session's line, a notice, "Background command
// completed", "Received N messages", the plan's summary and "Worked for". A line with nothing behind
// it (a compaction's note) never lights, nor does a "Subagent finished" line with no report: only its
// name chip opens the subagent and lights (Leo, 2026-11-05: "subagents need to have their clickable
// bit be highlighted instead of the whole line click sending me to the subagent righ split"). Measured in the page from the real transcript, gallery
// entries named below. design/chat-transcript.md.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Kind = {
  /** What the row is, in the report. */
  name: string;
  entry: string;
  /** The line the pointer visits. */
  line: string;
  /** The line's words, inside `line`. */
  words: string;
  /** The line's glyph, inside `line`, when it has one in the tool rows' icon column. */
  glyph?: string;
  /** False for a line with nothing behind it: it never lights. */
  lights?: boolean;
};

await requireBrowserLane("transcript-row-word-lift-browser.test.ts", async () => {
  const KINDS: Kind[] = [
    // The reference: a tool run's summary line.
    {
      name: "tool run (Ran 2 commands)",
      entry: "agent-pane.transcript-system-rows",
      line: "button.cv-tool.is-run",
      words: ".cv-tool__text",
      glyph: ".cv-tool__icon",
    },
    {
      name: "tool call (a command)",
      entry: "agent-pane.inbox-notice",
      line: "button.cv-tool.cv-command.is-toggle",
      words: ".cv-tool__text, .cv-command__text",
      glyph: ".cv-tool__icon",
    },
    {
      name: "Scheduled check",
      entry: "agent-pane.transcript-system-rows",
      line: 'button.cv-background-turn[data-background-turn="quiet"]',
      words: ".cv-agent-activity__sentence",
      glyph: ".cv-agent-activity__icon",
    },
    {
      name: "Background update",
      entry: "agent-pane.lone-system-rows",
      line: "button.cv-background-turn",
      words: ".cv-agent-activity__sentence",
      glyph: ".cv-agent-activity__icon",
    },
    {
      name: "N background tasks finished",
      entry: "agent-pane.background-runs",
      line: 'button.cv-background-turn[data-background-turn="run"]',
      words: ".cv-agent-activity__sentence",
      glyph: ".cv-agent-activity__icon",
    },
    {
      // A failure's line under the default background-turn-look (inline): its rows already draw under
      // it, so it opens nothing and is no button, like "Subagent finished" with no report.
      name: "background reaction line (opens nothing)",
      entry: "agent-pane.background-reactions",
      line: "div.cv-background-turn",
      words: ".cv-agent-activity__sentence",
      glyph: ".cv-agent-activity__icon",
      lights: false,
    },
    {
      name: "Subagent finished, no report (only its name chip opens)",
      entry: "agent-pane.background-tasks",
      line: "div.cv-subagent-done",
      words: ".cv-agent-activity__sentence",
      glyph: ".cv-tool__icon",
      lights: false,
    },
    {
      name: "Report from (subagent report)",
      entry: "agent-pane.subagent-report",
      line: "button.cv-subagent-report__head",
      words: ".cv-subagent-report__sentence",
    },
    {
      name: "sub-session line (its name chip opens its chat)",
      entry: "agent-pane.long-report",
      line: ".cv-disclosure__open",
      words: ".cv-disclosure__label",
      glyph: ".cv-disclosure__icon",
    },
    {
      name: "notice",
      entry: "agent-pane.notice-row",
      line: ".cv-received > .cv-disclosure__line > button.cv-disclosure__toggle:not(.is-chevron)",
      words: ".cv-notice__lead",
    },
    {
      name: "Background command completed",
      entry: "agent-pane.turn-after-subagent",
      line: "button.cv-tool.cv-bgtask.is-toggle",
      words: ".cv-tool__text",
      glyph: ".cv-tool__icon",
    },
    {
      name: "Received N messages",
      entry: "agent-pane.inbox-notice",
      line: "button.cv-lane-batch__toggle",
      words: ".cv-tool__text",
    },
    {
      name: "plan summary",
      entry: "agent-pane.plan-list",
      line: "button.cv-plan__summary",
      words: ".cv-plan__text",
    },
    {
      name: "Worked for",
      entry: "agent-pane.approved-tool-row",
      line: "button.cv-worked",
      words: ".cv-worked__label",
    },
    {
      name: "compaction note (opens nothing)",
      entry: "agent-pane.transcript-system-rows",
      line: "div.cv-compaction",
      words: ".cv-tool__text",
      lights: false,
    },
  ];

  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript row word lift", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.transcript-system-rows", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry: string) => {
    const page = await browser.newPage({ viewport: { width: 760, height: 2400 } });
    await page.emulateMedia({ reducedMotion: "reduce" });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(entry, { width: 760, exp: "background-turn-look", arm: "line" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    // Each state is read as it settles: no transition is mid-way when it is read.
    await page.addStyleTag({
      content: "*, *::before, *::after { transition: none !important; animation: none !important; }",
    });
    return page;
  };

  /** The transcript's text tone, resolved in the page. */
  const textTone = (page: Page) =>
    page.evaluate(() => {
      const host = document.querySelector(".acpmux-row") ?? document.body;
      const el = document.createElement("span");
      el.style.color = "var(--cv-text)";
      host.appendChild(el);
      const color = getComputedStyle(el).color;
      el.remove();
      return color;
    });

  /** The line's words' and glyph's colours and the line's box. */
  const read = (page: Page, kind: Kind) =>
    page.evaluate(
      ({ line, words, glyph }) => {
        const el = [...document.querySelectorAll<HTMLElement>(`.acpmux-row ${line}`)].find(
          (candidate) => candidate.getBoundingClientRect().width > 0,
        );
        if (!el) return undefined;
        const word = el.querySelector(words) ?? (el.matches(words) ? el : null);
        const mark = glyph ? el.querySelector(glyph) : null;
        const box = el.getBoundingClientRect();
        const wordBox = word?.getBoundingClientRect();
        return {
          words: word ? getComputedStyle(word).color : "(no words)",
          glyph: mark ? getComputedStyle(mark).color : "",
          box: `${box.x},${box.y},${box.width},${box.height}`,
          wordBox: wordBox ? `${wordBox.x},${wordBox.y},${wordBox.width},${wordBox.height}` : "",
          point: wordBox ? { x: wordBox.x + Math.min(8, wordBox.width / 2), y: wordBox.y + wordBox.height / 2 } : null,
        };
      },
      { line: kind.line, words: kind.words, glyph: kind.glyph ?? "" },
    );

  for (const kind of KINDS)
    test(`${kind.name}: ${kind.lights === false ? "never lights" : "its words light all the way through on hover, nothing moves"}`, async () => {
      const page = await open(kind.entry);
      try {
        await page.mouse.move(1, 1);
        const rest = await read(page, kind);
        expect(rest, `${kind.entry} draws no ${kind.line}`).toBeDefined();
        expect(rest!.point).not.toBeNull();
        await page.mouse.move(rest!.point!.x, rest!.point!.y);
        const hover = await read(page, kind);
        const text = await textTone(page);
        if (kind.lights === false) expect(hover!.words).toBe(rest!.words);
        else expect(`${kind.name}: ${hover!.words}`).toBe(`${kind.name}: ${text}`);
        // The glyph never lights, and the line and its words keep their geometry.
        expect(hover!.glyph).toBe(rest!.glyph);
        expect(hover!.box).toBe(rest!.box);
        expect(hover!.wordBox).toBe(rest!.wordBox);
      } finally {
        await page.close();
      }
    });
});
