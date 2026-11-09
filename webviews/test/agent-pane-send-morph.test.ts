// l10n-allow-file: browser fixture prompts and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
// Leo, 2026-11-08 (ask-157340f908): "if you're at the bottom or something, then the transformation
// applies whatever's in your composer into your depicted message." A prompt sent from the latest row:
// what is in the composer (its words and its attachments) becomes the sent message in place, on the
// send motion (MOTION_SEND_MS): a copy drawn over the pane starts where the composer drew it, in the frame the
// composer empties, and lands on the sent bubble and thumbnail as the thread rises to them; the real
// bubble and thumbnail are hidden while it flies and drawn in the frame it lands, never both and never
// neither. Sent while scrolled up, or with Reduce Motion, nothing flies: the prompt fades in place
// (conversation.css SEND-ENTRANCE). Every frame from the send is read in the agent pane's dev entry.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-morph.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { MOTION_SEND_MS } from "../src/motion/scale.generated";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Box = { left: number; top: number; width: number; height: number };
type Ghost = Box & { kind: string; opacity: number };
/// One frame from the send: the composer's words and chips still drawn, the copies drawn over the
/// pane, and the sent row's bubble and thumbnail (their boxes, whether they are drawn, and their ink:
/// their own opacity and every box's around them up to the row).
type Frame = {
  at: number;
  typed: string;
  chips: number;
  ghosts: Ghost[];
  bubble?: Box & { shown: boolean; ink: number };
  preview?: Box & { shown: boolean; ink: number };
};

