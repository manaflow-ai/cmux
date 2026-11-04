import { useSyncExternalStore } from "react";

/// How a message row between agents lays out its parts: a sent message ("Sent to <chip>"), another
/// agent's received line (<chip> · host) and the head of a folded group of messages ("7 messages
/// from 6 sessions").
/// `single`, the default: one line, the verb, the chip, the count, the message's first line (a
/// group's senders) cut by one ellipsis, then the chevron. Leo, 2026-11-03, of the stacked rows:
/// "i don't think these subtitles are as good as just doing it directly in the same line" and "idk
/// why names are ellipses'd so early", so the first line gives way before the name does
/// (AgentMessageRow.css, conversation.css `.cv-received__sender`).
/// The others are gallery versions kept beside it (MessageLineLook.gallery.ts): `stacked` (cmux#33249,
/// after Leo's 2026-11-02 "i also think this is quite weird looking" of the one cut line), the first
/// line on its own line under the row; `quiet`, the line alone, with no preview until the row opens.
/// The native host sends no value, so the default holds there.
export type MessageLineLook = "stacked" | "single" | "quiet";

const LOOKS: readonly MessageLineLook[] = ["stacked", "single", "quiet"];
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
