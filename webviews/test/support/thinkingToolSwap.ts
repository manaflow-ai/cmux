// The live line's words handing over to a tool call, read frame by frame on the scripted `arrive-tool`
// turn (send-stream-motion.harness.tsx; conversation.css `data-live-swap`):
// thinking-tool-swap-stills.test.ts draws it for review, thinking-tool-swap-frames.test.ts holds it to
// its bounds.
import type { Page } from "playwright";
import { TRANSCRIPT_ROW } from "../../src/agent-session/acpmux/transcriptSelectors";

export const SWAP_PAGE = "/test/browser/send-stream-motion.html";

/// One box in the viewport, px.
export type Box = { top: number; bottom: number; left: number; right: number };

/// One frame of the hand-over.
export type SwapFrame = {
  phase?: string;
  /// The live line's row box.
  live?: Box;
  /// The words leaving the line (`.cv-roll-out`), as drawn: their box cut to the line's clip, and
  /// their ink (their opacity times every ancestor's); undefined once they are gone.
  out?: { box: Box; ink: number; text: string };
  /// The words the line says now (`output.cv-thinking`), cut to the line's clip, with their ink.
  now?: { box: Box; ink: number; text: string };
  /// The turn's other rows in view (the prompt, the reply, the arriving call's row): their box and ink,
  /// and their text's own box (the line boxes of their words), px.
  rows: { id: string; box: Box; ink: number; textBox?: Box; text: string }[];
  /// Where the stills' clip starts (px from the page's top): a little over the turn's last rows.
  clipTop: number;
};

/// Installed before the page's own scripts: from the step `begin` on, frame callbacks wait for
/// `__advance`, and every animation is held and moved on by one 120 Hz slot per frame
/// (turn-end-stills.test.ts's gate).
export function swapFrameGate() {
  const w = window as unknown as Record<string, unknown>;
  const realRaf = window.requestAnimationFrame.bind(window);
  const realCancel = window.cancelAnimationFrame.bind(window);
  let gated = false;
  let next = -1;
  const queued = new Map<number, FrameRequestCallback>();
  window.requestAnimationFrame = (callback) => {
    if (!gated) return realRaf(callback);
    const id = next--;
    queued.set(id, callback);
    return id;
  };
  window.cancelAnimationFrame = (id) => (id < 0 ? void queued.delete(id) : realCancel(id));
  const seen = new WeakSet<Animation>();
  const hold = () => {
    for (const animation of document.getAnimations()) {
      if (animation.playState === "running") {
        if (!seen.has(animation) && gated) animation.currentTime = 0;
        animation.pause();
      }
      seen.add(animation);
    }
  };
  w.__gate = () => {
    gated = true;
    hold();
  };
  w.__advance = () =>
    new Promise<void>((resolve) => {
      for (const animation of document.getAnimations())
        if (animation.playState === "paused") animation.currentTime = Number(animation.currentTime ?? 0) + 1000 / 120;
      const callbacks = [...queued.values()];
      queued.clear();
      realRaf((time) => {
        for (const callback of callbacks) callback(time);
        const idle = (w.__frameIdle as (() => Promise<void>) | undefined)?.() ?? Promise.resolve();
        void idle.then(() =>
          realRaf(() => {
            hold();
            resolve();
          }),
        );
      });
    });
  w.__release = () => {
    gated = false;
    for (const callback of queued.values()) realRaf(callback);
    queued.clear();
    for (const animation of document.getAnimations()) if (animation.playState === "paused") animation.play();
  };
  w.__onStep = (name: string) => {
    w.__phase = name;
    if (name === "begin") (w.__gate as () => void)();
  };
}

