import { useSyncExternalStore } from "react";

/// How a message row between agents lays out its parts: a sent message ("Sent to <chip>"), another
/// agent's received line (<chip> · host) and the head of a folded group of messages ("7 messages
/// from 6 sessions").
/// `single`, the default: one line, the verb, the chip at its whole width, the count, the message's
/// first line muted after them and cut with the line's one ellipsis, then the chevron right after the
/// words. Leo, 2026-11-03, on the stacked rows: "i don't think these subtitles are as good as just
/// doing it directly in the same line", and "idk why names are ellipses'd so early". This replaced
/// `stacked` (cmux#33249), which put the first line on its own line under the row after Leo said yes
/// (2026-11-02) to splitting "Sent to gcp-codex-swarm-10/spinner-chatgpt · and 5 more commands
/// claude-sr2-coord: Leo's answer (v…": that line cut the chip, count and preview together, so the name
/// now never shrinks while the preview has room to give.
/// The others are gallery versions kept beside it (MessageLineLook.gallery.ts): `stacked`, the first
/// line under the row; `quiet`, the line alone, with no preview until the row opens. The native host
/// sends no value, so the default holds there.
export type MessageLineLook = "single" | "stacked" | "quiet";

const LOOKS: readonly MessageLineLook[] = ["single", "stacked", "quiet"];
let current: MessageLineLook = "single";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureMessageLineLook(value: unknown): void {
  const next = LOOKS.find((look) => look === value) ?? "single";
  if (next === current) return;
  current = next;
  for (const listener of listeners) listener();
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// The look now.
export const useMessageLineLook = (): MessageLineLook => useSyncExternalStore(subscribe, snapshot, snapshot);

/// The look now, outside React (the row estimator, model.ts).
export const messageLineLook = (): MessageLineLook => current;

/// The preview line's height under a stacked message row, in points: `--cv-message-preview-line`
/// (AgentMessageRow.css), the detail size's line. model.ts adds it to a stacked row with a preview.
export const MESSAGE_PREVIEW_LINE_PT = 18;
