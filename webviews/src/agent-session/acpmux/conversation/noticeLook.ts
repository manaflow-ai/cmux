import { useSyncExternalStore } from "react";

/// How a tool's notice line draws (IncomingMessageCard.tsx, agentNotice.ts). `mark`, the default:
/// the severity's mark in the tool rows' icon column (fire a filled red disc, warn an amber
/// triangle, info a quiet ring), the sender and its machine, then the title in the rows' tone. The
/// others are gallery versions kept beside it (NoticeRow.gallery.ts): `tag`, the sender's agent mark
/// in the icon column and the severity as a small word before the title (Codex's review findings'
/// "P1"); `tint`, the `mark` line with a fire's or warning's title in its colour. The native host
/// sends no value, so the default holds there.
export type NoticeLook = "mark" | "tag" | "tint";

const LOOKS: readonly NoticeLook[] = ["mark", "tag", "tint"];
let current: NoticeLook = "mark";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureNoticeLook(value: unknown): void {
  const next = LOOKS.find((look) => look === value) ?? "mark";
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
export const useNoticeLook = (): NoticeLook => useSyncExternalStore(subscribe, snapshot, snapshot);

/// What an opened notice says (agentNotice.ts `openedNoticeText`). `body`, the default: its body, else
/// its title. The others are gallery versions kept beside it (NoticeRow.gallery.ts): `title-body`,
/// its title whole above the body; `wrap`, the body alone, the line's title wrapping whole while
/// open. The native host sends no value, so the default holds there.
export type NoticeBodyLook = "body" | "title-body" | "wrap";

const BODY_LOOKS: readonly NoticeBodyLook[] = ["body", "title-body", "wrap"];
let body: NoticeBodyLook = "body";

/// The theme carried a body look: the transcript follows at once. Anything else keeps the default.
export function configureNoticeBodyLook(value: unknown): void {
  const next = BODY_LOOKS.find((look) => look === value) ?? "body";
  if (next === body) return;
  body = next;
  for (const listener of listeners) listener();
}

const bodySnapshot = () => body;

/// The body look now.
export const useNoticeBodyLook = (): NoticeBodyLook => useSyncExternalStore(subscribe, bodySnapshot, bodySnapshot);