await requireBrowserLane("agent-pane-send-morph.test.ts", async () => {
  setDefaultTimeout(300_000);
  const LINE = "what is this sidebar doing";
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-morph: skipping (run `bunx playwright install chromium`)");
    describe.skip("send morph", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let pane: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    pane = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await pane.listen();
    await warmViteServer(pane, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  const field = '.acpmux-composer-prompt [contenteditable="true"]';

  /// The pane's dev entry with its mock agent and three earlier turns, so the chat overflows and a
  /// send rises from the latest row; the agent then answers late, as a real one does.
  const openChat = async (page: Page, turns = ["first question", "second question", "third question"]) => {
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    const port = (pane!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(field).waitFor();
    for (const line of turns) {
      await page.locator(field).click();
      await page.keyboard.type(line);
      await page.keyboard.press("Enter");
      await page.locator(".cv-user__bubble", { hasText: line }).waitFor();
      await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached", timeout: 30_000 });
    }
    if (turns.length > 2)
      expect(
        await page.locator(".acpmux-scroll").evaluate((scroll) => scroll.scrollHeight > scroll.clientHeight + 200),
      ).toBe(true);
    await page.evaluate(() =>
      Object.assign(window, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: 2000 }),
    );
  };

  /// A 1600x1000 screenshot pasted into the composer and `LINE` typed after it; answers where the
  /// composer drew them: its card, the chip and the words.
  const compose = async (page: Page) => {
    await page.locator(field).click();
    await page.evaluate(async (selector) => {
      const canvas = document.createElement("canvas");
      canvas.width = 1600;
      canvas.height = 1000;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#3a7bd5";
      context.fillRect(0, 0, canvas.width, canvas.height);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      document
        .querySelector(selector)!
        .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    }, field);
    await page.waitForFunction(() => {
      const image = document.querySelector<HTMLImageElement>(".acpmux-composer .acpmux-attachment-image img");
      return !!image && image.complete && image.naturalWidth > 0;
    });
    await page.keyboard.type(` ${LINE}`);
    return page.evaluate((selector) => {
      const box = (element: Element | null | undefined): Box => {
        const { left, top, width, height } = element!.getBoundingClientRect();
        return { left, top, width, height };
      };
      return {
        card: box(document.querySelector(".acpmux-composer-box")),
        chip: box(document.querySelector(".acpmux-composer .acpmux-attachment-image")),
        words: box(document.querySelector(`${selector} p`)),
      };
    }, field);
  };

  /// Reads every frame from now for `ms`: the composer, the copies over the pane and the sent row.
  const watch = (page: Page, ms = 1200) =>
    page.evaluate(
      ({ line, field, ms }) => {
        const frames: unknown[] = [];
        Object.assign(window, { __morph: { frames, done: false } });
        const start = performance.now();
        const box = (element: Element) => {
          const { left, top, width, height } = element.getBoundingClientRect();
          return { left, top, width, height };
        };
        const drawn = (element: Element, row: Element | null) => {
          let ink = 1;
          for (let at: Element | null = element; at; at = at === row ? null : at.parentElement)
            ink *= Number(getComputedStyle(at).opacity);
          return { ...box(element), shown: getComputedStyle(element).visibility === "visible", ink };
        };
        // raf-read: the send is the behavior; each frame is read as that frame is drawn.
        const tick = () => {
          const bubble = [...document.querySelectorAll(".cv-user__bubble")].find((node) =>
            node.textContent?.includes(line),
          );
          const row = bubble?.closest(".acpmux-row") ?? null;
          const preview = row?.querySelector("img.cv-user__image, .cv-user__image-placeholder");
          frames.push({
            at: Math.round(performance.now() - start),
            typed: document.querySelector(field)?.textContent ?? "",
            chips: document.querySelectorAll(".acpmux-composer .acpmux-attachment").length,
            ghosts: [...document.querySelectorAll<HTMLElement>("[data-send-morph-ghost]")].map((ghost) => ({
              ...box(ghost),
              kind: ghost.dataset.sendMorphGhost,
              opacity: Number(getComputedStyle(ghost).opacity),
            })),
            bubble: bubble ? drawn(bubble, row) : undefined,
            preview: preview ? drawn(preview, row) : undefined,
          });
          // raf-read: every frame of the send (above).
          if (performance.now() - start < ms) requestAnimationFrame(tick);
          else (window as unknown as { __morph: { done: boolean } }).__morph.done = true;
        };
        requestAnimationFrame(tick);
      },
      { line: LINE, field, ms },
    );
  const frames = async (page: Page) => {
    await page.waitForFunction(() => (window as unknown as { __morph: { done: boolean } }).__morph.done);
    const all = await page.evaluate(() => (window as unknown as { __morph: { frames: Frame[] } }).__morph.frames);
    // From the frame the composer let the prompt go.
    const sent = all.findIndex((frame) => !frame.typed.includes(LINE));
    expect(sent, "the composer never let the prompt go").toBeGreaterThanOrEqual(0);
    return all.slice(sent);
  };

  const near = (a: Box | undefined, b: Box | undefined, label: string, slack = 1.5) => {
    expect(a, label).toBeDefined();
    expect(b, label).toBeDefined();
    for (const key of ["left", "top", "width", "height"] as const)
      expect(Math.abs(a![key] - b![key]), `${label} ${key}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`).toBeLessThan(
        slack,
      );
  };
  const ghost = (frame: Frame, kind: string) => frame.ghosts.find((entry) => entry.kind === kind);

  test("at the bottom, the composer's words and screenshot become the sent message on the send motion", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page);
      const from = await compose(page);
      await watch(page);
      await page.keyboard.press("Enter");
      const seen = await frames(page);
      const first = seen[0]!;

      // The first frame: the composer is empty, and the copies are where it drew the prompt: the
      // bubble's shell on its card, the words on its words, the screenshot on its chip.
      expect(first.typed.trim(), "the composer empties in the send's first frame").toBe("");
      expect(first.chips, "the chip leaves the composer in the send's first frame").toBe(0);
      near(ghost(first, "bubble"), from.card, "the bubble starts as the composer's card");
      near(ghost(first, "attachment"), from.chip, "the screenshot starts on its chip");
      const words = first.ghosts.filter((entry) => entry.kind === "text" && entry.opacity > 0.99);
      expect(words.length, `the words are drawn where they were typed (${JSON.stringify(first.ghosts)})`).toBe(1);
      expect(Math.abs(words[0]!.left - from.words.left), "the words' left").toBeLessThan(1.5);
      expect(Math.abs(words[0]!.top - from.words.top), "the words' top").toBeLessThan(1.5);

      // Every frame: the copy or the sent message is drawn, never both and never neither, and the
      // composer stays empty.
      for (const frame of seen) {
        const flying = frame.ghosts.length > 0;
        expect(frame.typed.trim(), `the composer stays empty at ${frame.at} ms`).toBe("");
        if (flying) {
          if (frame.bubble) expect(frame.bubble.shown, `the bubble hides under its copy at ${frame.at} ms`).toBe(false);
          if (frame.preview)
            expect(frame.preview.shown, `the screenshot hides under its copy at ${frame.at} ms`).toBe(false);
        } else {
          expect(frame.bubble?.shown, `the bubble is drawn once its copy lands, at ${frame.at} ms`).toBe(true);
          expect(frame.preview?.shown, `the screenshot is drawn once its copy lands, at ${frame.at} ms`).toBe(true);
        }
      }

      // One clock: the copies land on the send motion (MOTION_SEND_MS from the row's first frame) and then
      // only the sent message is drawn, whole, with no entrance of its own after it.
      const mounted = seen.findIndex((frame) => frame.bubble);
      const landed = seen.findIndex((frame, index) => index > mounted && frame.ghosts.length === 0);
      expect(mounted, "the sent row never drew").toBeGreaterThanOrEqual(0);
      expect(landed, "the copies never landed").toBeGreaterThan(mounted);
      const flight = seen[landed]!.at - seen[mounted]!.at;
      expect(flight, "the flight's length").toBeGreaterThanOrEqual(MOTION_SEND_MS - 15);
      expect(flight, "the flight's length").toBeLessThan(MOTION_SEND_MS + 70);
      const last = seen[landed - 1]!;
      near(ghost(last, "bubble"), last.bubble, "the bubble's copy lands on the bubble");
      near(ghost(last, "attachment"), last.preview, "the screenshot's copy lands on its thumbnail");
      for (const frame of seen.slice(landed)) {
        expect(frame.bubble!.ink, `the bubble is whole once landed, at ${frame.at} ms`).toBeGreaterThan(0.99);
        expect(frame.preview!.ink, `the screenshot is whole once landed, at ${frame.at} ms`).toBeGreaterThan(0.99);
        near(frame.bubble, seen[landed]!.bubble, `the bubble stays where it landed at ${frame.at} ms`, 60);
      }
      // The copy's way is continuous: the bubble's shell never jumps more than a quarter of the way.
      for (let index = 1; index < landed; index += 1) {
        const [a, b] = [ghost(seen[index - 1]!, "bubble"), ghost(seen[index]!, "bubble")];
        if (a && b)
          expect(Math.abs(b.top - a.top), `the shell's step at ${seen[index]!.at} ms`).toBeLessThan(
            Math.abs(from.card.top - last.bubble!.top) * 0.5 + 2,
          );
      }
    } finally {
      await page.close();
    }
  });

  // The host's echo of the prompt can come inside the flight: it gives the screenshot its lasting id,
  // and the thumbnail drawn under the old one is replaced. The copy follows the new thumbnail.
  test("an echo inside the flight: the screenshot's copy still lands on its thumbnail", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page);
      await page.evaluate(() => Object.assign(window, { cmuxAcpmuxMockSlowMs: 40 }));
      await compose(page);
      await watch(page);
      // The echo's remount, as React draws it: a new thumbnail element where the old one was.
      await page.evaluate(() => {
        // raf-read: the remount comes a few frames into the flight, as an echo does.
        let seenFrames = 0;
        const swap = () => {
          const preview = document.querySelector<HTMLElement>(".acpmux-row img.cv-user__image[data-send-key]");
          if (preview && document.querySelector("[data-send-morph-ghost]") && (seenFrames += 1) === 3) {
            const fresh = preview.cloneNode(true) as HTMLElement;
            fresh.style.visibility = "";
            fresh.dataset.sendKey = "durable-image-id";
            preview.replaceWith(fresh);
            return;
          }
          // raf-read: the remount lands a few frames into the flight (above).
          requestAnimationFrame(swap);
        };
        // raf-read: the remount lands a few frames into the flight (above).
        requestAnimationFrame(swap);
      });
      await page.keyboard.press("Enter");
      const seen = await frames(page);
      const mounted = seen.findIndex((frame) => frame.bubble);
      const landed = seen.findIndex((frame, index) => index > mounted && frame.ghosts.length === 0);
      expect(landed, "the copies never landed").toBeGreaterThan(mounted);
      const last = seen[landed - 1]!;
      near(ghost(last, "attachment"), last.preview, "the screenshot's copy lands on its thumbnail");
      for (const frame of seen.slice(mounted, landed))
        if (frame.preview)
          expect(frame.preview.shown, `the thumbnail hides under its copy at ${frame.at} ms`).toBe(false);
    } finally {
      await page.close();
    }
  });

  // A prompt sent while a turn runs is queued: no row comes for it (the queue draws it over the
  // composer), so its copies fade where they are on the send's clock, never hold over the next
  // draft for long (review of #38217, F3).
  test("a prompt queued behind a running turn: its copies fade where they are", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page);
      await page.locator(field).click();
      await page.keyboard.type("a long task");
      await page.keyboard.press("Enter");
      await page.getByRole("button", { name: "Stop" }).waitFor();
      await compose(page);
      await watch(page, 900);
      await page.keyboard.press("Enter");
      const seen = await frames(page);
      expect(
        seen.some((frame) => frame.bubble),
        "the queued prompt drew no row",
      ).toBe(false);
      const gone = seen.findIndex((frame) => frame.ghosts.length === 0);
      expect(gone, "the copies never went").toBeGreaterThan(0);
      expect(seen[gone]!.at - seen[0]!.at, "the copies go on the send's clock").toBeLessThan(MOTION_SEND_MS + 120);
    } finally {
      await page.close();
    }
  });

  test("sent while scrolled up: nothing flies, the prompt fades in place", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page);
      const scroll = page.locator(".acpmux-scroll");
      const box = (await scroll.boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 3);
      await page.mouse.wheel(0, -600);
      await page.waitForFunction(
        () => {
          const node = document.querySelector(".acpmux-scroll")!;
          return node.scrollHeight - node.clientHeight - node.scrollTop > 200;
        },
        undefined,
        { timeout: 10_000 },
      );
      // The reader's scroll settles before the send: the same place for ten frames in a row.
      await page.evaluate(
        () =>
          new Promise<void>((resolve) => {
            const node = document.querySelector(".acpmux-scroll")!;
            let last = -1;
            let still = 0;
            // raf-read: waits for the scroll to rest, a painted-frame condition.
            const tick = () => {
              still = node.scrollTop === last ? still + 1 : 0;
              last = node.scrollTop;
              if (still >= 10) return resolve();
              // raf-read: the scroll's rest is the condition (above).
              requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          }),
      );
      await compose(page);
      await watch(page, 900);
      await page.keyboard.press("Enter");
      const seen = await frames(page);
      for (const frame of seen) expect(frame.ghosts, `no copy flies at ${frame.at} ms`).toEqual([]);
      const drawn = seen.filter((frame) => frame.bubble);
      expect(drawn.length, "the sent row was never drawn").toBeGreaterThan(2);
      expect(drawn[0]!.bubble!.shown, "the bubble draws in its place").toBe(true);
      expect(drawn[0]!.bubble!.ink, "the bubble fades in in place").toBeLessThan(0.6);
      expect(drawn.at(-1)!.bubble!.ink).toBeGreaterThan(0.99);
    } finally {
      await page.close();
    }
  });

  // The PR's first-send gate: a new chat's first prompt has no transcript yet to say it is at the
  // bottom, so nothing flies and it fades in place (SEND-ENTRANCE), whichever way the transcript
  // comes to draw it. A short chat that already has rows and fits is at its latest row and morphs.
  test("a new chat's first prompt: nothing flies, the prompt fades in place", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page, []);
      expect(await page.locator(".cv-user__bubble").count(), "the chat starts empty").toBe(0);
      await compose(page);
      await watch(page, 900);
      await page.keyboard.press("Enter");
      const seen = await frames(page);
      for (const frame of seen) expect(frame.ghosts, `no copy flies at ${frame.at} ms`).toEqual([]);
      const drawn = seen.filter((frame) => frame.bubble);
      expect(drawn.length, "the sent row was never drawn").toBeGreaterThan(2);
      expect(drawn[0]!.bubble!.shown, "the bubble draws in its place").toBe(true);
      expect(drawn[0]!.bubble!.ink, "the bubble fades in in place").toBeLessThan(0.6);
      expect(drawn.at(-1)!.bubble!.ink).toBeGreaterThan(0.99);
    } finally {
      await page.close();
    }
  });

  test("a short chat that fits, sent from its latest row, morphs", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 } });
    try {
      await openChat(page, ["first question"]);
      expect(
        await page.locator(".acpmux-scroll").evaluate((scroll) => scroll.scrollHeight <= scroll.clientHeight + 1),
        "one turn fits the pane",
      ).toBe(true);
      await compose(page);
      await watch(page, 900);
      await page.keyboard.press("Enter");
      const seen = await frames(page);
      expect(
        seen.some((frame) => frame.ghosts.length > 0),
        "the composer's prompt becomes the sent message",
      ).toBe(true);
    } finally {
      await page.close();
    }
  });

  test("with Reduce Motion nothing flies at the bottom either", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 620 }, reducedMotion: "reduce" });
    try {
      await openChat(page);
      await compose(page);
      await watch(page, 700);
      await page.keyboard.press("Enter");
      const seen = await frames(page);
      for (const frame of seen) expect(frame.ghosts, `no copy flies at ${frame.at} ms`).toEqual([]);
      expect(
        seen.some((frame) => frame.bubble?.shown),
        "the sent row was drawn",
      ).toBe(true);
    } finally {
      await page.close();
    }
  });
});
