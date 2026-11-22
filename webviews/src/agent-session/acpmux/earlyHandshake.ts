// The pane's first handshake, started when its entry runs instead of after React's first commit (Leo,
// 2026-11-22: "get that gui agent chat sped up to be nearly as fast as the terminal coming back").
// A relaunched pane drew its saved copy in its first frame (chatSnapshot/boot.ts); what it waited on
// after was the app's `ready`, then the socket's open, then `initialize`, one after the other, each
// only once the pane's modules had loaded and React had committed. Here the three go out while they
// load: `ready` from the entry, the bridge's `transport.open` as soon as it answers, and `initialize`
// as the connection's first frame (BridgeSocket `prime`). The pane's own handshake takes them
// (App.tsx `connectHost`, `takeEarlyReady` and `takeEarlySocket`), so the chat's attach goes out the
// moment the pane asks for it. A page the app does not host (the dev slot, the gallery, a guest page)
// starts nothing here.
import { BridgeSocket } from "./bridgeSocket";
import { callNative } from "./callNative";
import { initializeParams } from "./initializeParams";
import { hasNativeHost } from "./native";

/// How long a socket opened here waits for the pane to take it before it is closed.
// timeout: the pane takes it within its first commit; one never taken is a page that went another way.
export const EARLY_SOCKET_UNCLAIMED_MS = 15_000;

let started = false;
let earlyReady: Promise<unknown> | undefined;
let earlySocket: BridgeSocket | undefined;
let unclaimedTimer: ReturnType<typeof setTimeout> | undefined;

/// Sends the pane's first `ready` now, and on a bridge answer opens its socket with `initialize`
/// primed. Once per page; a no-op off the app's host or where a test answers `ready` itself.
export function startEarlyHandshake(): void {
  if (started || !hasNativeHost() || window.cmuxAcpmuxActions?.ready) return;
  started = true;
  const ready = callNative<{ transport?: unknown }>("ready", {});
  earlyReady = ready;
  ready.then(
    (answered) => {
      if (answered?.transport !== "acpmux-bridge") return;
      const socket = new BridgeSocket();
      socket.prime("initialize", initializeParams());
      earlySocket = socket;
      // fixed-wait: one bound on a socket nothing took; cleared when taken, fires once.
      unclaimedTimer = setTimeout(() => {
        unclaimedTimer = undefined;
        if (earlySocket !== socket) return;
        earlySocket = undefined;
        socket.close();
      }, EARLY_SOCKET_UNCLAIMED_MS);
    },
    // The pane's handshake takes the refusal (`takeEarlyReady`) and says it.
    () => undefined,
  );
}

/// The early `ready`, once: the pane's first handshake answers with it instead of asking again.
export function takeEarlyReady<T>(): Promise<T> | undefined {
  const ready = earlyReady as Promise<T> | undefined;
  earlyReady = undefined;
  return ready;
}

/// The socket the early handshake opened, once, while it is not closed: the pane's first connect
/// uses it (its `onopen` runs again for a socket that opened already).
export function takeEarlySocket(): BridgeSocket | undefined {
  const socket = earlySocket;
  earlySocket = undefined;
  if (unclaimedTimer !== undefined) clearTimeout(unclaimedTimer);
  unclaimedTimer = undefined;
  if (!socket || socket.readyState === BridgeSocket.CLOSED) return undefined;
  if (socket.readyState === BridgeSocket.OPEN)
    queueMicrotask(() => {
      if (socket.readyState === BridgeSocket.OPEN) socket.onopen?.(new Event("open"));
    });
  return socket;
}
