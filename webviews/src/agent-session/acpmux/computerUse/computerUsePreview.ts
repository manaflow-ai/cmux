// The chat's live preview card of computer use (`computerUsePreview`, CmuxNextAgentPane
// AgentPaneComputerUsePreview): while this chat's agent drives an app, the host pushes the app's
// name and its newest frame; when the session ends, `done`, and the card keeps the last frame. The
// host owns the card; the page draws it and sends a click back as `chat.computerUsePreview
// {action}` (`open`: Agent Activity on the session, `close`: hide it). A module store, so a push
// that arrives before the chat mounts is kept.
//
// The card never covers the chat: while it shows, the column's end moves in by its room
// (`COMPUTER_USE_PREVIEW_RESERVE`, `--cv-inset-end`), as the Codex app narrows its chat beside the
// preview. A pane too narrow to give that room shows no card. With the Inspector open, the card sits
// under the Inspector's card (inspector/underInspector.ts) and the column keeps no room for it: the
// Inspector's own shift or push keeps the chat clear of both.
import { useSyncExternalStore } from "react";

/// The card's room at the chat's right: its 180px, 12px from the pane's edge, a 12px gap to the
/// column (computerUsePreview.css).
export const COMPUTER_USE_PREVIEW_RESERVE = 204;
/// The narrowest pane that shows the card: narrower, the column it leaves is too narrow to read.
export const COMPUTER_USE_PREVIEW_MIN_PANE = 600;

export type ComputerUsePreview = {
  /// The Computer Use session the card shows.
  session: string;
  /// The app's name ("Calculator"), or its window's title; "" when the host knows neither. The
  /// card shows no name: it is in the card's label only, which then names no app.
  app: string;
  /// The session ended: the last frame, dimmed, with the app's icon and a check.
  done: boolean;
  /// The newest frame, a `data:image/...` URL.
  frame: string;
  /// The app's icon, a `data:image/png` URL, sent with the done state when the host found one.
  icon?: string;
};

let current: ComputerUsePreview | null = null;
/// The session the person closed here: hidden at once, before the host's push that takes it away.
let closed: string | undefined;
const listeners = new Set<() => void>();

/// Only an image `data:` URL draws: the page's CSP allows `img-src data:`, and nothing else is
/// taken from the push.
const isImage = (value: unknown): value is string => typeof value === "string" && value.startsWith("data:image/");

/// The card of a host push, or null (no card, or a malformed one).
export function readComputerUsePreview(value: unknown): ComputerUsePreview | null {
  const raw = value as Partial<ComputerUsePreview> | null | undefined;
  if (!raw || typeof raw !== "object" || typeof raw.session !== "string" || !raw.session) return null;
  if (!isImage(raw.frame)) return null;
  return {
    session: raw.session,
    app: typeof raw.app === "string" ? raw.app : "",
    done: raw.done === true,
    frame: raw.frame,
    ...(isImage(raw.icon) ? { icon: raw.icon } : {}),
  };
}

/// Replaces the card from a host push.
export function setComputerUsePreview(value: unknown): void {
  const next = readComputerUsePreview(value);
  if (
    next?.session === current?.session &&
    next?.frame === current?.frame &&
    next?.done === current?.done &&
    next?.app === current?.app &&
    next?.icon === current?.icon
  )
    return;
  current = next;
  for (const listener of listeners) listener();
}

export function currentComputerUsePreview(): ComputerUsePreview | null {
  return current && current.session !== closed ? current : null;
}

/// Hides the card of `session` here at once (the close button); the host's next push agrees.
export function closeComputerUsePreview(session: string): void {
  if (closed === session) return;
  closed = session;
  for (const listener of listeners) listener();
}

/// The app's name the card's label says: trimmed, or none.
export const computerUsePreviewTitle = (preview: ComputerUsePreview): string | undefined =>
  preview.app.trim() || undefined;

const roomQuery = `(min-width: ${COMPUTER_USE_PREVIEW_MIN_PANE}px)`;
const subscribeRoom = (listener: () => void) => {
  if (typeof window === "undefined" || !window.matchMedia) return () => undefined;
  const query = window.matchMedia(roomQuery);
  query.addEventListener("change", listener);
  return () => query.removeEventListener("change", listener);
};
const hasRoom = () => typeof window === "undefined" || !window.matchMedia || window.matchMedia(roomQuery).matches;

/// Whether the pane is wide enough to show the card beside the column (the page is the pane).
export function useComputerUsePreviewRoom(): boolean {
  return useSyncExternalStore(subscribeRoom, hasRoom, hasRoom);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function useComputerUsePreview(): ComputerUsePreview | null {
  return useSyncExternalStore(subscribe, currentComputerUsePreview, currentComputerUsePreview);
}

declare global {
  interface Window {
    /// The old host's script for the `computerUsePreview` event (CmuxNextAgentPane AgentPaneComputerUsePreview).
    cmuxAcpmuxComputerUsePreview?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxComputerUsePreview = setComputerUsePreview;
