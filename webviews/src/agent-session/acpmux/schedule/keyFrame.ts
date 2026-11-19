/**
 * The frame after a key draws the key first (cmuxterm-hq docs/design/chat-instant-under-load.md, "input"
 * lane; Leo, 2026-11-17: "we're not waiting for ui to render. we're just gonna have the text be drawn fast").
 *
 * A streamed reply commits in a frame callback; when a key lands, the next frame used to carry both the
 * composer's echo and the transcript's commit, its React render, layout and the rows' restyle, so the
 * character showed only after the stream's work. `keyFrame(frameTime)` says a key was handled in the
 * display interval before `frameTime`: the stream's frame work (`nextFrame` in direct.ts) then waits one
 * frame, once, and the key's frame paints the composer alone. The stream loses one intermediate state per
 * key, never a frame and never text: its next frame draws everything that arrived.
 *
 * Every agent chat page shares one renderer and so one main thread (CEFSwitches.swift
 * `processPerSitePageSchemes`): a key typed in one chat also waited behind every other chat's stream
 * commit in that frame. The page that takes the key says so on a same-origin BroadcastChannel, and
 * every other chat page's stream work waits that frame too.
 *
 * Capture-phase listeners on the window and one channel, installed once on first use; nothing runs
 * between keys.
 */

/** A key handled this long before a frame's start makes it that key's frame (one 60 Hz interval). */
export const KEY_FRAME_MS = 17;

const KEY_EVENTS = ["keydown", "beforeinput", "compositionupdate"] as const;
const CHANNEL = "cmux-agent-key-frame";

let lastKeyAt = Number.NEGATIVE_INFINITY;
let listening = false;

function listen(): void {
  if (listening || typeof performance === "undefined") return;
  listening = true;
  const channel = typeof BroadcastChannel === "function" ? new BroadcastChannel(CHANNEL) : undefined;
  if (channel) channel.onmessage = keyInAnotherPage;
  // One post per key: `beforeinput` and `compositionupdate` follow their keydown in the same interval.
  const mark = (event: Event) => {
    lastKeyAt = performance.now();
    if (event.type === "keydown") channel?.postMessage(0);
  };
  if (typeof window === "undefined") return;
  for (const type of KEY_EVENTS) window.addEventListener(type, mark, { capture: true, passive: true });
}

/** Another chat page of this renderer took a key (its channel message): this page's next frame is that key's. */
export function keyInAnotherPage(): void {
  lastKeyAt = performance.now();
}

/** Whether a key was handled within KEY_FRAME_MS before `frameTime` (a rAF timestamp). */
export function keyFrame(frameTime: number): boolean {
  listen();
  return frameTime - lastKeyAt < KEY_FRAME_MS;
}

/** Starts listening before the first frame asks (the pane calls it at mount). */
export function watchKeys(): void {
  listen();
}

/** For tests: a key handled at `at` (performance.now time). */
export function noteKeyForTest(at: number): void {
  lastKeyAt = at;
}
