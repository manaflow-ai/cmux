// cmux-web-test-timeout: 1500
// l10n-allow-file: test fixture prompts, not shipped UI.
// A multi-line send from the real composer, under the transcript motion detector (support/transcriptMotion.ts;
// hq#18554 ask 3). Leo, 2026-11-22: "IT JUMPS ... DON'T JUMP / FIX THE ANIMATIONS / FIX THE LOGIC / AND /
// WHEN A TURN BY AN AGENT END / STOP ADDING DINGLEBERRIES OF TOOL CALLS ... THAT SHIFTS POORLY. IF IT NEEDS
// TO SHIFT, IT SHIFTS GRACEFULLY. THAT'S THE GOAL. / AND I SHOULDN'T HAVE TO KEEP IDENTIFYING THIS /
// MATHEMATICALLY, ALL OF THESE SHOULD BE FLAGGABLE". In his video he types a message of lines with blank
// lines between them (the composer grows, then scrolls inside), presses Enter, and the composer goes back
// to one line slowly while the transcript above it jumps.
//
// Each case: the pane's production build (papercutChat.ts, a stand-in acpmux, 40 finished turns), a pane
// 360 px or 1280 px wide, at the latest row or scrolled up, a prompt of 1, 5, 30 or 300 lines with a blank
// line between each (typed with Shift+Enter up to 5 lines, pasted past that), with or without a pasted
// image. Every frame from just before Enter until 1.5 s after is recorded (every row's box, the composer's
// card, the dock, the animations) and read by `transcriptMoves`; the stand-in echoes the prompt as acpmux
// does (user_message, turn_started) as soon as the page sent it. Each case prints one JSON line
// (`send-lines`): the detector's flags (kind, element, px, frame time), and the composer card's height
// over time: how long from Enter until it is its one-line height again, in how many frames, and how
// (`instant`: in the send's frame or the next; `animated`: a geometry animation drew it; `shrink`: frames
// of in-between heights with no animation, a slow collapse).
//
// The gate (send-lines-motion-baseline.json): each case's flag kinds known today. A case flagging a kind
// its entry does not list, in two plays out of two, fails; a listed kind that plays clean is printed so it
// can come out. Chromium on the frames' own 120 Hz clock (frames120.ts, browser/frameClock.ts), so what
// each frame draws follows from the frames before it, not from the runner's load.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import type { PluginOption } from "vite";
import { chromium, type Browser, type Page } from "playwright";
import { FramesUnsupported, open120Hz } from "./support/frames120";
import { installPaintedFrames } from "./support/paintedFrames";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import {
  countFlags,
  defineTranscriptMotion,
  TRANSCRIPT_MOTION,
  transcriptMoves,
  type MotionFlag,
  type MotionFlagKind,
  type MotionRecord,
} from "./support/transcriptMotion";
import { COMPOSER_EDITOR } from "../src/agent-session/acpmux/composerSelectors";
import { MOTION_SEND_MS } from "../src/motion/scale.generated";

