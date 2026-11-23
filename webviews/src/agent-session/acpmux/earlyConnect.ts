// The pane's first handshake, started when the bundle runs instead of after React's first commit.
//
// A restarted chat used to ask the host `ready` only from the pane's effect (paneSnapshot.ts
// `connectHost`), after the whole first mount, and its `transport.open` then waited behind that
// mount's main-thread work: about 300 ms of a local restart's settle went to page work before the
// socket opened (bench/first-load-after-restart.bench.ts WIRE_TRACE=1). Here `ready`, and for the
// app's bridge `transport.open`, leave before `createRoot().render`; the first `connectHost` takes
// the answers instead of asking again. Nothing here draws: the mount and its first frame are the
// same, only the host's answers are already in hand when the effect asks for them.
import { BridgeSocket } from "./bridgeSocket";
import { callNative } from "./callNative";
import { hasNativeHost } from "./native";

type Early = { ready?: Promise<{ transport?: string }>; socket?: BridgeSocket };
let early: Early | undefined;

/// Asks the host `ready` now and, when it answers with the app's bridge, opens the bridge. Once per
/// page, only where a host can answer (the app's pane, the dev slot, the benches); the gallery and
/// mock pages, which mount with no host, start nothing.
export function startEarlyConnect(): void {
  if (early || !hasNativeHost()) return;
  const ready = callNative<{ transport?: string }>("ready", {});
  const held: Early = { ready };
  early = held;
  ready.then(
    (reply) => {
      // Taken already, or dropped: whoever holds the answer opens its own socket.
      if (early !== held || reply?.transport !== "acpmux-bridge") return;
      held.socket = new BridgeSocket();
    },
    () => undefined,
  );
}

/// The early `ready` answer, once: the first handshake takes it in place of asking (Swift hands a
/// seeded prompt out once, so the page asks `ready` once for it). Undefined when none is waiting.
export function takeEarlyReady<T>(): Promise<T> | undefined {
  const held = early;
  const ready = held?.ready;
  if (!held || !ready) return undefined;
  held.ready = undefined;
  return ready as Promise<T>;
}

/// The handshake's `ready`: the early answer on the first ask, a fresh ask after it (and always on
/// a reconnect, whose params differ).
export function askReady<T>(reconnect: boolean): Promise<T> {
  return (!reconnect && takeEarlyReady<T>()) || callNative<T>("ready", reconnect ? { reconnect } : {});
}

/// The bridge socket opened with the early `ready`, once, for the first client to adopt; it says
/// how its open went to the handlers the client sets (BridgeSocket `announce`).
export function takeEarlySocket(): BridgeSocket | undefined {
  const socket = early?.socket;
  if (!socket) return undefined;
  early = undefined;
  socket.announce();
  return socket;
}

/// Closes an early socket nobody adopted (the first handshake ended without a client), so no
/// host connection stays open with no page reading it.
export function dropEarlyConnect(): void {
  const socket = early?.socket;
  early = undefined;
  socket?.close();
}
