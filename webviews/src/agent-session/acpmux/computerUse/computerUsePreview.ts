// The chat's live preview card of computer use (`computerUsePreview`, CmuxNextAgentPane
// AgentPaneComputerUsePreview): while this chat's agent drives an app, the host pushes the app's
// name and its newest frame; when the session ends, `done`, and the card keeps the last frame. The
// host owns the card; the page draws it and sends a click back as `chat.computerUsePreview
// {action}` (`open`: Agent Activity on the session, `close`: hide it). A module store, so a push
// that arrives before the chat mounts is kept.
import { useSyncExternalStore } from "react";

export type ComputerUsePreview = {
  /// The Computer Use session the card shows.
  session: string;
  /// The app's name, as the helper reports it ("" when it named none).
  app: string;
  /// The session ended: the last frame, dimmed, with the app's icon and a check.
  done: boolean;
  /// The newest frame, a `data:image/...` URL.
  frame: string;
  /// The app's icon, a `data:image/png` URL, when the host found one.
  icon?: string;
};

let current: ComputerUsePreview | null = null;
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
  return current;
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