/// Reads one frame (runs in the page).
export function readSwapFrame(rowSelector: string): SwapFrame {
  const box = (rect: DOMRect | Box): Box => ({
    top: Math.round(rect.top * 100) / 100,
    bottom: Math.round(rect.bottom * 100) / 100,
    left: Math.round(rect.left * 100) / 100,
    right: Math.round(rect.right * 100) / 100,
  });
  const cut = (a: Box, b: Box): Box => ({
    top: Math.max(a.top, b.top),
    bottom: Math.min(a.bottom, b.bottom),
    left: Math.max(a.left, b.left),
    right: Math.min(a.right, b.right),
  });
  const ink = (node: Element | null, stop?: Element): number => {
    let value = 1;
    for (let at = node; at && at !== stop?.parentElement; at = at.parentElement) {
      const style = getComputedStyle(at);
      value *= Number.parseFloat(style.opacity);
      if (style.visibility === "hidden" || style.display === "none") return 0;
    }
    return Math.round(value * 1000) / 1000;
  };
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const view = scroller.getBoundingClientRect();
  const liveRow = scroller.querySelector<HTMLElement>('.acpmux-row[data-row-id="thinking-live"]');
  const line = liveRow?.querySelector<HTMLElement>(".cv-worked--live");
  // The line's clip: the words never draw past the words' row (conversation.css overflow-y: clip on
  // `.cv-shimmer__row` while a roll plays) nor the line's own box.
  const clipNode = line?.querySelector<HTMLElement>(".cv-shimmer__row") ?? line;
  const clip = clipNode ? box(clipNode.getBoundingClientRect()) : undefined;
  const piece = (node: HTMLElement | null | undefined) => {
    if (!node || !clip) return undefined;
    const drawn = cut(box(node.getBoundingClientRect()), clip);
    if (drawn.bottom - drawn.top <= 0.5) return undefined;
    const value = ink(node);
    if (value <= 0.01) return undefined;
    const text = node.dataset.text ?? (node.textContent ?? "").trim();
    return { box: drawn, ink: value, text: text.slice(0, 40) };
  };
  const rows: SwapFrame["rows"] = [];
  const turn = [...scroller.querySelectorAll<HTMLElement>(rowSelector)].filter((row) => {
    const id = row.dataset.rowId!;
    return id.startsWith("live-") && row !== liveRow;
  });
  for (const row of turn) {
    const rect = row.getBoundingClientRect();
    if (rect.height === 0 || rect.bottom <= view.top || rect.top >= view.bottom) continue;
    // The text's own line boxes: what a reader sees as the row's words.
    let textBox: Box | undefined;
    const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.textContent?.trim()) continue;
      const range = document.createRange();
      range.selectNodeContents(node);
      for (const each of range.getClientRects()) {
        if (each.height <= 0 || each.width <= 0) continue;
        textBox = textBox
          ? {
              top: Math.min(textBox.top, each.top),
              bottom: Math.max(textBox.bottom, each.bottom),
              left: Math.min(textBox.left, each.left),
              right: Math.max(textBox.right, each.right),
            }
          : box(each);
      }
    }
    // The ink of the row's words as drawn (the row's and its children's opacity on its first text).
    const first = (() => {
      const walk = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
      for (let node = walk.nextNode(); node; node = walk.nextNode())
        if (node.textContent?.trim()) return node.parentElement;
      return row;
    })();
    rows.push({
      id: row.dataset.rowId!,
      box: box(rect),
      ink: ink(first),
      ...(textBox && { textBox: box(textBox) }),
      text: (row.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 40),
    });
  }
  const liveBox = liveRow ? box(liveRow.getBoundingClientRect()) : undefined;
  return {
    phase: (window as unknown as { __phase?: string }).__phase,
    ...(liveBox && { live: liveBox }),
    ...(line && { out: piece(line.querySelector<HTMLElement>(".cv-roll-out")) }),
    ...(line && { now: piece(line.querySelector<HTMLElement>("output.cv-thinking")) }),
    rows,
    clipTop: Math.round((liveBox?.bottom ?? view.bottom) + window.scrollY - 150),
  };
}

