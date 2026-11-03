import { useSyncExternalStore } from "react";

/// How a message row between agents lays out its parts: a sent message ("Sent to <chip>"), another
/// agent's received line (<chip> · host) and the head of a folded group of messages ("7 messages
/// from 6 sessions"). Leo said yes (2026-11-02) to splitting "Sent to gcp-codex-swarm-10/spinner-chatgpt
/// · and 5 more commands claude-sr2-coord: Leo's answer (v…", a count, a target and a message preview
/// truncated on one line, and of the same rows "i also think this is quite weird looking".
/// `stacked`, the default: the line holds the verb, the chip, the count and the chevron; the message's
/// first line (a group's senders) sits on its own line under it, at the text column, cut there.
/// The others are gallery versions kept beside it (MessageLineLook.gallery.ts): `single`, the one
/// line from before (cmux#29800's rows); `quiet`, the line alone, with no preview until the row
/// opens. The native host sends no value, so the default holds there.
export type MessageLineLook = "stacked" | "single" | "quiet";

const LOOKS: readonly MessageLineLook[] = ["stacked", "single", "quiet"];
let current: MessageLineLook = "stacked";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureMessageLineLook(value: unknown): void {
  const next = LOOKS.find((look) => look === value) ?? "stacked";
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
