// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// `cmux app chat drive` (chatDrive.ts) with real engine input: the point `begin` returns, a real
// pointer moved there and real wheel ticks give the page a real `:hover` (a computed style only a
// :hover rule sets), the tool screenshot's real hover card, and a scroll of the transcript, and the
// report counts exactly the wheel ticks sent, all trusted. The host's native injection (the app's
// AgentChatDriveInput) is held to the same input-event list this file asserts.
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts), in real Chromium and WebKit (the app's engine). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/chat-drive-browser.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { PNG } from "pngjs";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";
import { SENT_IMAGE, TOOL_SCREENSHOT } from "../src/agent-session/acpmux/transcriptSelectors";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane, type PapercutStep } from "./support/papercutChat";

await requireBrowserLane("chat-drive-browser.test.ts", async () => {
  /// A solid `width` x `height` PNG, base64.
  function png(width: number, height: number, [r, g, b]: [number, number, number]): string {
    const image = new PNG({ width, height });
    for (let at = 0; at < width * height * 4; at += 4) image.data.set([r, g, b, 255], at);
    return PNG.sync.write(image).toString("base64");
  }

  const SHOT = png(320, 200, [40, 120, 200]);
  const SENT = png(240, 160, [200, 90, 40]);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const TURNS = 24;
  /// The chat's last turn: a prompt with an image, a command whose result is a screenshot, an answer.
  const LAST_TURN: PapercutStep[] = [
    [
      "mux",
      "user_message",
      { text: "What is on this screen?", images: [{ id: "sent-1", mimeType: "image/png", width: 240, height: 160 }] },
    ],
    ["mux", "turn_started", {}],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "shot-1",
        title: "screencapture /tmp/shot.png",
        kind: "execute",
        status: "completed",
        rawInput: { command: "screencapture /tmp/shot.png" },
        content: [{ type: "content", content: { type: "image", mimeType: "image/png", data: SHOT } }],
      }),
    ],
    [
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Last answer: a blue screen." } }),
    ],
    ["mux", "turn_result", { status: "completed" }],
  ];

  /// The trusted pointer and mouse events a real pointer moved onto a target gives the page before the
  /// wheel's (`pointerenter` and `mouseenter` on the target itself). Their order differs by engine
  /// (Chromium sends the pointer events of a crossing before the mouse ones, WebKit pairs each), so the
  /// set is what is held; the host's injection is held to the same set.
  const POINTER_ARRIVES = ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"];

  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`chat-drive-browser: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("chat drive", () => test("browsers", () => {}));
    return;
  }
  const browsers = new Map<string, Browser>();
  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    current = browsers.values().next().value;
    pane = await papercutPane(() => current!, {
      turns: TURNS,
      running: false,
      extra: LAST_TURN,
      ready: "text=Last answer:",
      attachments: { "sent-1": { mimeType: "image/png", data: SENT } },
    });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /// The pane at its latest message, its thumbnails drawn, with a test-only `:hover` rule on them: the
  /// pane's stylesheet has none of its own on these thumbnails.
  async function open(): Promise<Page> {
    const page = await pane!.open();
    await page.locator(SENT_IMAGE).first().waitFor();
    // A finished turn folds its work into "Worked for": open it, as a person does to see its calls.
    await page
      .getByRole("button", { name: /Worked for/ })
      .last()
      .click();
    await page.locator(TOOL_SCREENSHOT).first().waitFor();
    await page.addStyleTag({ content: `${SENT_IMAGE}:hover, .cv-tool-visual:hover { --drive-hovered: yes; }` });
    return page;
  }

  type Drive = Record<string, any>;
  const call = (page: Page, verb: "begin" | "state" | "end" | "personActive", options?: unknown) =>
    page.evaluate(
      async ([verb, options]) => {
        const drive = window.cmuxAcpmuxBridge!.drive! as unknown as Record<string, (options?: unknown) => unknown>;
        return (await drive[verb](options)) as Record<string, any>;
      },
      [verb, options] as const,
    ) as Promise<Drive>;
  const hoveredStyle = (page: Page, selector: string, index: number) =>
    page.evaluate(
      ([selector, index]) =>
        getComputedStyle(document.querySelectorAll(selector)[index]!).getPropertyValue("--drive-hovered").trim(),
      [selector, index] as const,
    );
  const scrollTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);

  for (const [name] of engines) {
    describe(name, () => {
      test("a real pointer on a tool screenshot: :hover, its card, the wheel's scroll, every tick counted", async () => {
        current = browsers.get(name);
        const page = await open();
        // Start away from the thumbnails, as a person's pointer does.
        await page.mouse.move(5, 5);
        // A thumbnail under something else is no point to hover: begin says so and installs nothing.
        await page.evaluate(() => {
          const cover = document.createElement("div");
          cover.id = "drive-cover";
          cover.style.cssText = "position:fixed;inset:0;z-index:2147483647";
          document.body.append(cover);
        });
        expect(await call(page, "begin", { target: { tool_screenshot: 1 }, seconds: 20 })).toEqual({
          error: "target_covered",
        });
        await page.evaluate(() => document.getElementById("drive-cover")!.remove());
        const begun = await call(page, "begin", { target: { tool_screenshot: 1 }, allow_busy: false, seconds: 20 });
        expect(begun.ok).toBe(true);
        expect(begun.device_pixel_ratio).toBe(1);
        expect(begun.scroller.scroll_height).toBeGreaterThan(begun.scroller.height);
        // Bringing the target into view moved the transcript, if at all, by what begin says.
        expect(begun.scrolled_into_view.to).toBe(begun.scroller.top);
        const { x, y } = begun.point;
        await page.mouse.move(x, y, { steps: 4 });
        // The card opens after its dwell, as a person's resting pointer opens it.
        await page.waitForFunction(
          () => (window.cmuxAcpmuxBridge!.drive!.state() as { card_open: boolean | null }).card_open === true,
          undefined,
          { timeout: 10_000 },
        );
        const resting = await call(page, "state");
        expect(resting).toMatchObject({ hovered: true, card_open: true });
        expect(await hoveredStyle(page, TOOL_SCREENSHOT, 0)).toBe("yes");
        const before = await scrollTop(page);
        const ticks = 3;
        // `mouse.wheel` returns before the page has the event (Chromium's last tick lands a moment later),
        // so each tick goes once the page has the last, as the host's own ticks do. This window capture
        // listener runs in the same dispatch as the drive's, after it.
        await page.evaluate(() => {
          const counted = window as unknown as { driveTestWheels: number };
          counted.driveTestWheels = 0;
          window.addEventListener("wheel", () => (counted.driveTestWheels += 1), { capture: true, passive: true });
        });
        for (let tick = 1; tick <= ticks; tick += 1) {
          await page.mouse.wheel(0, -40);
          await page.waitForFunction(
            (tick) => (window as unknown as { driveTestWheels: number }).driveTestWheels >= tick,
            tick,
            { timeout: 5_000 },
          );
        }
        await page.waitForFunction((before) => document.querySelector(".acpmux-scroll")!.scrollTop !== before, before, {
          timeout: 5_000,
        });
        const wheeled = await call(page, "state");
        // The host's own hold and wheel are no person's.
        expect(wheeled.person_active).toBe(false);
        expect(wheeled.scroll_top).not.toBe(before);
        const report = await call(page, "end");
        console.log(name, JSON.stringify({ resting, wheeled, sequence: report.input_sequence, totals: report.totals }));
        expect(report.totals.wheel_events).toBe(ticks);
        expect(report.totals.wheel_trusted).toBe(ticks);
        expect(report.person_active).toBe(false);
        expect(report.scrolled_into_view).toEqual(begun.scrolled_into_view);
        expect(report.totals.hovered_frames).toBeGreaterThan(0);
        expect(report.totals.card_open_frames).toBeGreaterThan(0);
        expect(report.frames.some((frame: Drive) => frame.hovered && frame.card_open)).toBe(true);
        const sequence = (report.input_sequence as { type: string; trusted: boolean }[]).map((entry) => entry.type);
        expect(report.input_sequence.every((entry: { trusted: boolean }) => entry.trusted)).toBe(true);
        const arrival = sequence.slice(0, sequence.indexOf("wheel"));
        expect([...new Set(arrival)].filter((type) => POINTER_ARRIVES.includes(type)).sort()).toEqual(
          [...POINTER_ARRIVES].sort(),
        );
        // Each mouse event follows its pointer event, and the target is entered before the wheel.
        expect(arrival.indexOf("pointerover")).toBeLessThan(arrival.indexOf("mouseover"));
        expect(arrival.indexOf("pointerenter")).toBeLessThan(arrival.indexOf("mouseenter"));
        expect(arrival.lastIndexOf("pointermove")).toBeLessThan(arrival.lastIndexOf("mousemove"));
        expect(report.input_events.wheel).toEqual({ count: ticks, trusted: ticks });
        // The host lets go of the pointer: the card goes, and state() still reads it after end.
        await page.mouse.move(5, 5, { steps: 2 });
        await page.waitForFunction(
          () => (window.cmuxAcpmuxBridge!.drive!.state() as { card_open: boolean | null }).card_open === false,
          undefined,
          { timeout: 5_000 },
        );
        expect(await call(page, "state")).toMatchObject({ hovered: false, card_open: false, running: false });
        await page.close();
      });

      test("a person's real key mid-run stops the drive's typing", async () => {
        current = browsers.get(name);
        const page = await open();
        const text = "x".repeat(300);
        expect(await call(page, "begin", { type: { text, allow_draft: false }, seconds: 20 })).toMatchObject({
          ok: true,
        });
        await page.waitForFunction(
          () => (window.cmuxAcpmuxBridge!.composerState!()?.text.length ?? 0) >= 5,
          undefined,
          {
            timeout: 5_000,
          },
        );
        await page.keyboard.press("y");
        expect((await call(page, "state")).person_active).toBe(true);
        const report = await call(page, "end");
        expect(report.type_stopped).toBe("person");
        expect(report.typed).toBeLessThan(text.length);
        // The drive typed nothing after the person's key: the draft ends with it.
        expect(await page.evaluate(() => window.cmuxAcpmuxBridge!.composerState!()?.text)).toBe(
          `${text.slice(0, report.typed)}y`,
        );
        await page.close();
      });

      // The person's draft, all of it selected, as their own select-all leaves it: with the caret still
      // in the composer, and after they left it (the drive's typing puts focus back through its route).
      for (const left of [false, true])
        test(`typing over a selected draft goes after it and replaces none of it${left ? ", the composer left" : ""}`, async () => {
          current = browsers.get(name);
          const page = await open();
          const draft = "keep this draft";
          await page.locator(COMPOSER_EDITOR).click();
          await page.keyboard.type(draft);
          await page.keyboard.press("ControlOrMeta+a");
          expect(await page.evaluate(() => document.getSelection()?.toString().trim())).toBe(draft);
          if (left) await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
          expect(await call(page, "begin", { type: { text: "x", allow_draft: true }, seconds: 20 })).toMatchObject({
            ok: true,
          });
          // One character, one frame: the draft changes once.
          await page.waitForFunction((draft) => window.cmuxAcpmuxBridge!.composerState!()?.text !== draft, draft, {
            timeout: 5_000,
          });
          const report = await call(page, "end");
          expect(report.typed).toBe(1);
          expect(await page.evaluate(() => window.cmuxAcpmuxBridge!.composerState!()?.text)).toBe(`${draft}x`);
          expect(await page.locator(COMPOSER_EDITOR).textContent()).toBe(`${draft}x`);
          await page.close();
        });

      test("a real pointer on a sent image: :hover, no page card, and typing that drives the composer", async () => {
        current = browsers.get(name);
        const page = await open();
        await page.mouse.move(5, 5);
        const begun = await call(page, "begin", {
          target: { sent_image: 1 },
          allow_busy: false,
          type: { text: "hi there", allow_draft: false },
          seconds: 20,
        });
        expect(begun.ok).toBe(true);
        await page.mouse.move(begun.point.x, begun.point.y, { steps: 4 });
        await page.waitForFunction(
          () => (window.cmuxAcpmuxBridge!.drive!.state() as { hovered: boolean }).hovered,
          undefined,
          { timeout: 5_000 },
        );
        expect(await hoveredStyle(page, SENT_IMAGE, 0)).toBe("yes");
        // A sent image has no hover card on the page (its name is the native title tooltip).
        expect((await call(page, "state")).card_open).toBeNull();
        // One character a frame: the whole text is in the composer's own draft a few frames on.
        await page.waitForFunction(() => window.cmuxAcpmuxBridge!.composerState!()?.text === "hi there", undefined, {
          timeout: 5_000,
        });
        // The drive's own typing is not a person's; a real key in the composer is.
        expect(await call(page, "personActive")).toEqual({ typing_ms_ago: null, pointer_inside: true });
        await page.keyboard.type("!");
        const person = await call(page, "personActive");
        expect(person.typing_ms_ago).toBeGreaterThanOrEqual(0);
        expect(person.typing_ms_ago).toBeLessThan(2000);
        const report = await call(page, "end");
        console.log(name, JSON.stringify({ typed: report.typed, focus: report.focus, totals: report.totals }));
        expect(report.typed).toBe("hi there".length);
        expect(report.draft_left).toBe(true);
        expect(report.person_active).toBe(true);
        expect(report.person_active_by).toBe("key");
        expect(report.focus.after).toBe("composer");
        expect(report.totals.composer_renders).toBeGreaterThan(0);
        expect(report.totals.composer_mutations).toBeGreaterThan(0);
        // Nothing is restored: the drive's text, and the person's key after it, stay in the draft.
        expect(await page.locator(COMPOSER_EDITOR).textContent()).toBe("hi there!");
        await page.close();
      });
    });
  }
});
