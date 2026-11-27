// How an agent reply's text shows while it streams (`agentPane.display.streaming`, Settings > Agent
// Chat; a theme or profile file may set it, docs/cmux-next/transcript-customization.md):
//   - `words` (the default): the reply grows a whole word at a time and its newest words fade in
//     (revealedMarkdownModel.ts useStreamReveal), the chat as it drew before the setting;
//   - `lines`: the same reveal, ending at a whole line instead of a whole word; a line still arriving
//     shows once text stops arriving (StreamReveal.stallMs), as a held word does;
//   - `instant`: text shows as it arrives, with no fade, as Reduce Motion draws it.
// No new effect: each value is the reveal's existing model with a different edge or none.
import { useSyncExternalStore } from "react";

export const STREAMING_STYLE_KEY = "agentPane.display.streaming";
export type StreamingStyle = "words" | "lines" | "instant";
export const STREAMING_STYLES: readonly StreamingStyle[] = ["words", "lines", "instant"];
export const DEFAULT_STREAMING_STYLE: StreamingStyle = "words";

export const isStreamingStyle = (value: unknown): value is StreamingStyle =>
  value === "words" || value === "lines" || value === "instant";

/** The style from the host's display map; anything else keeps `words`. */
export function resolveStreamingStyle(values: Record<string, unknown> | undefined): StreamingStyle {
  const value = values?.[STREAMING_STYLE_KEY];
  return isStreamingStyle(value) ? value : DEFAULT_STREAMING_STYLE;
}

let current: StreamingStyle = DEFAULT_STREAMING_STYLE;
const listeners = new Set<() => void>();

/** The host's display push (chatDisplay.ts `setChatDisplay`): replies streaming now follow at once. */
export function configureStreamingStyle(values: Record<string, unknown> | undefined): void {
  const next = resolveStreamingStyle(values);
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

export const streamingStyle = (): StreamingStyle => current;
export const useStreamingStyle = (): StreamingStyle => useSyncExternalStore(subscribe, snapshot, snapshot);

/// The end of the text to show in `lines`: after the last line break that has arrived, never less
/// than what shows (`shown`); all of it once the stream is done or released.
export function lineEdge(text: string, raw: number, done: boolean, shown: number): number {
  const limit = Math.min(raw, text.length);
  if (done) return limit;
  const end = text.lastIndexOf("\n", limit - 1) + 1;
  return Math.max(end, Math.min(shown, text.length));
}
