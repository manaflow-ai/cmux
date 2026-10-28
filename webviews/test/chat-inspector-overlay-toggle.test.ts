// cmux-web-test-timeout: 240
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
import { inspectorPushAlways, papercutPane } from "./support/papercutChat";

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
  /// state) and the tab row offered, open in `placement` (floating by default; pushing with Settings
  /// Push always) and done entering.
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
    if (placement === "push") await inspectorPushAlways(page);
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

  for (const name of browsers.keys())
    for (const { name: row, tabRow } of rows)
      test(`${name}, ${row}: Push always keeps every header tool in the native reserved strip`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width: 900, height: 640 });
        try {
          const { panel, toggle } = await openInspector(page, tabRow);
          await toggle.click();
          await panel.waitFor({ state: "detached" });
          await inspectorPushAlways(page);
          const positions = () =>
            page.locator(".acpmux-header-tools button").evaluateAll((buttons) =>
              buttons.map((button) => {
                const box = button.getBoundingClientRect();
                return { label: button.getAttribute("aria-label"), x: box.x, y: box.y, width: box.width };
              }),
            );
          const closed = await positions();
          await toggle.click();
          await page.locator('aside.acpmux-chat-inspector[data-placement="push"][data-presence="shown"]').waitFor();
          expect(await positions()).toEqual(closed);
          // Native tabs cover everything left of this reserved strip. A real click at the old
          // position must still reach the toggle after opening, including after a pane resize.
          await page.setViewportSize({ width: 1050, height: 640 });
          await page.waitForFunction(
            (x) =>
              Math.abs(document.querySelector(".acpmux-chat-inspector-toggle")!.getBoundingClientRect().x - x) < 0.5,
            closed[0]!.x + 150,
          );
          const opened = await positions();
          await page.mouse.click(opened[0]!.x + 12, opened[0]!.y + 12);
          await panel.waitFor({ state: "detached" });
          expect(await positions()).toEqual(opened);
          expect(await toggle.getAttribute("aria-pressed")).toBe("false");
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
            top: box.top,
            height: box.height,
            bottom: box.bottom,
            pane: window.innerHeight,
            scrolls: body.scrollHeight > body.clientHeight + 1,
          };
        });
      const tall = await pane!.open({ width: 1600, height: 1400 });
      // The card's own height and top in the tall pane: its sections at rest, unclipped.
      let natural = { top: 0, height: 0 };
      try {
        await openInspector(tall, 0);
        const { empty, bottom, pane: height, top, height: card } = await measure(tall);
        natural = { top, height: card };
        expect({ deadSpace: empty <= 16, short: bottom < height - 200 }).toEqual({ deadSpace: true, short: true });
      } finally {
        await tall.close();
      }
      // A pane 40px too short for the card (with its 8px inset at the foot), so its sections must
      // scroll. Derived from the harness's sections, not a fixed height: Environment became one
      // project row (#26199) and the sections shrank from about 160px to about 100.
      const short = await pane!.open({ width: 1600, height: Math.floor(natural.top + natural.height + 8 - 40) });
      try {
        await openInspector(short, 0);
        const { bottom, pane: height, scrolls } = await measure(short);
        expect({ inside: bottom <= height - 8 + 0.5, scrolls }).toEqual({ inside: true, scrolls: true });
      } finally {
        await short.close();
      }
    });

  // Leo, 2026-10-26: "you still haven't done the full-length thing. It's still just this constrained
  // height for, like, no reason at all." A busy chat's card uses all the room under the header, less
  // its inset at the foot, and only then does its body scroll: no 560px or 80% cap with room left. It is
  // still a floating card (its own inset at the foot, never the pane's edge), over the chat or pushing.
  for (const name of browsers.keys())
    test(`${name}: floating or pushing, a busy Inspector uses the full room under the header, then scrolls`, async () => {
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
            const { bottom, scrolls } = await panel.evaluate((node) => {
              const box = node.getBoundingClientRect();
              const body = node.querySelector(".acpmux-chat-inspector__body")!;
              return { top: box.top, bottom: box.bottom, scrolls: body.scrollHeight > body.clientHeight + 1 };
            });
            // The card's inset at the foot (inspector.css --acpmux-inspector-inset).
            const inset = 8;
            expect({ width, height, foot: Math.round(height - inset - bottom), scrolls }).toEqual({
              width,
              height,
              foot: 0,
              scrolls: true,
            });
          } finally {
            await page.close();
          }
        }
    });

  // Leo, 2026-10-22: "the card should just end when there's no more content to show". The ceiling
  // (the room under the header less its inset) is only a maximum: below it the card's height is its
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
            belowCeiling: card < height - top - 8,
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

  // Leo, 2026-10-22: "WHY DOES IT STAY ON IN THESE RANDOM SITUATIONS WITHOUT BEING CLOSABLE!?" Its
  // toggle closes it, and so does Esc while the keyboard is in it (not in a text field there). It
  // steps aside while a diff in place hides the header (#24344), so it needs no close button of its
  // own (Leo, 2026-10-24: "the top bit with the closing mark. It doesn't— it's not necessary").
  /// Two painted frames: an Esc that closes the panel has drawn by then.
  const frames = (page: Page) =>
    page.evaluate(() => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done()))));
  for (const name of browsers.keys())
    test(`${name}: no x and no band over its first row; Esc closes it from inside, not from the composer or a popover`, async () => {
      current = browsers.get(name)!;
      const page = await pane!.open({ width: 1600, height: 620 });
      try {
        const { panel, toggle } = await openInspector(page, 0);
        const { buttons, band } = await panel.evaluate((node) => {
          const first = node.querySelector(".acpmux-chat-inspector__body [data-section]")!;
          return {
            buttons: node.querySelectorAll(".acpmux-chat-inspector__close").length,
            band: first.getBoundingClientRect().top - node.getBoundingClientRect().top > 12,
          };
        });
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
        await panel.locator("button").first().focus();
        await page.keyboard.press("Escape");
        const byEscape = await panel.waitFor({ state: "detached", timeout: 5_000 }).then(
          () => true,
          () => false,
        );
        expect({ buttons, band, keptInComposer, keptUnderPopover, byEscape }).toEqual({
          buttons: 0,
          band: false,
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
  // toggle; elsewhere Esc keeps its meaning. A close by Esc gives the keyboard to the toggle.
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

  // Full length (Leo, 2026-10-26) never covers the composer: in a pane too narrow for the chat to move
  // left for it, the card floats over the chat and stops above the composer's stack.
  // A new chat's dock is `display: contents` (bottomStack.css): its own box is empty, so the card
  // measures its children; the second pass forces that layout on this chat.
  for (const name of browsers.keys())
    for (const contents of [false, true])
      test(`${name}: over the chat in a narrow pane, a busy Inspector stops above the composer${contents ? " (dock display: contents)" : ""}`, async () => {
        current = browsers.get(name)!;
        const page = await pane!.open({ width: 900, height: 900 });
        try {
          if (contents)
            await page.addStyleTag({
              content: ".acpmux-main > .acpmux-dock { display: contents !important; position: static !important; }",
            });
          const { panel } = await openInspector(page, 0);
          await page.addStyleTag({ content: "aside.acpmux-chat-inspector [data-section] { min-height: 1600px; }" });
          await page.waitForFunction(
            () => document.querySelector("aside.acpmux-chat-inspector[data-over-chat]") !== null,
          );
          const { bottom, dockTop, scrolls } = await panel.evaluate((node) => {
            const body = node.querySelector(".acpmux-chat-inspector__body")!;
            return {
              bottom: node.getBoundingClientRect().bottom,
              // The composer's own box (the dock's may be empty under display: contents).
              dockTop: document.querySelector(".acpmux-composer")!.getBoundingClientRect().top,
              scrolls: body.scrollHeight > body.clientHeight + 1,
            };
          });
          expect({ clear: bottom <= dockTop + 0.5, scrolls }).toEqual({ clear: true, scrolls: true });
        } finally {
          await page.close();
        }
      });
});
