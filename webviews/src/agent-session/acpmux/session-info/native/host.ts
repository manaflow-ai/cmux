// Whether the App draws Session Info for this page (the host's `sessionInfoHost` event, model.ts), and
// the clicks it hands back (`sessionInfoAction`): each runs the action the page's last model named.
import { useSyncExternalStore } from "react";
import { NATIVE_ACTION_ID_MAX, type NativeInfoActions, type NativeInfoRect } from "./model";

let drawn = false;
const listeners = new Set<() => void>();
let actions: NativeInfoActions | undefined;
/// The panel's own actions (its width, a fold, Esc), which no row names.
let own: ((id: string) => boolean) | undefined;

/// The host said whether it draws Session Info.
export function setNativeSessionInfoHost(on: unknown): void {
  const next = on === true;
  if (next === drawn) return;
  drawn = next;
  for (const listener of listeners) listener();
}

export function nativeSessionInfoDrawn(): boolean {
  return drawn;
}

/// Whether the App draws Session Info, following the host.
export function useNativeSessionInfoHost(): boolean {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    nativeSessionInfoDrawn,
    () => false,
  );
}

/// The model the page sent last: its row actions, and the panel's own handler.
export function setNativeSessionInfoActions(
  next: NativeInfoActions | undefined,
  panel?: (id: string) => boolean,
): void {
  actions = next;
  own = panel;
}

/// A click in the App's panel: the page's row action by `id`, else the panel's own.
export function runNativeSessionInfoAction(value: unknown): void {
  const event = value && typeof value === "object" ? (value as { id?: unknown; rect?: unknown }) : undefined;
  const id = event ? event.id : value;
  if (typeof id !== "string" || id.length === 0 || id.length > NATIVE_ACTION_ID_MAX) return;
  let rect: NativeInfoRect | undefined;
  if (event?.rect !== undefined) {
    const box = event.rect as Partial<NativeInfoRect> | null;
    if (!box || ![box.left, box.top, box.right, box.bottom].every((n) => typeof n === "number" && Number.isFinite(n)))
      return;
    rect = box as NativeInfoRect;
    if (rect.right < rect.left || rect.bottom < rect.top) return;
  }
  if (actions?.run(id, rect)) return;
  own?.(id);
}

declare global {
  interface Window {
    /// The old host's scripts (CmuxNextAgentPane AgentPaneSessionInfo): the page host sends events.
    cmuxAcpmuxSessionInfo?: { host(on: unknown): void; action(id: unknown): void };
  }
}

if (typeof window !== "undefined") {
  window.cmuxAcpmuxSessionInfo = { host: setNativeSessionInfoHost, action: runNativeSessionInfoAction };
}
