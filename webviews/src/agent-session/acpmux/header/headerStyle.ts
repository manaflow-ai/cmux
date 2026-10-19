import { useSyncExternalStore } from "react";

/// How the chat header offers the tabs a chat opens beside it, for comparing designs (Lucas
/// 2026-10-17: "an easier and sleeker setup to add more tabs to the chat"):
/// - `buttons`: today's quick-action buttons (Changes, Preview, Terminal, Browser).
/// - `add`: one [+] that lists every tab the chat can open beside it; each pick adds one.
/// - `add-terminal`: Terminal keeps its button; [+] lists the rest.
/// - `tray`: every tab the chat can open beside it as one quiet group of icons.
/// - `labels`: that group with a word beside each icon (icons only in a narrow pane).
/// - `quiet`: the same icons with no group fill, muted, a hairline before Sources.
/// - `expand`: `quiet`, and the icon under the pointer slides open to its name.
///
/// Set live by `headerStyle` in `agent-pane/layout.json` (the App pushes the file to every chat), or
/// in the dev server by `?data-chat-header=add`. Unset or unknown is `buttons`.
export type HeaderStyle = "buttons" | "add" | "add-terminal" | "tray" | "labels" | "quiet" | "expand";

const STYLES: readonly HeaderStyle[] = ["buttons", "add", "add-terminal", "tray", "labels", "quiet", "expand"];
const isStyle = (value: unknown): value is HeaderStyle => STYLES.includes(value as HeaderStyle);

let fromLayout: HeaderStyle | undefined;
const listeners = new Set<() => void>();

/// The host pushed `layout.json` (or `{}` when it was removed): the header follows at once.
export function configureHeaderStyle(layout: Record<string, unknown> | undefined): void {
  const value = layout?.headerStyle;
  const next = isStyle(value) ? value : undefined;
  if (next === fromLayout) return;
  fromLayout = next;
  for (const listener of listeners) listener();
}

/// The header style now: layout.json's, else the page's `data-chat-header`, else `buttons`.
export function headerStyle(): HeaderStyle {
  if (fromLayout) return fromLayout;
  const attribute = typeof document === "undefined" ? undefined : document.documentElement.dataset.chatHeader;
  return isStyle(attribute) ? attribute : "buttons";
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// The live header style.
export const useHeaderStyle = (): HeaderStyle => useSyncExternalStore(subscribe, headerStyle, headerStyle);

/// The thread's project and title at the header's start (header/ThreadTitle.tsx), for trying the
/// design: `threadTitle: true` in `agent-pane/layout.json`, or `?data-thread-title=on` in the dev server.
let threadTitleOn = false;

export function configureThreadTitle(layout: Record<string, unknown> | undefined): void {
  const next = layout?.threadTitle === true;
  if (next === threadTitleOn) return;
  threadTitleOn = next;
  for (const listener of listeners) listener();
}

const threadTitleShown = () =>
  threadTitleOn || (typeof document !== "undefined" && document.documentElement.dataset.threadTitle === "on");

/// Whether the header shows the thread's project and title.
export const useThreadTitle = (): boolean => useSyncExternalStore(subscribe, threadTitleShown, threadTitleShown);

/// Pointer cursors on the composer's controls (Lucas 2026-10-17; today's arrow, Leo's Codex-like press,
/// stays the default): `pointerCursor: true` in `agent-pane/layout.json` sets `data-pointer-cursor` on
/// `<html>`, which composerControls.css reads.
export function configurePointerCursor(layout: Record<string, unknown> | undefined): void {
  if (typeof document === "undefined") return;
  if (layout?.pointerCursor === true) document.documentElement.dataset.pointerCursor = "on";
  else delete document.documentElement.dataset.pointerCursor;
}
