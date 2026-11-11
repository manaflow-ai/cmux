// The transcript's row kinds against their settled spacing (src/agent-session/acpmux/transcriptSpacing.ts
// TRANSCRIPT_SPACING_KINDS, leo-workspace design/transcript-spacing.md "Row kinds"). Leo, 2026-11-02
// 23:59Z, on a received line, "Scheduled check", an expanded "Ran 2 commands" and "Compacting the
// conversation…": "these are all so stupid looking" / "the spacing" / "y'all need to just go study";
// and earlier that day: "we need to like enforce the good versions when we find them later in the
// specs/comments/tests or something".
//
// Gallery entry agent-pane.transcript-spacing-table, variant all-kinds, holds each of those row kinds
// in one Claude Code chat; the test opens "Ran 2 commands" and measures every row of the table in
// Chromium, light and dark, between visible marks (a text line's glyph-box centre, a bubble's edge, a
// footer glyph's centre). A row marked `pending` is expected to fail until its PR lands
// (`test.failing`). transcript-spacing-table.test.ts measures the first table over variant shipped;
// the gap over the composer is agent-pane-composer-rest-gap.test.ts's (model.ts REST_GAP).
//
// Variants working-bottom and reply-received hold the bottom of a running turn as Leo's 2026-11-03
// captures showed it ("this is pretty bad spacing and formatting" / "i thought we made this stuff
// smaller"): every status row there is measured against TRANSCRIPT_STATUS_ROWS, and the session chips
// on those rows against SESSION_CHIP.
//
// CMUX_TRANSCRIPT_SPACING_LOG=1 logs every row's lines and every measured gap; with FAST_CHECKS_OUT
// set, each variant's capture is written there.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import {
  RUN_CHILD,
  SESSION_CHIP,
  TRANSCRIPT_SPACING_KINDS,
  TRANSCRIPT_STATUS_ROWS,
} from "../src/agent-session/acpmux/transcriptSpacing";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-spacing-kinds.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript-spacing-table";
  const VARIANT = "all-kinds";
  const THEMES = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ];
  const LOG = process.env.CMUX_TRANSCRIPT_SPACING_LOG === "1";
  const STATUS_VARIANTS = [...new Set(TRANSCRIPT_STATUS_ROWS.map((row) => row.variant))];

  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript spacing kinds", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
    for (const variant of STATUS_VARIANTS) await warmGalleryFrame(vite, ENTRY, { browser, params: { variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Measured = { gaps: Record<string, number | null>; indent: number | null; rows: string[] };

  const measure = (page: Page): Promise<Measured> =>
    page.evaluate(() => {
      type Line = { top: number; bottom: number; left: number };
      const shown = (element: Element) => {
        const box = element.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) return false;
        for (let node: Element | null = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden") return false;
        }
        return true;
      };
      /** The glyph boxes of the shown text lines under `scope`, top to bottom, one per line. */
      const lines = (scope: Element | null | undefined): Line[] => {
        if (!scope) return [];
        const out: Line[] = [];
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim() || !node.parentElement || !shown(node.parentElement)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.width === 0 || rect.height === 0) continue;
            const same = out.find((line) => Math.abs((line.top + line.bottom) / 2 - (rect.top + rect.bottom) / 2) < 4);
            if (same) {
              same.top = Math.min(same.top, rect.top);
              same.bottom = Math.max(same.bottom, rect.bottom);
              same.left = Math.min(same.left, rect.left);
            } else out.push({ top: rect.top, bottom: rect.bottom, left: rect.left });
          }
        }
        return out.sort((a, b) => a.top - b.top);
      };
      const row = (id: string) => document.querySelector(`[data-row-id="${id}"]`);
      const rowLines = (id: string) => lines(row(id));
      /** A footer's first glyph, shown or hover-revealed (an earlier turn's row keeps its place). */
      const glyph = (id: string) => {
        const svg = row(id)?.querySelector<SVGElement>(".cv-turn-actions button svg");
        const box = svg?.getBoundingClientRect();
        return box && box.height > 0 ? (box.top + box.bottom) / 2 : null;
      };
      const bubble = (id: string) => row(id)?.querySelector(".cv-user__bubble")?.getBoundingClientRect() ?? null;
      const at = (line: Line | undefined) => (line ? (line.top + line.bottom) / 2 : null);
      const diff = (a: number | null | undefined, b: number | null | undefined) =>
        a == null || b == null ? null : Math.round((b - a) * 100) / 100;

      const long = rowLines("kinds-long");
      const received = rowLines("kinds-received");
      const scheduled = rowLines("backgroundTurn-spacing-scheduled");
      const run = rowLines("kinds-run");
      const short = rowLines("kinds-short");
      const compacted = rowLines("kinds-compacted");
      const step = rowLines("kinds-step");
      const compacting = rowLines("kinds-compacting");
      const nextPrompt = bubble("kinds-next-prompt");

      const gaps: Record<string, number | null> = {
        "body-line": long.length > 1 ? diff(at(long[0]), at(long[1])) : null,
        "footer-to-received": diff(glyph("kinds-footer"), at(received[0])),
        "received-to-status": diff(at(received.at(-1)), at(scheduled[0])),
        "status-to-run": diff(at(scheduled.at(-1)), at(run[0])),
        "run-to-child": run.length > 2 ? diff(at(run[0]), at(run[1])) : null,
        "child-pitch": run.length > 2 ? diff(at(run[1]), at(run[2])) : null,
        "child-to-prose": run.length > 2 ? diff(at(run.at(-1)), at(short[0])) : null,
        "footer-to-prompt": diff(glyph("kinds-short-footer"), nextPrompt?.top),
        "prompt-to-status": diff(nextPrompt?.bottom, at(compacted[0])),
        "status-to-prose": diff(at(compacted.at(-1)), at(long[0])),
        "step-to-status": diff(at(step.at(-1)), at(compacting[0])),
      };
      const rows = [...document.querySelectorAll<HTMLElement>("[data-row-id]")].filter(shown).map((element) => {
        const box = element.getBoundingClientRect();
        const text = (element.innerText || "").replace(/\s+/g, " ").trim().slice(0, 60);
        return `${box.top.toFixed(2)}-${box.bottom.toFixed(2)} ${element.dataset.rowId} | ${text} | lines ${lines(
          element,
        )
          .map((line) => `${((line.top + line.bottom) / 2).toFixed(2)}@${line.left.toFixed(1)}`)
          .join(",")}`;
      });
      return { gaps, indent: run.length > 2 ? Math.round((run[1]!.left - run[0]!.left) * 100) / 100 : null, rows };
    });

  const open = async (theme: string, variant = VARIANT) => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 1200 }, deviceScaleFactor: 2 });
    // Leo's capture of a Claude chat, as Claude's in-place runs draw it (claudeTurnFold.experiment.ts
    // arm "runs"); by default a finished Claude turn folds under Worked for (Codex parity).
    await page.addInitScript(() => {
      globalThis.cmuxExperiments = { ...globalThis.cmuxExperiments, "claude-turn-fold": "runs" };
    });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 1100, theme, reducedMotion: "true", exp: "background-turn-look", arm: "line" })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    // Open "Ran 2 commands", as in Leo's capture, and let its fold and the rows under it settle.
    if (variant === VARIANT)
      await page.locator('[data-row-id="kinds-run"] button.cv-tool', { hasText: "Ran 2 commands" }).first().click();
    await page.evaluate(async () => {
      const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve(undefined)));
      const finite = () =>
        document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      for (let moving = finite(); moving.length > 0; moving = finite())
        await Promise.allSettled(moving.map((animation) => animation.finished));
      await frame();
      await frame();
      await frame();
    });
    await page.mouse.move(0, 0);
    return page;
  };

  type StatusMeasured = {
    gaps: Record<string, number | null>;
    chips: { overText: number; fontDelta: number }[];
    rows: string[];
  };
  /** The status rows of a running turn's bottom (variants working-bottom and reply-received): each
   * row's first text line, found by its kind, and the session chips on them. */
  const measureStatus = (page: Page): Promise<StatusMeasured> =>
    page.evaluate(() => {
      type Line = { top: number; bottom: number };
      const shown = (element: Element) => {
        const box = element.getBoundingClientRect();
        if (box.width === 0 || box.height === 0) return false;
        for (let node: Element | null = element; node; node = node.parentElement) {
          const style = getComputedStyle(node);
          if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
        }
        return true;
      };
      const lines = (scope: Element | null | undefined): Line[] => {
        if (!scope) return [];
        const out: Line[] = [];
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim() || !node.parentElement || !shown(node.parentElement)) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.width === 0 || rect.height === 0) continue;
            const same = out.find((line) => Math.abs((line.top + line.bottom) / 2 - (rect.top + rect.bottom) / 2) < 4);
            if (same) {
              same.top = Math.min(same.top, rect.top);
              same.bottom = Math.max(same.bottom, rect.bottom);
            } else out.push({ top: rect.top, bottom: rect.bottom });
          }
        }
        return out.sort((a, b) => a.top - b.top);
      };
      const rows = [...document.querySelectorAll<HTMLElement>("[data-row-id]")].filter(shown);
      const byText = (pattern: RegExp) => rows.find((row) => pattern.test(row.innerText || ""));
      const byClass = (name: string) => rows.find((row) => row.classList.contains(name));
      const head = (row: Element | undefined) => {
        const first = lines(row)[0];
        return first ? (first.top + first.bottom) / 2 : null;
      };
      const tail = (row: Element | undefined) => {
        const last = lines(row).at(-1);
        return last ? (last.top + last.bottom) / 2 : null;
      };
      const diff = (a: number | null | undefined, b: number | null | undefined) =>
        a == null || b == null ? null : Math.round((b - a) * 100) / 100;
      // A stacked row's first line sits on its own line under the row: the pitch from it to the row under it is one
      // row line plus that line (#34370 measures the closed waiting group this way).
      const below = (row: Element | undefined) => {
        const first = row?.querySelector(".cv-msgline__preview")?.getBoundingClientRect();
        return first && first.height > 0 ? first.height : 0;
      };
      const after = (row: Element | undefined, gap: number | null) =>
        gap == null ? null : Math.round((gap - below(row)) * 100) / 100;
      const live = rows.find(
        (row) => row.classList.contains("acpmux-thinking") || row.classList.contains("acpmux-working"),
      );
      const footer = document
        .querySelector('[data-row-id="received-footer"] .cv-turn-actions button svg')
        ?.getBoundingClientRect();
      const received = document.querySelector('[data-row-id="received-line"]') ?? undefined;
      const bubble = document.querySelector('[data-row-id="sp-prompt"] .cv-user__bubble')?.getBoundingClientRect();
      const sent = byText(/^Sent to/m) ?? document.querySelector('[data-row-id="received-sent"]') ?? undefined;
      const gaps: Record<string, number | null> = {
        // A running turn keeps its work in sight (cmux#38339): its last call's row over the subagent's.
        "work-to-subagent": diff(
          tail(document.querySelector('[data-row-id="status-work"]') ?? undefined),
          head(byClass("acpmux-subagentDone")),
        ),
        "subagent-to-waiting": diff(head(byClass("acpmux-subagentDone")), head(byClass("acpmux-pendingMessages"))),
        // The closed group draws its first line under its head (stacked): the live line is a row under that.
        "waiting-to-live": after(
          byClass("acpmux-pendingMessages"),
          diff(head(byClass("acpmux-pendingMessages")), head(live)),
        ),
        "reply-footer-to-received":
          footer && footer.height > 0 ? diff((footer.top + footer.bottom) / 2, head(received)) : null,
        "received-to-sent": diff(head(received), head(sent)),
        "sent-to-live": diff(head(sent), head(live)),
        "status-to-prompt": diff(head(byClass("acpmux-subagentDone")), bubble?.top),
        "prompt-to-sent": diff(bubble?.bottom, head(document.querySelector('[data-row-id="sp-sent"]') ?? undefined)),
        "note-to-live": diff(head(document.querySelector('[data-row-id="notes-last"]') ?? undefined), head(live)),
      };
      const chips = [...document.querySelectorAll<HTMLElement>(".cv-agent-tag")].filter(shown).map((chip) => {
        const label = lines(chip)[0];
        const box = chip.getBoundingClientRect();
        // The row's own words: a received line's preview, a sent line's verb.
        const row = chip.closest("[data-row-id]") ?? document.body;
        const words = row.querySelector(".cv-received__preview, .cv-agentmsg__words, .cv-agentmsg__preview");
        const size = (element: Element) => parseFloat(getComputedStyle(element).fontSize);
        return {
          overText: label ? Math.round((box.height - (label.bottom - label.top)) * 100) / 100 : 99,
          fontDelta: words ? Math.round((size(chip) - size(words)) * 100) / 100 : 99,
        };
      });
      const list = rows.map((element) => {
        const box = element.getBoundingClientRect();
        const text = (element.innerText || "").replace(/\s+/g, " ").trim().slice(0, 60);
        return `${box.top.toFixed(2)}-${box.bottom.toFixed(2)} ${element.dataset.rowId} ${element.className} | ${text} | lines ${lines(
          element,
        )
          .map((line) => ((line.top + line.bottom) / 2).toFixed(2))
          .join(",")}`;
      });
      return { gaps, chips, rows: list };
    });

  const statusMeasured = new Map<string, StatusMeasured>();
  const statusOf = async (theme: (typeof THEMES)[number], variant: string) => {
    const key = `${theme.file}/${variant}`;
    const known = statusMeasured.get(key);
    if (known) return known;
    const page = await open(theme.name, variant);
    try {
      // An earlier turn's footer shows on hover: point at its reply, as Leo would to read it.
      const reply = page.locator('[data-row-id="received-reply"]');
      if ((await reply.count()) > 0) await reply.hover();
      // Let the footer's reveal and any other finite motion end, then a few frames paint.
      await page.evaluate(async () => {
        const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve(undefined)));
        await frame();
        const finite = () =>
          document
            .getAnimations()
            .filter(
              (animation) =>
                animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
            );
        for (let moving = finite(); moving.length > 0; moving = finite())
          await Promise.allSettled(moving.map((animation) => animation.finished));
        await frame();
        await frame();
      });
      const result = await measureStatus(page);
      if (process.env.FAST_CHECKS_OUT)
        await page.screenshot({ path: path.join(process.env.FAST_CHECKS_OUT, `status-${variant}-${theme.file}.png`) });
      if (LOG)
        console.log(
          `TRANSCRIPT_STATUS_ROWS ${key}\n${result.rows.join("\n")}\n${JSON.stringify({ ...result, rows: undefined })}`,
        );
      statusMeasured.set(key, result);
      return result;
    } finally {
      await page.close();
    }
  };

  const measured = new Map<string, Measured>();
  const of = async (theme: (typeof THEMES)[number]) => {
    const known = measured.get(theme.file);
    if (known) return known;
    const page = await open(theme.name);
    try {
      const result = await measure(page);
      if (LOG)
        console.log(
          `TRANSCRIPT_SPACING_KINDS ${theme.file}\n${result.rows.join("\n")}\n${JSON.stringify({ ...result, rows: undefined })}`,
        );
      measured.set(theme.file, result);
      return result;
    } finally {
      await page.close();
    }
  };

  for (const theme of THEMES) {
    for (const row of TRANSCRIPT_SPACING_KINDS) {
      // Whatever its value, every row must find both marks: a pending row that measured nothing
      // would otherwise pass as its expected failure forever.
      test(`${row.id} finds both its marks (${theme.file})`, async () => {
        expect((await of(theme)).gaps[row.id]).not.toBeNull();
      });
      (row.pending ? test.failing : test)(`${row.id}: ${row.between} is ${row.value}px (${theme.file})`, async () => {
        const got = (await of(theme)).gaps[row.id]!;
        expect(Math.abs(got - row.value)).toBeLessThanOrEqual(row.tolerance);
      });
    }
    for (const row of TRANSCRIPT_STATUS_ROWS) {
      test(`${row.id} finds both its marks (${theme.file})`, async () => {
        expect((await statusOf(theme, row.variant)).gaps[row.id]).not.toBeNull();
      });
      (row.pending ? test.failing : test)(`${row.id}: ${row.between} is ${row.value}px (${theme.file})`, async () => {
        const got = (await statusOf(theme, row.variant)).gaps[row.id]!;
        expect(Math.abs(got - row.value)).toBeLessThanOrEqual(row.tolerance);
      });
    }
    test(`the received and sent lines' session chips are found (${theme.file})`, async () => {
      expect((await statusOf(theme, "reply-received")).chips.length).toBeGreaterThanOrEqual(2);
    });
    (SESSION_CHIP.pending ? test.failing : test)(
      `a session chip is at most ${SESSION_CHIP.overText}px taller than its text, at the row's size (${theme.file})`,
      async () => {
        for (const chip of (await statusOf(theme, "reply-received")).chips) {
          expect(chip.overText).toBeLessThanOrEqual(SESSION_CHIP.overText);
          expect(Math.abs(chip.fontDelta)).toBeLessThanOrEqual(SESSION_CHIP.fontDelta + 0.01);
        }
      },
    );
    test(`an opened run's commands are found (${theme.file})`, async () => {
      expect((await of(theme)).indent).not.toBeNull();
    });
    (RUN_CHILD.pending ? test.failing : test)(
      `an opened run's commands sit ${RUN_CHILD.indent}px in from its head's text (${theme.file})`,
      async () => {
        expect(Math.abs((await of(theme)).indent! - RUN_CHILD.indent)).toBeLessThanOrEqual(RUN_CHILD.tolerance);
      },
    );
  }
});
