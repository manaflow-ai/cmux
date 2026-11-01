// cmux-web-test-timeout: 300
// The composer's controls row and footer (hq#1957 item 15). Leo saw a huge empty gap between
// Effort and the permission chip while the model and effort chips truncated ("Claude Opu…",
// "Med…"), and the folder footer cut at the card's bottom edge. In the gallery's
// `agent-pane.composer-row` entry at a narrow, a normal and a wide pane:
//   - the controls are two clusters: + model access on the left, mic and Send (or Stop) on the
//     right; the row's free space sits only between the two;
//   - the effort is the model button's own label, "Opus 5.5  Medium" (Leo 2026-10-20), never a
//     chip of its own, and it is never cut either;
//   - the row is compact and calm (hq#1957 item 15 compact row): the left cluster's controls sit
//     4 to 12 px apart (composer-row-rhythm.test.ts: one gap per group); no ring or spinner; one lock at
//     most; no granted-permission status chip; Stop has Send's footprint and a square glyph of 9
//     to 12 px, centred in it: a plain glyph in the secondary text color (--agent-muted), with no
//     disc (Leo 2026-10-21);
//   - no label is ever cut: a short row swaps whole units instead (a short label, a glyph alone),
//     in composerRowFit.ts's order, which composer-row-steps.test.ts plays;
//   - these chats have started, so no location strip heads the card (a new chat's strip is
//     composer-location-strip.test.ts's).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Rect = { left: number; right: number; top: number; bottom: number; width: number };
type Row = {
  bar: Rect;
  box: Rect;
  footer: Rect | null;
  /** Left cluster controls in order, with the free space after the last one. */
  left: { name: string; rect: Rect }[];
  right: Rect;
  barGap: number;
  /** Each label: cut (an ellipsis or a label pushed out of its chip) or whole. */
  labels: Record<string, { cut: boolean; dropped: boolean; atMin: boolean; need: number } | undefined>;
  /** Rings and spinners in the row (the context ring was one). */
  spinners: string[];
  /** Lock icons drawn in the row. */
  locks: number;
  /** Whether the granted-permission status chip sits in the row. */
  status: boolean;
  /** Whether an effort chip of its own is drawn anywhere (none since Leo 2026-10-20). */
  effortChip: boolean;
  /** Send or Stop, whichever shows, and Stop's glyph. */
  send: Rect | undefined;
  stop: Rect | undefined;
  stopGlyph: Rect | undefined;
  /** The trailing cluster's controls, left to right by position (mic, then Send or Stop). */
  trailing: string[];
  /** Send's or Stop's fill and ink, whichever shows; empty when neither does. */
  fill: string;
  ink: string;
  /** The theme's --agent-text and --acpmux-base, resolved in the bar. */
  text: string;
  base: string;
  /** The pane's secondary text color (--agent-muted), resolved in the bar: the ink of the mic, Send and Stop. */
  muted: string;
};

