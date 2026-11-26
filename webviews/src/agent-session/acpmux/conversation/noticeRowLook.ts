import { useSyncExternalStore } from "react";

/// How an inbox thread whose newest message is a tool's notice draws (InboxNoticeCard.tsx, acpmux's
/// `notice` part, hub/inbox.rs): one compact line naming the detector (`now`), not the relay host,
/// its title with no `[notice from … on …]` head, and "×N, last HH:MMZ" when its condition repeated;
/// its chevron opens the whole text (Leo, 2026-11-25: "how can we improve this?"). `dot`, the
/// default: the severity's mark (NoticeMark.tsx) in the icon column. The others are gallery versions
/// kept beside it (InboxNotice.gallery.ts): `tint`, the same line tinted by its severity; `trailing`,
/// the sender's own mark kept and the severity's after the title; `off`, the line as it drew before
/// (the relay's name, the raw head). The native host sends no value, so the default holds there.
export type NoticeRowLook = "dot" | "tint" | "trailing" | "off";

const LOOKS: readonly NoticeRowLook[] = ["dot", "tint", "trailing", "off"];
let current: NoticeRowLook = "dot";
const listeners = new Set<() => void>();

/// The theme carried a look: the transcript follows at once. Anything else keeps the default.
export function configureNoticeRowLook(value: unknown): void {
  const next = LOOKS.find((look) => look === value) ?? "dot";
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
export const useNoticeRowLook = (): NoticeRowLook => useSyncExternalStore(subscribe, snapshot, snapshot);

/// The look now, outside React (the row estimator, model.ts).
export const noticeRowLook = (): NoticeRowLook => current;
