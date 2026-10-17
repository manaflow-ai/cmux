import { useSyncExternalStore } from "react";

/// How the chat header offers the tabs a chat opens beside it, for comparing designs (Lucas
/// 2026-10-17: "an easier and sleeker setup to add more tabs to the chat"):
/// - `buttons`: today's quick-action buttons (Changes, Preview, Terminal, Browser).
/// - `add`: one [+] that lists every tab the chat can open beside it; each pick adds one.
/// - `add-terminal`: Terminal keeps its button; [+] lists the rest.
///
/// Set live by `headerStyle` in `agent-pane/layout.json` (the App pushes the file to every chat), or
/// in the dev server by `?data-chat-header=add`. Unset or unknown is `buttons`.
export type HeaderStyle = "buttons" | "add" | "add-terminal";

const STYLES: readonly HeaderStyle[] = ["buttons", "add", "add-terminal"];
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
