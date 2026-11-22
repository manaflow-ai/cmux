import { useSyncExternalStore } from "react";

/// A notice the app raises about the chat's agent service (`paneNotices`, AgentPaneNotice.swift):
/// another cmux install's daemon, remote approvals off there, a peer that did not count this Mac's
/// allow. The app sends the text, already localized, and an optional button whose click goes back
/// as `pane.noticeAction {id}`. The page draws them in its notice slot above the composer, in the
/// flow: the app's own label over the page floated over the transcript's first message.
export type PaneNotice = { id: string; title: string; detail?: string; button?: string; enabled?: boolean };

const NONE: readonly PaneNotice[] = [];
let current: readonly PaneNotice[] = NONE;
const listeners = new Set<() => void>();

/// Reads the app's push; anything malformed is left out.
export function readPaneNotices(value: unknown): readonly PaneNotice[] {
  if (!Array.isArray(value)) return NONE;
  const notices: PaneNotice[] = [];
  for (const item of value) {
    if (!item || typeof item !== "object") continue;
    const { id, title, detail, button, enabled } = item as Record<string, unknown>;
    if (typeof id !== "string" || typeof title !== "string" || !title) continue;
    notices.push({
      id,
      title,
      ...(typeof detail === "string" && detail && { detail }),
      ...(typeof button === "string" && button && { button, enabled: enabled !== false }),
    });
  }
  return notices.length ? notices : NONE;
}

export function setPaneNotices(value: unknown): void {
  const next = readPaneNotices(value);
  if (next === NONE && current === NONE) return;
  current = next;
  for (const listener of listeners) listener();
}

export function paneNotices(): readonly PaneNotice[] {
  return current;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

export function usePaneNotices(): readonly PaneNotice[] {
  return useSyncExternalStore(subscribe, paneNotices, paneNotices);
}
