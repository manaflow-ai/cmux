// Live elapsed labels ("Working for 42s", a running subagent's time): one clock for the whole pane.
// A live label registers its node and a text function; the clock wakes once a second, on the wall
// clock's second boundary, and writes each node's text itself, so a pane with many running agents
// commits nothing to React per second. While the pane is hidden the clock sleeps; when the pane
// shows again it writes every label at once and resumes.
import { useCallback, useLayoutEffect, useRef, type RefCallback } from "react";

type Entry = { node: HTMLElement; text: (now: number) => string; now: () => number };

const entries = new Set<Entry>();
let timer: ReturnType<typeof setTimeout> | undefined;
let listening = false;

const hidden = () => globalThis.document?.hidden === true;

function write(entry: Entry): void {
  const next = entry.text(entry.now());
  if (entry.node.textContent !== next) entry.node.textContent = next;
}

function sleep(): void {
  if (timer === undefined) return;
  clearTimeout(timer);
  timer = undefined;
}

/// Wakes just after the next whole second, so every label turns over together.
function schedule(): void {
  if (timer !== undefined || entries.size === 0 || hidden()) return;
  timer = setTimeout(tick, 1001 - (Date.now() % 1000));
}

function tick(): void {
  timer = undefined;
  for (const entry of entries) write(entry);
  schedule();
}

function onVisibility(): void {
  if (hidden()) return sleep();
  for (const entry of entries) write(entry);
  schedule();
}

function listen(on: boolean): void {
  const doc = globalThis.document;
  if (!doc || on === listening) return;
  if (on) doc.addEventListener("visibilitychange", onVisibility);
  else doc.removeEventListener("visibilitychange", onVisibility);
  listening = on;
}

/// Writes `text(now())` into `node` now and on every tick until the returned stop runs.
export function watchLive(node: HTMLElement, text: (now: number) => string, now: () => number = Date.now): () => void {
  const entry: Entry = { node, text, now };
  entries.add(entry);
  write(entry);
  listen(true);
  schedule();
  return () => {
    entries.delete(entry);
    if (entries.size > 0) return;
    sleep();
    listen(false);
  };
}

/// A ref for an element whose only content is `text`: written at every render (a prop change
/// shows at once) and, while `live`, on every tick of the shared clock. React never renders the
/// element's children, so the clock's writes and React's never meet.
export function useLiveText(
  text: (now: number) => string,
  live: boolean,
  now: () => number = Date.now,
): RefCallback<HTMLElement> {
  const latest = useRef({ text, now });
  latest.current = { text, now };
  const element = useRef<HTMLElement | null>(null);
  useLayoutEffect(() => {
    const node = element.current;
    if (!node) return;
    const next = text(now());
    if (node.textContent !== next) node.textContent = next;
  });
  useLayoutEffect(() => {
    const node = element.current;
    if (!node || !live) return;
    return watchLive(
      node,
      (time) => latest.current.text(time),
      () => latest.current.now(),
    );
  }, [live]);
  return useCallback((node: HTMLElement | null) => {
    element.current = node;
  }, []);
}

/// How many labels the clock serves and how many timers it holds (tests).
export const liveClockStats = {
  timers: (): number => (timer === undefined ? 0 : 1),
  entries: (): number => entries.size,
};