/// The px every drawn thing moved since the frame before: the live line's words (the leaving and the
/// arriving), the live line and every row in view (by id; pass rows: [] for the line alone).
export function movedPx(before: SwapFrame, now: SwapFrame): number {
  let most = 0;
  const step = (a: Box | undefined, b: Box | undefined) => {
    if (a && b) most = Math.max(most, Math.abs(a.top - b.top));
  };
  step(before.live, now.live);
  // A word that keeps its words moves with them; a roll's copy is new each roll.
  if (before.now?.text === now.now?.text) step(before.now?.box, now.now?.box);
  if (before.out && now.out && before.out.text === now.out.text) step(before.out.box, now.out.box);
  const was = new Map(before.rows.map((row) => [row.id, row.box]));
  for (const row of now.rows) step(was.get(row.id), row.box);
  return Math.round(most * 100) / 100;
}

/// How far (px of height) the leaving words, while drawn with any ink, cross the box of any row's
/// words that was not on screen before the hand-over (the arriving call's row) in one frame.
export function overlapPx(frame: SwapFrame, arriving: ReadonlySet<string>): number {
  const out = frame.out;
  if (!out || out.ink <= 0.02) return 0;
  let most = 0;
  for (const row of frame.rows) {
    if (!arriving.has(row.id) || row.ink <= 0.02) continue;
    const words = row.textBox ?? row.box;
    const height = Math.min(out.box.bottom, words.bottom) - Math.max(out.box.top, words.top);
    const width = Math.min(out.box.right, words.right) - Math.max(out.box.left, words.left);
    if (height > 0 && width > 0) most = Math.max(most, height);
  }
  return Math.round(most * 100) / 100;
}

/// Runs `arrive-tool` on a page opened at SWAP_PAGE (with `swapFrameGate` installed) and reads every
/// frame from the one drawn before the call starts to 48 frames (400 ms) past its end; `each` sees
/// each frame as it is drawn (the stills take their picture there).
export async function recordSwap(
  page: Page,
  each?: (frame: SwapFrame, index: number, landed: number) => Promise<void>,
): Promise<{ frames: SwapFrame[]; landed: number }> {
  await page.waitForFunction(() => "__sendStream" in window);
  await page.getByText("History answer 6.").waitFor();
  const run = page.evaluate(() =>
    (window as unknown as { __sendStream: { run(options: object): Promise<unknown> } }).__sendStream
      .run({ scenario: "arrive-tool" })
      .then(() => true),
  );
  await page.waitForFunction(() => (window as unknown as { __phase?: string }).__phase === "begin");
  // The composer's stand-in and the scroller's edge fade would cover the live line on this page.
  await page.addStyleTag({
    content:
      ".acpmux-dock { visibility: hidden !important; } .acpmux-scroll, .acpmux-scroll * { mask-image: none !important; -webkit-mask-image: none !important; }",
  });
  const frames: SwapFrame[] = [];
  let landed = -1;
  for (let index = 0; index < 400 && (landed < 0 || index - landed <= 48); index += 1) {
    if (index > 0) await page.evaluate(() => (window as unknown as { __advance: () => Promise<void> }).__advance());
    const frame = await page.evaluate(readSwapFrame, TRANSCRIPT_ROW);
    if (landed < 0 && frame.phase === "land") landed = index;
    frames.push(frame);
    await each?.(frame, index, landed);
  }
  await page.evaluate(() => (window as unknown as { __release: () => void }).__release());
  await run;
  return { frames, landed };
}

/// The call's rows: rows in view after the call ends that were not before it.
export function arrivingRows(frames: SwapFrame[], landed: number): Set<string> {
  const before = new Set(frames[landed - 1]?.rows.map((row) => row.id));
  const arriving = new Set<string>();
  for (const frame of frames.slice(landed)) for (const row of frame.rows) if (!before.has(row.id)) arriving.add(row.id);
  return arriving;
}

/// Frames in which the leaving words and an arriving row are both drawn: the call's name twice.
export function drawnTwice(frame: SwapFrame, arriving: ReadonlySet<string>): boolean {
  if (!frame.out || frame.out.ink <= 0.02) return false;
  return frame.rows.some((row) => arriving.has(row.id) && row.ink > 0.02);
}
