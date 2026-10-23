// The Inspector's toggle closes it (inspector/ChatInspector.tsx, inspector.css). Over the chat (the
// overlay placement, the default) the panel used to run the pane's full height, over the chat
// header too: the toggle at the header's end sat under the panel, so a click on it hit a
// section's disclosure button instead and no one could close the Inspector from its toggle. Open,
// the panel starts under the header, the toggle is the topmost element at its own centre, and a
// real mouse click there closes the panel without moving anything left on the page (the misplaced
// click folded the Environment section and Context jumped up under it, 84 px in the gallery, a layout
// shift the gallery graded as failing). With the header's tools in the pane's tab row (the
// `chrome.tabs.rowTools` Debug setting, header/tabRow.ts), the panel starts at that row's foot.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engine); CI fails the file when it
// cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/chat-inspector-overlay-toggle.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Locator, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("chat-inspector-overlay-toggle.test.ts", async () => {
  setDefaultTimeout(300_000);
  // Each engine launches once and stays up for the file: a probe launch closed before a second
  // launch left the second's first page never opening on a loaded Linux host.
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`chat-inspector-overlay-toggle: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("inspector overlay toggle", () => test("browsers", () => {}));
    return;
  }

  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  /// The same chat with its last turn still running: the composer shows Stop.
  let running: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    // The context the harness holds, so the Context section sits under Environment, as in the gallery.
    const usage = { sessionUpdate: "usage_update", used: 52_000, size: 200_000 };
    pane = await papercutPane(() => current!, {
      turns: 4,
      running: false,
      extra: [["in", "usage_update", { method: "session/update", params: { sessionId: "agent-1", update: usage } }]],
    });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
    running = await papercutPane(() => current!, { turns: 4, running: true });
    await (await running.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
    await running?.close();
  });

  /// The tab row the App offers: height 0 is the header's own row.
  const rows = [
    { name: "header", tabRow: 0 },
    { name: "tab row", tabRow: 38 },
  ];

  /// The chat with the Inspector on (Debug Settings `agent.inspector`, pushed with the header
  /// state) and the tab row offered, open in `placement` (over the chat by default: a 1600px pane's
  /// gutter has room for it; a 700px pane's has none, so it pushes) and done entering.
  const openInspector = async (page: Page, tabRow: number, placement: "overlay" | "push" = "overlay") => {
    await page.evaluate((height) => {
      const bridge = (
        window as unknown as {
          cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void; applyTabRow(row: unknown): void };
        }
      ).cmuxAcpmuxBridge;
      bridge.applyTabRow({ height, trailingInset: 0 });
      bridge.applyHeaderState({ inspector: true, version: 2 });
    }, tabRow);
    const panel = page.locator("aside.acpmux-chat-inspector");
    const toggle = page.locator("button.acpmux-chat-inspector-toggle");
    await toggle.waitFor({ timeout: 10_000 });
    if ((await panel.count()) === 0) await toggle.click({ force: true });
    await page.locator(`aside.acpmux-chat-inspector[data-placement="${placement}"][data-presence="shown"]`).waitFor({
      timeout: 10_000,
    });
    return { panel, toggle };
  };

  for (const name of browsers.keys())
    for (const { name: row, tabRow } of rows)
      test(`${name}, ${row}: the toggle is above the open overlay and a click on it closes the Inspector`, async () => {
        current = browsers.get(name)!;
        // Wide enough that the panel floats in the gutter beside the transcript (ChatInspector.tsx pushes).
        const page = await pane!.open({ width: 1600, height: 520 });
        try {
          const { panel, toggle } = await openInspector(page, tabRow);
          expect(await toggle.getAttribute("aria-pressed")).toBe("true");
          const box = (await toggle.boundingBox())!;
          const x = box.x + box.width / 2;
          const y = box.y + box.height / 2;
          const hit = await page.evaluate(
            ([px, py]) => {
              const element = document.elementFromPoint(px!, py!);
              if (element?.closest("button.acpmux-chat-inspector-toggle")) return "the toggle";
              return element ? `${element.tagName.toLowerCase()}.${element.className}` : "nothing";
            },
            [x, y],
          );
          // The panel starts at the header's foot (in the tab row, the row's), not over it.
          const header = (await page.locator("header.acpmux-header").boundingBox())!;
          const top = (await panel.boundingBox())!.y;
          const foot = tabRow > 0 ? tabRow : header.y + header.height;
          // Where the panel's sections and the header sit, to see that the click moved none of them.
          const places = () =>
            page.evaluate(() =>
              Object.fromEntries(
                [...document.querySelectorAll("aside.acpmux-chat-inspector [data-section], header.acpmux-header")].map(
                  (element) => [element.getAttribute("data-section") ?? "header", element.getBoundingClientRect().y],
                ),
              ),
            );
          const before = await places();
          await page.mouse.click(x, y);
          const closed = await panel
            .waitFor({ state: "detached", timeout: 5_000 })
            .then(() => true)
            .catch(() => false);
          const after = await places();
          // How far the click moved what it left on the page, in px (the misplaced click folded
          // Environment and Context jumped up).
          const moved = Math.max(
            0,
            ...Object.entries(after).map(([name, y]) => (name in before ? Math.abs(y - before[name]!) : 0)),
          );
          expect({
            hit,
            atFoot: Math.abs(top - foot) < 0.5,
            closed,
            pressed: await toggle.getAttribute("aria-pressed"),
            moved,
          }).toEqual({ hit: "the toggle", atFoot: true, closed: true, pressed: "false", moved: 0 });
        } finally {
          await page.close();
        }
      });

  // Leo, 2026-10-22: "THIS BECAME A SIDEBAR FOR NO REASON, ALL THIS DEAD SPACE". Over the chat the
  // Inspector ran from under the header to the pane's foot (#22643), and as glass (#23477) its
  // empty foot was a slab of glass taller than its sections. It is a card as tall as its sections:
  // in a tall pane its foot is its last section's (plus the body's padding), never the pane's; in a
  // short one it stops above the pane's foot and its body scrolls.
  for (const name of browsers.keys())
    test(`${name}: over the chat the Inspector is as tall as its sections, and scrolls when they are taller`, async () => {
      current = browsers.get(name)!;
      const measure = (page: Page) =>
        page.evaluate(() => {
          const panel = document.querySelector("aside.acpmux-chat-inspector")!;
          const body = panel.querySelector(".acpmux-chat-inspector__body")!;
          const sections = [...panel.querySelectorAll("[data-section]")];
          const last = sections[sections.length - 1]!.getBoundingClientRect();
          const box = panel.getBoundingClientRect();
          return {
            empty: Math.round(box.bottom - last.bottom),
            bottom: box.bottom,
            pane: window.innerHeight,
            scrolls: body.scrollHeight > body.clientHeight + 1,
          };
        });
      const tall = await pane!.open({ width: 1600, height: 1400 });
      try {
        await openInspector(tall, 0);
        const { empty, bottom, pane: height } = await measure(tall);
        expect({ deadSpace: empty <= 16, short: bottom < height - 200 }).toEqual({ deadSpace: true, short: true });
      } finally {
        await tall.close();
      }
      // The harness's sections are about 160px tall: a 160px pane leaves them about 110.
      const short = await pane!.open({ width: 1600, height: 160 });
      try {
        await openInspector(short, 0);
        const { bottom, pane: height, scrolls } = await measure(short);
        expect({ inside: bottom <= height - 8 + 0.5, scrolls }).toEqual({ inside: true, scrolls: true });
      } finally {
        await short.close();
      }
    });

  // claude-sr2, 2026-10-22 (relaying Leo): over the in-pane diff the Inspector was "again a full-height
  // column". It was the same card, but a busy chat's sections (Tasks 175, Subagents +94) are taller
  // than any pane, so the card always reached the pane's foot. However tall its sections, the card
  // stops at a ceiling (at most 560px, and never more than 80% of the room under the header) and
  // its body scrolls: it never reads as a column, over the chat or over a diff. Pushing the chat
  // aside (a 700px pane), it is the same card: its column below the card is the chat's page.
  for (const name of browsers.keys())
    test(`${name}: floating or pushing, the Inspector never runs the pane's height, however tall its sections`, async () => {
      current = browsers.get(name)!;
      for (const [width, placement] of [
        [1600, "overlay"],
        [700, "push"],
      ] as const)
        for (const height of [1400, 800, 420]) {
          const page = await pane!.open({ width, height });
          try {
            const { panel } = await openInspector(page, 0, placement);
            // A busy chat: every section taller than the pane.
            await page.addStyleTag({ content: "aside.acpmux-chat-inspector [data-section] { min-height: 1600px; }" });
            const { top, bottom, scrolls } = await panel.evaluate((node) => {
              const box = node.getBoundingClientRect();
              const body = node.querySelector(".acpmux-chat-inspector__body")!;
              return { top: box.top, bottom: box.bottom, scrolls: body.scrollHeight > body.clientHeight + 1 };
            });
            const room = height - top;
            expect({ width, height, short: bottom - top <= Math.min(560, room * 0.8) + 0.5, scrolls }).toEqual({
              width,
              height,
              short: true,
              scrolls: true,
            });
          } finally {
            await page.close();
          }
        }
    });

  // Leo, 2026-10-22: "the card should just end when there's no more content to show". The ceiling
  // (560px, 80% of the room under the header) is only a maximum: below it the card's height is its
  // content's, the same in a tall pane as in a short one, floating or pushing, with nothing under its
  // last section but the body's own padding, and its body does not scroll. Folding a section shrinks
  // the card with it, so no fixed or minimum height holds it open either.
  /// The card's height, the room under its last block of sections (ChatInspector.tsx RAIL_LAYOUT; not
  /// the `data-section` blocks inside them) and the body's bottom padding.
  const fit = (panel: Locator) =>
    panel.evaluate((node) => {
      const box = node.getBoundingClientRect();
      const body = node.querySelector(".acpmux-chat-inspector__body")!;
      const sections = [...body.querySelectorAll(":scope > .acpmux-chat-inspector-group")];
      const last = sections[sections.length - 1]!.getBoundingClientRect();
      return {
        top: box.top,
        card: box.height,
        endsAtContent: Math.abs(box.bottom - last.bottom - parseFloat(getComputedStyle(body).paddingBottom)) < 0.5,
        scrolls: body.scrollHeight > body.clientHeight + 1,
      };
    });
  for (const name of browsers.keys())
    test(`${name}: floating or pushing, a card with little to show ends right after its last section, in any pane`, async () => {
      current = browsers.get(name)!;
      for (const [width, placement] of [
        [1600, "overlay"],
        [700, "push"],
      ] as const) {
        const cards: ({ height: number } & Awaited<ReturnType<typeof fit>>)[] = [];
        let folded: { shrank: boolean; endsAtContent: boolean; scrolls: boolean } | undefined;
        for (const height of [1400, 800, 520]) {
          const page = await pane!.open({ width, height });
          try {
            const { panel } = await openInspector(page, 0, placement);
            const open = await fit(panel);
            cards.push({ height, ...open });
            if (height !== 520) continue;
            // Open Context, then fold it: the card ends at its sections again, shorter by just its rows.
            const context = panel.locator('section[data-section="context"]');
            const frame = () =>
              page.evaluate(
                () => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))),
              );
            await context.locator(".ui-disclosure-trigger").click();
            const rows = context.locator(".ui-disclosure-panel");
            await rows.waitFor({ timeout: 5_000 });
            await frame();
            const unfolded = await fit(panel);
            const fold = await rows.evaluate((node) => node.getBoundingClientRect().height);
            await context.locator(".ui-disclosure-trigger").click();
            await rows.waitFor({ state: "detached", timeout: 5_000 });
            await frame();
            const after = await fit(panel);
            folded = {
              shrank: fold > 0 && Math.abs(unfolded.card - after.card - fold) < 0.5,
              endsAtContent: after.endsAtContent,
              scrolls: after.scrolls,
            };
          } finally {
            await page.close();
          }
        }
        // The harness's sections are about 200px tall: well under the ceiling in every one of these panes.
        const [first] = cards;
        expect({
          cards: cards.map(({ height, top, card, endsAtContent, scrolls }) => ({
            placement,
            height,
            belowCeiling: card < Math.min(560, (height - top) * 0.8),
            sameAsTallestPane: Math.abs(card - first!.card) < 0.5,
            endsAtContent,
            scrolls,
          })),
          folded,
        }).toEqual({
          cards: cards.map(({ height }) => ({
            placement,
            height,
            belowCeiling: true,
            sameAsTallestPane: true,
            endsAtContent: true,
            scrolls: false,
          })),
          folded: { shrank: true, endsAtContent: true, scrolls: false },
        });
      }
    });

  // Leo, 2026-10-22: "WHY DOES IT STAY ON IN THESE RANDOM SITUATIONS WITHOUT BEING CLOSABLE!?" Over a
  // diff in place the chat header (with the toggle) is hidden, so the panel carries its own close
  // button, and Esc closes it while the keyboard is in it (not in a text field there).
  /// Two painted frames: an Esc that closes the panel has drawn by then.
  const frames = (page: Page) =>
    page.evaluate(() => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))));
  for (const name of browsers.keys())
    test(`${name}: the Inspector's own close button and Esc close it; Esc in the composer or on a popover leaves it open`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 1600, height: 620 });
      try {
        const { panel, toggle } = await openInspector(page, 0);
        // As over a diff in place: the header, and the toggle with it, out of reach.
        await page.addStyleTag({ content: "header.acpmux-header { visibility: hidden; }" });
        const close = page.locator("aside.acpmux-chat-inspector button.acpmux-chat-inspector__close");
        await close.click({ timeout: 5_000 });
        const byButton = await panel.waitFor({ state: "detached", timeout: 5_000 }).then(
          () => true,
          () => false,
        );
        // The header is hidden: the toggle opens it again through the DOM.
        await toggle.evaluate((button: HTMLElement) => button.click());
        await panel.waitFor({ timeout: 5_000 });
        await page.locator("textarea, [contenteditable=true]").first().focus();
        await page.keyboard.press("Escape");
        await frames(page);
        // Still open, not leaving (a leaving panel stays drawn while it slides out).
        const keptInComposer = (await toggle.getAttribute("aria-pressed")) === "true";
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        // An open popover takes Esc first: the Inspector stays.
        await page.evaluate(() => {
          const popover = document.createElement("dialog");
          popover.open = true;
          popover.className = "ui-popup";
          popover.innerHTML = "<button>Item</button>";
          // Inside the panel, where Esc would otherwise close it.
          document.querySelector("aside.acpmux-chat-inspector")!.append(popover);
          popover.querySelector("button")!.focus();
        });
        await page.keyboard.press("Escape");
        await frames(page);
        // Still open, not leaving (a leaving panel stays drawn while it slides out).
        const keptUnderPopover = (await toggle.getAttribute("aria-pressed")) === "true";
        await page.evaluate(() => document.querySelector("dialog.ui-popup")!.remove());
        await close.focus();
        await page.keyboard.press("Escape");
        const byEscape = await panel.waitFor({ state: "detached", timeout: 5_000 }).then(
          () => true,
          () => false,
        );
        expect({ byButton, keptInComposer, keptUnderPopover, byEscape }).toEqual({
          byButton: true,
          keptInComposer: true,
          keptUnderPopover: true,
          byEscape: true,
        });
      } finally {
        await page.close();
      }
    });

  // Follow-up to #24126: Esc closed the Inspector from anywhere, so with a turn running and nothing
  // focused the first Esc closed the panel instead of arming the composer's double press that stops
  // the turn (escapeStop.ts). Esc closes the Inspector only while the keyboard is in it or on its
  // toggle; elsewhere Esc keeps its meaning. A close by Esc or by the x gives the keyboard to the toggle.
  const onToggle = (page: Page) =>
    page.evaluate(() => document.activeElement?.matches("button.acpmux-chat-inspector-toggle") ?? false);
  /// Whether the daemon heard `method` after the first `from` calls, within about a second of frames.
  const heard = async (page: Page, from: number, method: string) => {
    for (let tries = 0; tries < 60; tries++) {
      if (running!.methods.slice(from).includes(method)) return true;
      await frames(page);
    }
    return false;
  };
  for (const name of browsers.keys())
    test(`${name}: with nothing focused and a turn running, Esc arms and then stops the turn, and the Inspector stays open`, async () => {
      current = browsers.get(name)!;
      const page = await running!.open({ width: 1600, height: 620 });
      try {
        const { panel, toggle } = await openInspector(page, 0);
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        await page.getByRole("button", { name: "Stop", exact: true }).waitFor({ timeout: 5_000 });
        const sent = running!.methods.length;
        await page.keyboard.press("Escape");
        const armed = await page
          .getByRole("button", { name: "Press Esc again to stop" })
          .waitFor({ timeout: 2_000 })
          .then(
            () => true,
            () => false,
          );
        await frames(page);
        const openAfterFirst = (await toggle.getAttribute("aria-pressed")) === "true";
        await page.keyboard.press("Escape");
        const stopped = await heard(page, sent, "session/cancel");
        const openAfterStop = (await toggle.getAttribute("aria-pressed")) === "true" && (await panel.count()) === 1;
        expect({ armed, openAfterFirst, stopped, openAfterStop }).toEqual({
          armed: true,
          openAfterFirst: true,
          stopped: true,
          openAfterStop: true,
        });
      } finally {
        await page.close();
      }
    });

  for (const name of browsers.keys())
    test(`${name}: Esc with the keyboard in the Inspector or on its toggle closes it and gives the keyboard to the toggle`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 1600, height: 620 });
      try {
        const { panel, toggle } = await openInspector(page, 0);
        await page.locator("aside.acpmux-chat-inspector [data-section] button").first().focus();
        await page.keyboard.press("Escape");
        const fromPanel = await panel.waitFor({ state: "detached", timeout: 5_000 }).then(
          () => true,
          () => false,
        );
        const focusFromPanel = await onToggle(page);
        await toggle.click();
        await panel.waitFor({ timeout: 5_000 });
        await toggle.focus();
        await page.keyboard.press("Escape");
        const fromToggle = await panel.waitFor({ state: "detached", timeout: 5_000 }).then(
          () => true,
          () => false,
        );
        expect({ fromPanel, focusFromPanel, fromToggle, focusFromToggle: await onToggle(page) }).toEqual({
          fromPanel: true,
          focusFromPanel: true,
          fromToggle: true,
          focusFromToggle: true,
        });
      } finally {
        await page.close();
      }
    });

  for (const name of browsers.keys())
    test(`${name}: the Inspector's x closes it and gives the keyboard to the toggle`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 1600, height: 620 });
      try {
        const { panel } = await openInspector(page, 0);
        await page.locator("aside.acpmux-chat-inspector button.acpmux-chat-inspector__close").click({ timeout: 5_000 });
        const closed = await panel.waitFor({ state: "detached", timeout: 5_000 }).then(
          () => true,
          () => false,
        );
        expect({ closed, focus: await onToggle(page) }).toEqual({ closed: true, focus: true });
      } finally {
        await page.close();
      }
    });
});
