// Where the chat runs, as the host last said (plans media-safety R0, leo-workspace#874). Until the
// host knows whether a chat is on this Mac (a handshake named a session but its attach reply has
// not come in), it reads no file for the agent's output: `image.load`, `media.load` and
// `link.inspect` answer `{pending: true}`. The page draws that as waiting, never as a failure.
// When the host knows, it sends the `locality` event (`{locality: "local"}`, or `{locality:
// "remote", machine}`), and the page asks again: the image cache and the link store forget what
// they must, and every waiting image, video and path chip asks the host once more. The host
// decides what loads; the page only waits and asks.
import { useSyncExternalStore } from "react";

export type Locality = { locality: "local" | "remote" | "unknown"; machine?: string };

const KINDS = new Set(["local", "remote", "unknown"]);
let current: Locality = { locality: "unknown" };
/// Bumped on each change, so an answer asked under an older locality is asked again.
let generation = 0;
const resets = new Set<(before: Locality) => void>();
const listeners = new Set<() => void>();

/// Whether a host answer is the pending refusal.
export function isPending(reply: unknown): boolean {
  return (reply as { pending?: unknown } | null | undefined)?.pending === true;
}

export function currentLocality(): Locality {
  return current;
}

export function localityGeneration(): number {
  return generation;
}

/// The host's `locality` event. A malformed value (an unknown kind, a `machine` that is not a
/// non-empty string), or the locality the page already has, changes nothing.
export function setLocality(value: unknown): void {
  const next = value as Partial<Locality> | null | undefined;
  if (!next || typeof next !== "object" || !KINDS.has(next.locality as string)) return;
  if (next.machine !== undefined && (typeof next.machine !== "string" || !next.machine)) return;
  const machine = next.machine;
  if (next.locality === current.locality && machine === current.machine) return;
  const before = current;
  current = { locality: next.locality!, ...(machine ? { machine } : {}) };
  generation += 1;
  for (const reset of resets) reset(before);
  for (const listener of listeners) listener();
}

/// Runs `reset` with the locality before each change, before any component draws again. Returns
/// the call that stops it.
export function onLocalityChange(reset: (before: Locality) => void): () => void {
  resets.add(reset);
  return () => resets.delete(reset);
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// The locality's generation: a component whose answer was pending asks again when it changes.
export function useLocalityGeneration(): number {
  return useSyncExternalStore(subscribe, localityGeneration, localityGeneration);
}

declare global {
  interface Window {
    /// The old host's script for the `locality` event (the shared page host sends it as an event).
    cmuxAcpmuxLocality?: (value: unknown) => void;
  }
}
if (typeof window !== "undefined") window.cmuxAcpmuxLocality = setLocality;
