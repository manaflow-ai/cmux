// Stub (red commit): the shared live clock lands in the next commit.
import type { RefCallback } from "react";

export function watchLive(_node: HTMLElement, _text: (now: number) => string, _now?: () => number): () => void {
  return () => {};
}

export function useLiveText(
  _text: (now: number) => string,
  _live: boolean,
  _now?: () => number,
): RefCallback<HTMLElement> {
  return () => {};
}

export const liveClockStats = { timers: (): number => 0, entries: (): number => 0 };
