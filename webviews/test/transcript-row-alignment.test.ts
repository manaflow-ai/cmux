// Status, tool and message rows share the prose's left edge and sit in the middle of their gap.
//
// Leo, 2026-10-30, on Claude Code desktop's status rows beside ours: "see how claude code has those
// centered tool calls / id like more alignment too"; and on Codex's and Claude's action rows beside
// ours: "1 CODEX 2 US 3 US 4 CODEX 5 CLAUDDE WE NEED TO LINE OUR SHIT UP LIKE THEIRS".
//
// In gallery entry agent-pane.transcript-row-alignment (a reply, a tool call, a reply, a subagent
// that finished, a reply, a background command that ended, a reply, another agent's message, a
// reply; above them a folded
// turn's "Worked for" line and a footer with its time, tokens and actions), measured from the
// transcript column's left edge (`col-left`, design/grid.md 5.5) in light and dark:
// - every reply's first glyph, a "Worked for" line's first glyph, the footer's "Worked for" label
//   and the first glyph of every action row (a reply's, a footer's) start on col-left;
// - every row with a leading icon (a tool row, a subagent's end, a background command's end,
//   another agent's message) has its 16px icon box on col-left and its words at one shared x;
// - each status row between two replies has the block gap above it and below it, so it sits in the
//   middle of its gap (design/grid.md 5.5: `--grid-gap-block` between any two transcript blocks; the
//   stack owns the gap, so #30865's reply room is 0 on the grid since #27580, which replaced the
//   26px-more-above offset this file asserted before).
//
// CMUX_ROW_ALIGNMENT_ARTIFACT_DIR=DIR (or fast-checks' FAST_CHECKS_OUT) also writes each theme's
// 2x stills and measurements to DIR.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-row-alignment.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript-row-alignment";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  /** How far apart two edges may be, in CSS px. */
  const TOLERANCE = 0.5;

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript row alignment", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "mix" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Lead = { kind: string; label: string; ink: number };
  type Iconed = { kind: string; label: string; slot: number; slotWidth: number; text: number };
  type Gap = { kind: string; label: string; above: number; below: number };
  type Measured = { leads: Lead[]; iconed: Iconed[]; gaps: Gap[]; blockGap: number };

  const measure = (page: Page): Promise<Measured> =>
    page.evaluate(() => {
      const visible = (element: Element) => {
        const box = element.getBoundingClientRect();
        return box.width > 0 && box.height > 0;
      };
      const rowOf = (element: Element) => element.closest<HTMLElement>(".acpmux-row");
      /** col-left: the transcript row's left edge, which is the prose's. */
      const origin = (element: Element) => (rowOf(element) ?? element).getBoundingClientRect().left;
      /** The first drawn text inside `scope` outside `skip`: its first glyph's left edge. */
      const firstText = (scope: Element, skip?: Element | null) => {
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (skip?.contains(node) || !node.textContent?.trim()) continue;
          const parent = node.parentElement;
          if (parent && getComputedStyle(parent).display === "none") continue;
          const range = document.createRange();
          const offset = node.textContent.length - node.textContent.trimStart().length;
          range.setStart(node, offset);
          range.setEnd(node, offset + 1);
          const rect = [...range.getClientRects()].find((candidate) => candidate.width > 0);
          if (rect) return { left: rect.left, text: node.textContent.trim().slice(0, 40) };
        }
        return undefined;
      };
      const leads: { kind: string; label: string; ink: number }[] = [];
      const lead = (kind: string, element: Element | null) => {
        if (!element || !visible(element)) return;
        const first = firstText(element);
        if (first) leads.push({ kind, label: first.text, ink: first.left - origin(element) });
      };
      for (const prose of document.querySelectorAll(".acpmux-row.acpmux-assistant .cv-md")) lead("reply", prose);
      for (const worked of document.querySelectorAll(".cv-worked.is-toggle")) lead("worked-for", worked);
      for (const label of document.querySelectorAll(".cv-turn-summary")) lead("footer label", label);
      // An action row's first glyph: its 16px box, where Codex and Claude start the copy glyph.
      // A footer that says its time first leads with that label instead (measured above).
      for (const actions of document.querySelectorAll(".cv-turn-actions .cv-turn-action-group")) {
        if (actions.previousElementSibling) continue;
        const glyph = actions.querySelector(".cv-iconbtn svg");
        if (!glyph || !visible(glyph)) continue;
        const kind = actions.closest(".cv-reply-actions") ? "reply actions" : "footer actions";
        leads.push({ kind, label: "first glyph", ink: glyph.getBoundingClientRect().left - origin(glyph) });
      }
      const iconed: { kind: string; label: string; slot: number; slotWidth: number; text: number }[] = [];
      const ROWS: [string, string, string][] = [
        ["tool", ".acpmux-activity .cv-tool", ":scope > .cv-tool__icon"],
        ["subagent finished", ".cv-subagent-done", ":scope > .cv-tool__icon"],
        ["background command", ".acpmux-backgroundTask .cv-tool", ":scope > .cv-tool__icon"],
        ["agent message", ".cv-received > .cv-disclosure__line", ".cv-received__mark"],
      ];
      for (const [kind, selector, icon] of ROWS)
        for (const element of document.querySelectorAll(selector)) {
          if (!visible(element)) continue;
          const slot = element.querySelector(icon);
          if (!slot) continue;
          const first = firstText(element, slot);
          if (!first) continue;
          const box = slot.getBoundingClientRect();
          iconed.push({
            kind,
            label: first.text,
            slot: box.left - origin(element),
            slotWidth: box.width,
            text: first.left - origin(element),
          });
        }
      // The status rows of the live turn, each between two replies: the room from the reply above
      // (its last line's box) to the row's line, and from the row's line to the reply below.
      const gaps: { kind: string; label: string; above: number; below: number }[] = [];
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")]
        .filter(visible)
        .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
      const STATUS: [string, string][] = [
        ["tool", ".acpmux-activity > .cv-tools"],
        ["subagent finished", ".cv-subagent-done"],
        ["background command", ".acpmux-backgroundTask .cv-tool"],
        ["agent message", ".cv-received > .cv-disclosure__line"],
      ];
      for (let index = 1; index < rows.length - 1; index += 1) {
        const before = rows[index - 1]!.querySelector(".cv-md");
        const after = rows[index + 1]!.querySelector(".cv-md");
        if (!before || !after) continue;
        for (const [kind, selector] of STATUS) {
          const line = rows[index]!.querySelector(selector);
          if (!line) continue;
          const box = line.getBoundingClientRect();
          gaps.push({
            kind,
            label: line.textContent?.trim().slice(0, 40) ?? "",
            above: box.top - before.getBoundingClientRect().bottom,
            below: after.getBoundingClientRect().top - box.bottom,
          });
        }
      }
      // The block gap, read from the live token (design/grid.md 5.5, --grid-gap-block).
      const probe = document.createElement("div");
      probe.style.cssText = "position:absolute;visibility:hidden;height:var(--grid-gap-block)";
      (document.querySelector(".acpmux-row") ?? document.body).appendChild(probe);
      const blockGap = probe.getBoundingClientRect().height;
      probe.remove();
      return { leads, iconed, gaps, blockGap };
    });

  const px = (value: number) => `${Math.round(value * 100) / 100}px`;

  /** What breaks the shared left edge or the centred gaps, as sentences; empty when the rows keep them. */
  const problems = ({ leads, iconed, gaps, blockGap }: Measured) => {
    const found: string[] = [];
    for (const item of leads)
      if (Math.abs(item.ink) > TOLERANCE)
        found.push(`the ${item.kind} "${item.label}" starts at ${px(item.ink)}, not on the prose's left edge (0px)`);
    const text = iconed[0]?.text;
    for (const item of iconed) {
      if (Math.abs(item.slot) > TOLERANCE)
        found.push(
          `the ${item.kind} row "${item.label}"'s icon box starts at ${px(item.slot)}, not on the prose's left edge`,
        );
      if (Math.abs(item.slotWidth - 16) > TOLERANCE)
        found.push(`the ${item.kind} row "${item.label}"'s icon box is ${px(item.slotWidth)} wide, not 16px`);
      if (text !== undefined && Math.abs(item.text - text) > TOLERANCE)
        found.push(
          `the ${item.kind} row "${item.label}"'s words start at ${px(item.text)}, the first iconed row's at ${px(text)}`,
        );
    }
    // A status row between two replies sits in the middle of its gap: the block gap on both sides
    // (design/grid.md 5.5; the stack owns the gap, so the reply room is 0 on the grid, #27580).
    if (!(blockGap > 0)) found.push(`the block gap token --grid-gap-block resolved to ${px(blockGap)}`);
    for (const gap of gaps)
      if (Math.abs(gap.above - blockGap) > TOLERANCE || Math.abs(gap.below - blockGap) > TOLERANCE)
        found.push(
          `the ${gap.kind} row "${gap.label}" has ${px(gap.above)} above it and ${px(gap.below)} below it, not the ${px(blockGap)} block gap on both sides`,
        );
    for (const side of ["above", "below"] as const) {
      const sizes = gaps.map((gap) => gap[side]);
      if (sizes.length > 0 && Math.max(...sizes) - Math.min(...sizes) > TOLERANCE)
        found.push(
          `the gaps ${side} status rows differ: ${gaps.map((gap) => `${gap.kind} ${px(gap[side])}`).join(", ")}`,
        );
    }
    return found;
  };

  for (const theme of THEMES)
    test(`status, tool and message rows share the prose's left edge and one gap above and below (${theme.name})`, async () => {
      const artifacts = process.env.CMUX_ROW_ALIGNMENT_ARTIFACT_DIR ?? process.env.FAST_CHECKS_OUT;
      const page = await browser.newPage({ viewport: { width: 900, height: 1200 }, deviceScaleFactor: 2 });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "footer", width: 720, theme: theme.name, reducedMotion: "true" })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        await page.evaluate(() => document.fonts.ready);
        await page.locator(".cv-received").first().waitFor();
        await page.locator(".cv-subagent-done").first().waitFor();
        const measured = await measure(page);
        console.log(`ROW_ALIGNMENT ${theme.file} ${JSON.stringify(measured)}`);
        const found = problems(measured);
        if (artifacts) {
          await mkdir(artifacts, { recursive: true });
          await writeFile(
            path.join(artifacts, `row-alignment-${theme.file}.json`),
            JSON.stringify({ theme: theme.name, ...measured, problems: found }, null, 2),
          );
          await page.screenshot({ path: path.join(artifacts, `row-alignment-${theme.file}.png`), fullPage: true });
          // The pointer on a reply with its own action row, which shows only on hover. Replies draw
          // one only where a turn's footer does not serve them (model.ts `hasReplyActions`), so the
          // capture is taken where one exists; the footer's row is in the shot above.
          if ((await page.locator(".acpmux-assistant .cv-reply-actions").count()) > 0) {
            await page.hover(".acpmux-assistant:has(.cv-reply-actions) .cv-md");
            await page.locator(".acpmux-assistant:hover .cv-reply-actions").waitFor();
            await page.screenshot({
              path: path.join(artifacts, `row-alignment-${theme.file}-actions.png`),
              fullPage: true,
            });
          }
        }
        const kinds = new Set([...measured.leads, ...measured.iconed].map((item) => item.kind));
        for (const kind of [
          "reply",
          "worked-for",
          "footer label",
          "footer actions",
          "tool",
          "subagent finished",
          "background command",
          "agent message",
        ])
          expect(kinds.has(kind), `measured a ${kind}`).toBe(true);
        expect(measured.gaps.map((gap) => gap.kind).sort()).toEqual([
          "agent message",
          "background command",
          "subagent finished",
          "tool",
        ]);
        expect(found).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