await requireBrowserLane("composer-row-layout.test.ts", async () => {
  /** Runs in the page: the row's geometry. */
  function measure(): Row {
    const rect = (element: Element): Rect => {
      const { left, right, top, bottom, width } = element.getBoundingClientRect();
      return { left, right, top, bottom, width };
    };
    const visible = (element: Element | null): element is HTMLElement =>
      element instanceof HTMLElement && element.getBoundingClientRect().width > 0;
    const bar = document.querySelector(".acpmux-composer-bar")!;
    const box = document.querySelector(".acpmux-composer-box")!;
    const footer = document.querySelector(".acpmux-composer-strip");
    const named: [string, string][] = [
      ["plus", ".acpmux-composer-plus .acpmux-picker-button"],
      ["model", ".acpmux-model .acpmux-picker-button"],
      ["access", ".acpmux-access-trigger"],
      ["plan", ".acpmux-plan"],
    ];
    const left = named.flatMap(([name, selector]) => {
      const element = bar.querySelector(selector);
      return visible(element) ? [{ name, rect: rect(element) }] : [];
    });
    left.sort((a, b) => a.rect.left - b.rect.left);
    // A label is cut when its text overflows its box, or when it is laid out outside its chip
    // (wrapped away) or not drawn while the chip still is.
    const label = (chip: string, text: string, item: string) => {
      const button = bar.querySelector(chip);
      if (!visible(button)) return undefined;
      const span = button.querySelector(text);
      const shown =
        span instanceof HTMLElement &&
        span.getClientRects().length > 0 &&
        getComputedStyle(span).visibility === "visible";
      const inside =
        shown &&
        span.getBoundingClientRect().top >= button.getBoundingClientRect().top - 0.5 &&
        span.getBoundingClientRect().bottom <= button.getBoundingClientRect().bottom + 0.5 &&
        span.getBoundingClientRect().width > 0;
      const overflow = shown && span.scrollWidth > span.clientWidth + 0.5;
      const host = bar.querySelector(item) ?? button;
      const min = parseFloat(getComputedStyle(host).minWidth) || 0;
      // The width the whole label would take back: an ellipsis's overflow, or a label dropped
      // for its icon with the gap beside it.
      const need = !shown
        ? (span instanceof HTMLElement ? span.getBoundingClientRect().width : 0) +
          (parseFloat(getComputedStyle(button).columnGap) || 0)
        : overflow
          ? span.scrollWidth - span.clientWidth
          : 0;
      return { cut: !inside || overflow, dropped: !shown, atMin: host.getBoundingClientRect().width <= min + 1, need };
    };
    return {
      bar: rect(bar),
      box: rect(box),
      footer: footer && rect(footer),
      left,
      right: rect(bar.querySelector(".acpmux-composer-actions")!),
      trailing: [...bar.querySelectorAll<HTMLElement>(".acpmux-composer-actions button")]
        .filter(visible)
        .sort((a, b) => a.getBoundingClientRect().left - b.getBoundingClientRect().left)
        .map((button) =>
          button.classList.contains("acpmux-mic")
            ? "mic"
            : button.classList.contains("acpmux-cancel")
              ? "stop"
              : button.classList.contains("acpmux-send")
                ? "send"
                : button.className,
        ),
      barGap: parseFloat(getComputedStyle(bar).columnGap) || 0,
      labels: {
        model: label(
          ".acpmux-model .acpmux-picker-button",
          '[data-fit-part="model"][data-fit-forms~="full"], .acpmux-model-name:not([data-short])',
          ".acpmux-model",
        ),
        effort: label(
          ".acpmux-model .acpmux-picker-button",
          '.acpmux-model-detail[data-fit-forms~="full"]:not(.acpmux-fit-label)',
          ".acpmux-model",
        ),
        access: label(".acpmux-access-trigger", ".acpmux-mode-text", ".acpmux-access"),
      },
      spinners: [
        ...bar.querySelectorAll(
          '.acpmux-context, .acpmux-context-ring, [role="progressbar"], [class*="spinner"], [class*="-ring"]',
        ),
      ].map((element) => element.className.toString() || element.tagName),
      // LockIcon (ComposerPickers.tsx): its shackle path.
      locks: bar.querySelectorAll('svg path[d^="M5.5 7V5.6"]').length,
      status: bar.querySelector(".acpmux-permission-status") !== null,
      effortChip: document.querySelector(".acpmux-effort") !== null,
      send: bar.querySelector(".acpmux-send:not(.acpmux-cancel)")
        ? rect(bar.querySelector(".acpmux-send:not(.acpmux-cancel)")!)
        : undefined,
      stop: bar.querySelector(".acpmux-cancel") ? rect(bar.querySelector(".acpmux-cancel")!) : undefined,
      stopGlyph: bar.querySelector(".acpmux-cancel svg rect")
        ? rect(bar.querySelector(".acpmux-cancel svg rect")!)
        : undefined,
      // Claude desktop's box: no Send until there is a draft (Leo 2026-10-20), so an idle row may have neither.
      fill: (() => {
        const shown = bar.querySelector(".acpmux-send");
        return shown ? getComputedStyle(shown).backgroundColor : "";
      })(),
      ink: (() => {
        const shown = bar.querySelector(".acpmux-send");
        return shown ? getComputedStyle(shown).color : "";
      })(),
      ...(() => {
        const probe = document.createElement("span");
        probe.style.color = "var(--agent-text)";
        probe.style.backgroundColor = "var(--acpmux-base)";
        bar.appendChild(probe);
        const { color, backgroundColor } = getComputedStyle(probe);
        // The pane's secondary text color, the ink of the mic, Send and Stop.
        probe.style.color = "var(--agent-muted)";
        const muted = getComputedStyle(probe).color;
        probe.remove();
        return { text: color, base: backgroundColor, muted };
      })(),
    };
  }

  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-row-layout: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer row layout", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.composer-row", { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the stage once: the first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, "agent-pane.composer-row", { browser, params: { variant: "claude-auto" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** The row's geometry; `draft` is typed first, so an idle row draws its Send. */
  const row = async (variant: string, width: number, draft?: string) => {
    const page = await browser!.newPage({ viewport: { width, height: 300 } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-model .acpmux-model-detail:visible").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    if (draft) {
      await page.locator(".acpmux-composer-prompt [contenteditable]").click();
      await page.keyboard.type(draft);
      await page.locator(".acpmux-composer-bar .acpmux-send:not(.acpmux-cancel)").waitFor();
    }
    const measured = await page.evaluate(measure);
    await page.close();
    return measured;
  };

  for (const variant of ["claude-auto", "long-model", "granted", "queued"])
    for (const width of [420, 720, 1100])
      test(`${variant} at ${width} px: two clusters, no cut label, no location strip`, async () => {
        const measured = await row(variant, width);
        const { left, right, labels, barGap } = measured;
        const names = left.map((control) => control.name);
        const problems: string[] = [];
        // The left cluster is contiguous: no control sits apart from the one before it.
        for (let index = 1; index < left.length; index++) {
          const gap = left[index]!.rect.left - left[index - 1]!.rect.right;
          if (gap > barGap + 0.5)
            problems.push(`${Math.round(gap)} px gap between ${names[index - 1]} and ${names[index]}`);
        }
        // The effort rides the model button: no control of its own (Leo 2026-10-20).
        if (measured.effortChip) problems.push("an effort chip of its own is drawn");
        // The row's free space sits between the clusters: the trailing one starts after the left ends.
        if (right.left < left.at(-1)!.rect.right + barGap - 0.5)
          problems.push(
            `the trailing cluster overlaps the chips by ${Math.round(left.at(-1)!.rect.right + barGap - right.left)} px`,
          );
        // A drawn label is never cut (an ellipsis, or laid out outside its chip); a label swapped
        // for its short form or glyph is a step of the row (composer-row-steps.test.ts).
        const cut = Object.entries(labels).flatMap(([name, label]) => (label?.cut && !label.dropped ? [name] : []));
        for (const name of cut) problems.push(`${name} cut at ${width} px`);
        // At a normal and a wide pane every label of Leo's row shows whole, in full.
        const dropped = Object.entries(labels).flatMap(([name, label]) => (label?.dropped ? [name] : []));
        if (width >= 720 && variant !== "long-model" && dropped.length > 0)
          problems.push(`${dropped.join(", ")} not in full at ${width} px`);
        // A started chat cannot change its folder or machine: no location strip heads the card.
        if (measured.footer) problems.push("a started chat draws the location strip");
        expect(problems).toEqual([]);
      });

  for (const variant of ["claude-auto", "long-model", "granted", "queued"])
    for (const width of [420, 720, 1100])
      test(`${variant} at ${width} px: a compact, calm row`, async () => {
        const measured = await row(variant, width);
        const problems: string[] = [];
        // The left cluster's spacing (one gap inside a group, one between groups) is
        // composer-row-rhythm.test.ts's; here no two of its controls touch or sit far apart.
        for (const [index, control] of measured.left.slice(1).entries()) {
          const gap = control.rect.left - measured.left[index]!.rect.right;
          if (gap < 3.5 || gap > 12.5)
            problems.push(`${measured.left[index]!.name}-${control.name} ${gap.toFixed(1)} px apart`);
        }
        if (measured.spinners.length > 0)
          problems.push(`a ring or spinner in the row: ${measured.spinners.join(", ")}`);
        if (measured.locks > 1) problems.push(`${measured.locks} locks in the row`);
        if (measured.status) problems.push("the granted-permission status chip is in the row");
        if (measured.stopGlyph) {
          const { width: w, bottom, top } = measured.stopGlyph;
          if (Math.abs(w - (bottom - top)) > 0.5 || w < 9 || w > 12)
            problems.push(`Stop's glyph is ${w.toFixed(1)} x ${(bottom - top).toFixed(1)} px`);
        }
        expect(problems).toEqual([]);
      });

  // A short pane with a queued prompt (re-review of #22285): the queue's last row, the card and the
  // split's quiet row (28 px and its 4 px gap) under it all stay inside the pane. The transcript
  // gives up room for the quiet row, down to 64 px above the stack.
  for (const height of [300, 285])
    test(`queued in a ${height} px pane: the quiet row stays inside the pane`, async () => {
      const page = await browser!.newPage({ viewport: { width: 720, height } });
      await page.goto(stageURL("queued"));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator(".acpmux-composer-foot .acpmux-model .acpmux-model-detail:visible").first().waitFor();
      const drawn = await page.evaluate(() => {
        const rect = (selector: string) => document.querySelector(selector)?.getBoundingClientRect();
        const main = rect(".acpmux-main")!;
        const foot = rect(".acpmux-composer-foot")!;
        const box = rect(".acpmux-composer-box")!;
        const queue = rect(".acpmux-composer-queue");
        const transcript = rect(".acpmux-main .acpmux-scroll")!;
        const stack = rect(".acpmux-main > .acpmux-dock")!;
        return {
          footInside: foot.bottom <= main.bottom + 0.5,
          footUnderBox: foot.top >= box.bottom - 0.5,
          queueAboveBox: !queue || queue.bottom <= box.top + 0.5,
          transcriptRoom: Math.round(stack.top - transcript.top),
          footBottom: Math.round(foot.bottom),
          paneBottom: Math.round(main.bottom),
        };
      });
      await page.close();
      console.log(`queued at ${height} px`, JSON.stringify(drawn));
      expect({
        footInside: drawn.footInside,
        footUnderBox: drawn.footUnderBox,
        queueAboveBox: drawn.queueAboveBox,
      }).toEqual({
        footInside: true,
        footUnderBox: true,
        queueAboveBox: true,
      });
      // The transcript keeps a row's worth above the stack.
      expect(drawn.transcriptRoom).toBeGreaterThanOrEqual(64);
    });

  // Leo 2026-10-21: "WE HAVE TOO MUCH FUCKING STUPID SPACE AT THE BOTTOM COMPAREDE TO CLAUDE CODE".
  // Claude Code leaves about 8 px under its quiet row; the row's own 10 px margin is the room under
  // it (Leo 2026-10-20: never on the window's edge), with no composer padding added below that.
  for (const variant of ["claude-auto", "queued"])
    test(`${variant}: the quiet row sits about 10 px over the pane's bottom edge`, async () => {
      const page = await browser!.newPage({ viewport: { width: 720, height: 600 } });
      await page.goto(stageURL(variant));
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator(".acpmux-composer-foot .acpmux-model .acpmux-model-detail:visible").first().waitFor();
      const under = await page.evaluate(() => {
        const main = document.querySelector(".acpmux-main")!.getBoundingClientRect();
        const foot = document.querySelector(".acpmux-composer-foot")!.getBoundingClientRect();
        return Math.round(main.bottom - foot.bottom);
      });
      await page.close();
      expect(under).toBeGreaterThanOrEqual(6);
      expect(under).toBeLessThanOrEqual(12);
    });

  // Only the floating chat dock drops it: a fresh chat's hero layout (no data-dock) keeps the
  // composer's own 16 px bottom padding.
  test("a dock that does not float keeps the composer's bottom padding", async () => {
    const page = await browser!.newPage({ viewport: { width: 720, height: 600 } });
    await page.goto(stageURL("claude-auto"));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-composer-foot .acpmux-model .acpmux-model-detail:visible").first().waitFor();
    const padding = await page.evaluate(() => {
      const composer = () => getComputedStyle(document.querySelector(".acpmux-dock > .acpmux-composer")!);
      const floating = composer().paddingBottom;
      document.querySelector(".acpmux-main")!.removeAttribute("data-dock");
      return { floating, fresh: composer().paddingBottom };
    });
    await page.close();
    expect(padding).toEqual({ floating: "0px", fresh: "16px" });
  });

  for (const width of [420, 720, 1100])
    test(`at ${width} px Stop takes Send's slot as a plain glyph in the secondary text color`, async () => {
      // One send control (Leo 2026-10-31: "THE F***ING TWO SEND BUTTONS"): no Send until there is
      // a draft, so the idle row Stop is held against has a prompt typed; there Send comes before
      // the mic, which keeps the right edge (Claude desktop's ↵). While a turn runs with an empty
      // prompt, Stop stands in that same slot.
      const idle = await row("claude-auto", width, "Add a test for the 429 path");
      const running = await row("queued", width);
      const send = idle.send!;
      const stop = running.stop!;
      expect(stop).toBeDefined();
      const off = (["width", "left", "top", "bottom"] as const).filter(
        (side) => Math.abs(send[side] - stop[side]) > 0.5,
      );
      expect(off.map((side) => `${side} ${send[side].toFixed(1)} -> ${stop[side].toFixed(1)}`)).toEqual([]);
      expect(idle.trailing.slice(-2)).toEqual(["send", "mic"]);
      expect(running.trailing.slice(-2)).toEqual(["stop", "mic"]);
      // A plain glyph, as the mic is (Leo 2026-10-21: "no solid discs"; then the secondary text
      // color, only a hover background): no fill, the square in the secondary text color, a step
      // above an empty draft's 45% Send.
      expect(running.fill).toBe("rgba(0, 0, 0, 0)");
      expect(running.muted).not.toBe(running.text);
      expect(running.ink).toBe(running.muted);
      // The square sits in Stop's centre.
      const glyph = running.stopGlyph!;
      const centre = (low: number, high: number) => (low + high) / 2;
      expect(Math.abs(centre(glyph.left, glyph.right) - centre(stop.left, stop.right))).toBeLessThanOrEqual(0.5);
      expect(Math.abs(centre(glyph.top, glyph.bottom) - centre(stop.top, stop.bottom))).toBeLessThanOrEqual(0.5);
    });
});