await requireBrowserLane("agent-pane-send-lines-motion-browser.test.ts", async () => {
  setDefaultTimeout(1_400_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-lines-motion-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("send lines motion", () => test("chromium", () => {}));
    return;
  }
  let frames120 = true;
  try {
    await (await open120Hz("about:blank")).close();
  } catch (error) {
    if (!(error instanceof FramesUnsupported) || process.env.GITHUB_ACTIONS === "true") throw error;
    frames120 = false;
    console.warn("agent-pane-send-lines-motion-browser: Chromium draws at its own pace here (no BeginFrame control)");
  }

  const clockSource = new Bun.Transpiler({ loader: "ts" })
    .transformSync(await Bun.file(path.join(import.meta.dir, "browser/frameClock.ts")).text())
    .replace(/^export /gm, "");
  const frameClock: PluginOption = {
    name: "send-lines-frame-clock",
    transformIndexHtml: (html) => html.replace("<head>", `<head><script>${clockSource}</script>`),
  };

  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 40, running: false, production: {}, vitePlugins: [frameClock] });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  const RECORD_MS = 1500;
  const HEIGHT = 800;

  /// Until the transcript, the dock and every finite animation hold still over 12 painted frames (at most 900).
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let last = "";
          let still = 0;
          let count = 0;
          window.cmuxAfterPaint(() => {
            count += 1;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            const box = document.querySelector<HTMLElement>(".acpmux-composer-box");
            const now = [scroller?.scrollTop, scroller?.scrollHeight, box?.getBoundingClientRect().height].join(",");
            const running = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" &&
                  Number.isFinite(animation.effect?.getComputedTiming().endTime ?? Number.POSITIVE_INFINITY),
              );
            still = now === last && !running ? still + 1 : 0;
            last = now;
            if (still < 12 && count < 900) return true;
            resolve();
            return false;
          });
        }),
    );
  const fromEnd = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
    });
  const composerHeight = (page: Page) =>
    page.evaluate(() => document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height);

  /// Leo's prompt: `lines` lines with a blank line between each.
  const promptLines = (lines: number, tag: string) =>
    Array.from({ length: lines }, (_, i) => `${tag} line ${i + 1}: the relay and its retry path`);

  /// Pastes plain text into the prompt, as the clipboard does.
  const pasteText = (page: Page, text: string) =>
    page.evaluate(
      ({ text, prompt }) => {
        const data = new DataTransfer();
        data.setData("text/plain", text);
        const field = document.querySelector(prompt)!;
        const paste = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
        if (paste.clipboardData !== data) Object.defineProperty(paste, "clipboardData", { value: data });
        field.dispatchEvent(paste);
      },
      { text, prompt: COMPOSER_EDITOR },
    );

  /// Pastes a screenshot-like PNG (made in the page) into the prompt; resolves once it is drawn ready.
  const pasteImage = async (page: Page): Promise<boolean> => {
    await page.evaluate(async (prompt) => {
      const canvas = document.createElement("canvas");
      canvas.width = 640;
      canvas.height = 400;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#1b1c20";
      context.fillRect(0, 0, 640, 400);
      context.fillStyle = "#d6d7db";
      context.font = "28px sans-serif";
      for (let line = 0; line < 12; line += 1) context.fillText(`line ${line}`, 24, 32 + line * 32);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "shot.png", { type: "image/png" }));
      const field = document.querySelector(prompt)!;
      const paste = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
      if (paste.clipboardData !== data) Object.defineProperty(paste, "clipboardData", { value: data });
      field.dispatchEvent(paste);
    }, COMPOSER_EDITOR);
    // The attachment's tile (in the text, or the strip), drawn ready: nothing loading in the card.
    return page
      .waitForFunction(
        () => {
          const box = document.querySelector(".acpmux-composer-box")!;
          if (box.querySelector('[aria-busy="true"]')) return false;
          return box.querySelector(".acpmux-md-inline-chip, .acpmux-attachment") !== null;
        },
        undefined,
        { timeout: 15_000 },
      )
      .then(
        () => true,
        async () => {
          console.warn(
            `send-lines: the pasted image drew no tile: ${await page.evaluate(() => document.querySelector(".acpmux-composer-box")?.innerHTML.slice(0, 600))}`,
          );
          return false;
        },
      );
  };

  /// Settles once `promise` does, or rejects after `ms` naming `what` (a step that never came).
  const within = <T>(promise: Promise<T>, ms: number, what: string) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    // fixed-wait: the bound on a step that never came (a send held, a frame never drawn).
    const limit = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`send-lines: ${what} did not come within ${ms / 1000} s`)), ms);
    });
    return Promise.race([promise, limit]).finally(() => clearTimeout(timer));
  };

  type Case = { lines: number; image: boolean; where: "bottom" | "up"; width: number };
  const key = (c: Case) => `${c.width}px ${c.where} ${c.lines} lines${c.image ? " +image" : ""}`;
  const CASES: Case[] = [];
  for (const width of [360, 1280])
    for (const where of ["bottom", "up"] as const)
      for (const lines of [1, 5, 30, 300])
        for (const image of [false, true]) CASES.push({ lines, image, where, width });

  /// The composer card's height over the recording, from the frame of Enter.
  function collapse(record: MotionRecord, typed: number, oneLine: number) {
    const sendAt = record.frames.findIndex((frame) => frame.marks.includes("send"));
    // The frame before the mark: Enter may land before the mark's own frame is drawn.
    const from = Math.max(0, sendAt - 1);
    const curve = record.frames.slice(from).map((frame) => ({
      t: Math.round((frame.t - record.frames[from]!.t) * 10) / 10,
      h: frame.els.composer?.[0][3] ?? 0,
      animated: frame.animated.includes("composer"),
    }));
    // Drop repeats: the curve as its changes.
    const steps = curve.filter((point, i) => i === 0 || Math.abs(point.h - curve[i - 1]!.h) > 0.5);
    const start = typed;
    const restIndex = curve.findIndex((point) => Math.abs(point.h - oneLine) <= 1);
    const between =
      restIndex < 0 ? curve.length : curve.slice(0, restIndex).filter((p) => Math.abs(p.h - start) > 1).length;
    const animated = curve.slice(0, Math.max(0, restIndex) + 1).some((point) => point.animated);
    const how =
      start - oneLine <= 1
        ? "none"
        : restIndex < 0
          ? "never"
          : animated
            ? "animated"
            : between === 0 && restIndex <= 2
              ? "instant"
              : "shrink";
    // The frame the sent bubble lands: the first frame after Enter with a row no frame before it drew.
    const seen = new Set(record.frames.slice(0, Math.max(1, from)).flatMap((frame) => Object.keys(frame.els)));
    const landed = record.frames.slice(from).findIndex((frame) => Object.keys(frame.els).some((k) => !seen.has(k)));
    return {
      startPx: start,
      oneLinePx: oneLine,
      ms: restIndex < 0 ? null : curve[restIndex]!.t,
      frames: restIndex < 0 ? null : restIndex,
      between,
      how,
      bubbleMs: landed < 0 ? null : (curve[landed]?.t ?? null),
      curve: steps.slice(0, 24).map((point) => [point.t, Math.round(point.h)]),
    };
  }

  /// One page a width, kept across its cases (each case starts at rest from where the last left it).
  type Opened = { page: Page; frames?: Awaited<ReturnType<typeof open120Hz>> };
  const pages = new Map<number, Opened>();
  async function pageFor(width: number): Promise<Opened> {
    const kept = pages.get(width);
    if (kept) return kept;
    const viewport = { width, height: HEIGHT };
    const address = frames120 ? pane.address().replace("/#", "/?clock=frames#") : pane.address();
    const frames = frames120 ? await open120Hz(address, { viewport, clock: "frames" }) : undefined;
    const page = frames?.page ?? (await browser.newPage({ viewport }));
    await installPaintedFrames(page);
    if (!frames) await page.goto(address);
    await page.locator(COMPOSER_EDITOR).first().waitFor({ timeout: 120_000 });
    // Earlier cases' sends are the chat's end now: wait for its rows, not one answer's text.
    await page.locator(".acpmux-thread > .acpmux-row").first().waitFor({ timeout: 120_000 });
    await page.evaluate(defineTranscriptMotion, TRANSCRIPT_MOTION);
    await settle(page);
    const opened = { page, frames };
    pages.set(width, opened);
    return opened;
  }
  afterAll(async () => {
    for (const { page, frames } of pages.values()) {
      if (frames) await frames.close();
      else await page.close();
    }
  });

  let sent = 0;
  async function play(c: Case) {
    const { page, frames } = await pageFor(c.width);
    // From the latest row: the last case's turn left it there (a send rides to the latest row).
    await page.keyboard.press("Escape");
    if ((await fromEnd(page)) > 1) {
      await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop = scroller.scrollHeight;
      });
      await settle(page);
    }
    if (c.where === "up") {
      await page.mouse.move(c.width / 2, 200);
      for (let moved = 0; moved < 1200; moved += 40) await page.mouse.wheel(0, -40);
      await settle(page);
    }
    const oneLine = await composerHeight(page);
    const tag = `Send ${(sent += 1)}`;
    const lines = promptLines(c.lines, tag);
    await page.locator(COMPOSER_EDITOR).first().click();
    if (c.lines <= 5) {
      for (const [i, line] of lines.entries()) {
        if (i) {
          await page.keyboard.press("Shift+Enter");
          await page.keyboard.press("Shift+Enter");
        }
        await page.keyboard.type(line);
      }
    } else await pasteText(page, lines.join("\n\n"));
    const attached = c.image ? await pasteImage(page) : false;
    await within(settle(page), 60_000, "the typed prompt's settle");
    const typedPx = await composerHeight(page);
    const upPx = c.where === "up" ? await fromEnd(page) : 0;
    const asked = pane.sent("session/prompt", pane.methods.filter((method) => method === "session/prompt").length);
    const before = pane.prompts.length;
    await page.evaluate(() => window.__transcriptMotion!.start());
    frames?.start();
    // Two frames of rest before Enter.
    await page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let painted = 0;
          window.cmuxAfterPaint(() => {
            painted += 1;
            if (painted < 2) return true;
            resolve();
            return false;
          });
        }),
    );
    await page.evaluate(() => window.__transcriptMotion!.mark("send"));
    const startedAt = await page.evaluate(() => performance.now());
    await page.keyboard.press("Enter");
    await within(asked, 20_000, "the page's session/prompt");
    const promptId = pane.prompts[before]?._meta?.acpmux?.promptId as string;
    pane.record("user_message", { text: lines.join("\n\n"), promptId, turnId: `turn-${promptId}` });
    pane.record("turn_started", {});
    await page.evaluate(
      (until) =>
        new Promise<void>((resolve) => {
          window.cmuxAfterPaint(() => {
            if (performance.now() < until) return true;
            resolve();
            return false;
          });
        }),
      startedAt + RECORD_MS,
    );
    const record = await page.evaluate(() => window.__transcriptMotion!.stop());
    await frames?.stop();
    pane.record("turn_result", { status: "completed" });
    await settle(page);
    const flags = transcriptMoves(record);
    return { record, flags, typedPx, upPx, oneLine, attached, collapse: collapse(record, typedPx, oneLine) };
  }

  const brief = (flag: MotionFlag) => ({
    kind: flag.kind,
    el: flag.key,
    px: flag.px,
    t: flag.t,
    ...(flag.detail ? { detail: flag.detail } : {}),
    ...(flag.cause.length ? { cause: flag.cause } : {}),
  });
  /// The kinds a case is gated on: the detector's, and `send-glide`: a geometry animation on the
  /// transcript (its thread, a row, the dock, the composer) that starts with the send and runs longer
  /// than the send's step (MOTION_SEND_MS, 0: "its room, its bubble and the thread are in their places
  /// in the frame the composer empties", motion/scale.generated.ts). The detector excuses it (it rides
  /// the house curve); the send's contract does not.
  type Kind = MotionFlagKind | "send-glide";
  const KINDS: Kind[] = ["move", "resize", "off-curve", "send-glide"];
  const TRANSCRIPT_TARGET = /^(row:|dock$|composer$|div\.acpmux-thread|div\.acpmux-scroll|div\.acpmux-dock)/;
  const sendGlides = (record: MotionRecord) => {
    const sendAt = record.frames.findIndex((frame) => frame.marks.includes("send"));
    return record.animations.filter(
      (animation) =>
        animation.frame >= sendAt - 1 &&
        TRANSCRIPT_TARGET.test(animation.target) &&
        animation.duration > MOTION_SEND_MS + 0.5,
    );
  };
  const counts = (played: { flags: MotionFlag[]; record: MotionRecord }): Record<Kind, number> => ({
    ...countFlags(played.flags),
    "send-glide": sendGlides(played.record).length,
  });
  const baseline = (await Bun.file(path.join(import.meta.dir, "send-lines-motion-baseline.json")).json()) as Record<
    string,
    Kind[]
  >;
  const results: Record<string, unknown>[] = [];

  describe("a multi-line send from the composer", () => {
    for (const c of CASES) {
      test(
        key(c),
        async () => {
          let played = await play(c);
          const kinds = (one: typeof played) => KINDS.filter((kind) => counts(one)[kind] > 0);
          const allowed = baseline[key(c)] ?? [];
          let fresh = kinds(played).filter((kind) => !allowed.includes(kind));
          if (fresh.length) {
            // A flag counts when it repeats.
            const again = await play(c);
            const repeated = kinds(again).filter((kind) => fresh.includes(kind));
            if (repeated.length < fresh.length) played = again;
            fresh = repeated;
          }
          const line = {
            case: key(c),
            flags: counts(played),
            // Flags by kind and element: rows by their kind, everything else by its key.
            by: played.flags.reduce<Record<string, number>>((by, flag) => {
              const el = flag.of === "row" ? "row" : flag.key.replace(/#\d+$/, "");
              by[`${flag.kind} ${el}`] = (by[`${flag.kind} ${el}`] ?? 0) + 1;
              return by;
            }, {}),
            glides: sendGlides(played.record).map(
              (a) => `${a.target} ${a.properties.join(",")} ${a.duration}ms ${a.easing}`,
            ),
            ...(c.image ? { attached: played.attached } : {}),
            typedPx: played.typedPx,
            scrolledUpPx: Math.round(played.upPx),
            composer: played.collapse,
            animations: played.record.animations.map(
              (a) => `${a.target} ${a.properties.join(",")} ${a.duration}ms ${a.easing}`,
            ),
            first: played.flags.slice(0, 8).map(brief),
          };
          results.push(line);
          console.log(`send-lines ${JSON.stringify(line)}`);
          const cleared = allowed.filter((kind) => !kinds(played).includes(kind));
          if (cleared.length)
            console.log(`send-lines ratchet: ${key(c)} no longer flags ${cleared.join(", ")}: take it out`);
          expect(fresh).toEqual([]);
        },
        300_000,
      );
    }
  });

  afterAll(async () => {
    if (process.env.FAST_CHECKS_OUT)
      await Bun.write(path.join(process.env.FAST_CHECKS_OUT, "send-lines.json"), JSON.stringify(results, null, 1));
  });
});
