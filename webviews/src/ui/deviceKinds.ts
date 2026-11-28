import { useSyncExternalStore } from "react";
import kinds from "./deviceGlyphKinds.json";

/// What a device is (`mac-mini`, `linux-server`, `iphone`), as acpmux reports it
/// (cmux-tui/crates/cmux-device-kind). `deviceGlyphKinds.json` is that crate's kind-to-glyph table,
/// written and kept current by its test `web_glyph_table_is_current`.
export type DeviceKind = keyof typeof kinds;

export const DEVICE_KINDS = Object.keys(kinds) as DeviceKind[];

/// The SF Symbol each kind draws, the same name the native views draw.
export const DEVICE_SYMBOLS: Readonly<Record<DeviceKind, string>> = kinds;

/// A wire name as a kind; anything else (absent, a newer daemon's kind) is undefined.
export function deviceKindOf(name: unknown): DeviceKind | undefined {
  return typeof name === "string" && Object.hasOwn(kinds, name) ? (name as DeviceKind) : undefined;
}

/// The kind whose glyph is the SF Symbol `symbol` (each kind has its own; the native records name the
/// symbol); undefined for anything else.
export function deviceKindOfSymbol(symbol: unknown): DeviceKind | undefined {
  return DEVICE_KINDS.find((kind) => DEVICE_SYMBOLS[kind] === symbol);
}

/// What the daemon said of each machine: this one (`_acpmux/status` `device`) and each peer
/// (`peers[].health.device`), by peer name. Kept here, as `machineColor` keeps its colors by name,
/// so every view that draws a machine reads it without a prop through every layer.
type Known = { local?: DeviceKind; peers: Readonly<Record<string, DeviceKind>> };
let known: Known = { peers: {} };
const listeners = new Set<() => void>();

/// The kinds in an `_acpmux/status` reply.
export function deviceKindsFromStatus(status: unknown): Known {
  const reply = (status ?? {}) as { device?: unknown; peers?: unknown };
  const peers: Record<string, DeviceKind> = {};
  if (Array.isArray(reply.peers)) {
    for (const peer of reply.peers) {
      const row = (peer ?? {}) as { name?: unknown; transport?: unknown; url?: unknown; health?: { device?: unknown } };
      // A `ws://`/`wss://` peer is a Cloud machine by its source (as `cmux device list` and the
      // native sidebar decide): it stays the cloud, whatever its VM reports.
      const cloud =
        row.transport === "ws" ||
        row.transport === "wss" ||
        (typeof row.url === "string" && /^wss?:\/\//.test(row.url));
      const kind = cloud ? "cloud" : deviceKindOf(row.health?.device);
      if (typeof row.name === "string" && row.name && kind) peers[row.name] = kind;
    }
  }
  const local = deviceKindOf(reply.device);
  return local ? { local, peers } : { peers };
}

/// Records a status read's kinds. A reply without a kind keeps what an earlier one said: a peer
/// whose health is not read yet stays the device it was.
export function noteDeviceKinds(status: unknown): void {
  const next = deviceKindsFromStatus(status);
  const merged: Known = { local: next.local ?? known.local, peers: { ...known.peers, ...next.peers } };
  if (merged.local === known.local && sameKinds(merged.peers, known.peers)) return;
  known = merged;
  for (const listener of listeners) listener();
}

function sameKinds(a: Readonly<Record<string, DeviceKind>>, b: Readonly<Record<string, DeviceKind>>): boolean {
  const keys = Object.keys(a);
  return keys.length === Object.keys(b).length && keys.every((key) => a[key] === b[key]);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// The kind of this machine (`machine` absent) or of the peer `machine` names, once the daemon said.
export function knownDeviceKind(machine?: string): DeviceKind | undefined {
  return machine === undefined ? known.local : known.peers[machine];
}

/// [`knownDeviceKind`], re-rendering when a status read changes it.
export function useDeviceKind(machine?: string): DeviceKind | undefined {
  return useSyncExternalStore(
    subscribe,
    () => knownDeviceKind(machine),
    () => knownDeviceKind(machine),
  );
}

/// Tests and gallery states: forget every kind.
export function resetDeviceKinds(next: Known = { peers: {} }): void {
  known = next;
  for (const listener of listeners) listener();
}
