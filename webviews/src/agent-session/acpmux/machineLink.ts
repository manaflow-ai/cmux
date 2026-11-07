import { useSyncExternalStore } from "react";

/// `machine` is the app's registry id (what its Reconnect names); `name` what the sidebar header
/// calls it (an older app sends none).
export type MachineLink = { machine: string; name?: string; link: string; words: string };

let current: MachineLink | null = null;
const listeners = new Set<() => void>();

export function setMachineLink(value: unknown): void {
  const next = readMachineLink(value);
  if (
    next?.machine === current?.machine &&
    next?.name === current?.name &&
    next?.link === current?.link &&
    next?.words === current?.words
  )
    return;
  current = next;
  for (const listener of listeners) listener();
}

export function readMachineLink(value: unknown): MachineLink | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw.machine !== "string" || typeof raw.link !== "string" || typeof raw.words !== "string") return null;
  return {
    machine: raw.machine,
    ...(typeof raw.name === "string" && raw.name ? { name: raw.name } : {}),
    link: raw.link,
    words: raw.words,
  };
}

export function machineLink(): MachineLink | null {
  return current;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => void listeners.delete(listener);
}

export function useMachineLink(): MachineLink | null {
  return useSyncExternalStore(subscribe, machineLink, machineLink);
}

/// A machine link as the composer's quiet row draws it (MachineLinkStatus.tsx): the sidebar's
/// `MachineLinkState` (connected, connecting, offline, paused, attention) and the sidebar header's
/// own word for it (`statusWords`: "Reconnecting…", "Offline").
export type LinkState = "connected" | "connecting" | "offline" | "paused" | "attention";

export type PaneLink = {
  /// The machine the chat runs on: the app's registry id for a machine it keeps, the peer's name for an
  /// acpmux peer.
  machine: string;
  /// What the row writes for it: the sidebar header's name (`machine` when none).
  name?: string;
  link: LinkState;
  /// The app's own word for the state of a machine it keeps (the sidebar header's); a peer's state
  /// is written from `link` and `reconnecting` (MachineLinkStatus.tsx `linkWords`).
  words?: string;
  /// A peer link coming back rather than coming up the first time: "Reconnecting…", not "Connecting…".
  reconnecting?: true;
  /// Whose link it is, so Reconnect asks the one that keeps it: the app's machine registry
  /// (`machine.reconnect` on this tab's machine) or this Mac's acpmux (`_acpmux/peer_reconnect`).
  source: "app" | "peer";
};

const LINK_STATES = new Set<string>(["connected", "connecting", "offline", "paused", "attention"]);

/// acpmux's peer link states (`peer_link.rs` `as_str`) in the sidebar's words: a link that has not
/// finished its handshake again is on its way (`degraded`, `restarting`, `reconnecting`).
const PEER_LINKS: Record<string, { link: LinkState; reconnecting?: true }> = {
  connected: { link: "connected" },
  connecting: { link: "connecting" },
  degraded: { link: "connecting", reconnecting: true },
  reconnecting: { link: "connecting", reconnecting: true },
  restarting: { link: "connecting", reconnecting: true },
  offline: { link: "offline" },
};

type LinkSnapshot = {
  summary?: { peer?: string } | undefined;
  peerKinds?: Record<string, "ssh" | "cloud"> | undefined;
  peerStates?: Record<string, string> | undefined;
  peerConnected?: Record<string, boolean> | undefined;
};

/// The link of the machine the open chat runs on, or null for a chat on this Mac. The app's push
/// (`machineLink`, a machine it keeps: an SSH machine, a Cloud machine) comes first; a chat on an
/// acpmux peer (the session this Mac's acpmux mirrors, `summary.peer`) reads that peer's link as
/// acpmux last said it (`peerStates`, kept current by `_acpmux/peer_state_changed`). A Cloud peer
/// that is not answering says nothing here: the peer copy banner says whether it is paused or
/// starting, and offers Resume (PeerCopyBanner.tsx). O(1).
export function paneLink(native: MachineLink | null, snapshot: LinkSnapshot): PaneLink | null {
  if (native && LINK_STATES.has(native.link) && native.machine)
    return {
      machine: native.machine,
      ...(native.name ? { name: native.name } : {}),
      link: native.link as LinkState,
      words: native.words,
      source: "app",
    };
  const peer = snapshot.summary?.peer;
  if (!peer) return null;
  const said = snapshot.peerStates?.[peer];
  const known: { link: LinkState; reconnecting?: true } | undefined =
    said !== undefined
      ? PEER_LINKS[said]
      : snapshot.peerConnected?.[peer] === undefined
        ? undefined
        : { link: snapshot.peerConnected[peer] ? ("connected" as const) : ("offline" as const) };
  if (!known) return null;
  if (known.link === "offline" && snapshot.peerKinds?.[peer] === "cloud") return null;
  return { machine: peer, link: known.link, source: "peer", ...(known.reconnecting ? { reconnecting: true } : {}) };
}
