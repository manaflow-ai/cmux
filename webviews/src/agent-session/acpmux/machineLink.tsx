import { useSyncExternalStore } from "react";
import { Spinner } from "./conversation/icons";
import type { Environment } from "./environments";
import { translate as t, type StringKey } from "./i18n";

/// A machine's link as the composer strip draws it (Leo, 2026-10-28: "you just get a little green
/// dot ... as if you were working on your own computer, but now it's remote"): green only once its
/// handshake finished, a spinner while it connects or reconnects (never a pulsing dot), red when
/// it is down. The sidebar's machine header draws the same word (CmuxNextSidebar MachineLinkState).
/// `paused` is a Cloud machine its owner or the idle pause parked; `attention` one that needs
/// cmux-tui installed.
export type MachineLink = "connected" | "connecting" | "offline" | "paused" | "attention";

/// The App's `machineLink` push (AgentPaneMachineLink.swift): the link of the machine this pane's
/// chat runs on, for a chat on another machine; none for a chat on this Mac.
export type PaneMachineLink = { machine: string; link: MachineLink; words: string };

const LINKS: readonly MachineLink[] = ["connected", "connecting", "offline", "paused", "attention"];
let current: PaneMachineLink | undefined;
const listeners = new Set<() => void>();

/// The App's push; anything that is not a known link clears it (a chat on this Mac).
export function setMachineLink(value: unknown): void {
  const raw = (value ?? {}) as { machine?: unknown; link?: unknown; words?: unknown };
  const link = LINKS.find((known) => known === raw.link);
  const next =
    link && typeof raw.machine === "string"
      ? { machine: raw.machine, link, words: typeof raw.words === "string" ? raw.words : "" }
      : undefined;
  if (next?.machine === current?.machine && next?.link === current?.link && next?.words === current?.words) return;
  current = next;
  for (const listener of listeners) listener();
}

/// The App's word for this pane's machine now.
export const paneMachineLink = (): PaneMachineLink | undefined => current;
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// The link of the machine this pane's chat runs on, as the App pushes it.
export const usePaneMachineLink = (): PaneMachineLink | undefined => useSyncExternalStore(subscribe, paneMachineLink, paneMachineLink);

/// A peer's link from acpmux's word for it (peer_link.rs `PeerState`): `connected` only once its
/// handshake finished (a `degraded` link has not), connecting or reconnecting on its way, and
/// down otherwise. From a daemon that names no state, its `connected` flag; nothing when it said
/// nothing (a Cloud chat's host acpmux does not list).
export function peerLink(environment: Pick<Environment, "kind" | "state" | "connected">): MachineLink | undefined {
  if (environment.kind === "local") return undefined;
  switch (environment.state) {
    case "connected":
      return "connected";
    case "connecting":
    case "reconnecting":
    case "degraded":
      return "connecting";
    case undefined:
      return environment.connected === undefined ? undefined : environment.connected ? "connected" : "offline";
    default:
      return "offline";
  }
}

/// A computer's link in the strip and the machine list. `local` is the machine this pane's acpmux
/// runs on: this Mac draws none, and a chat the App runs on another machine (whose page sees that
/// machine as its own) draws the App's word (`pane`). A peer draws acpmux's.
export function computerLink(
  computer: Pick<Environment, "id" | "kind" | "state" | "connected">,
  pane: PaneMachineLink | undefined,
): MachineLink | undefined {
  return computer.id === "local" ? pane?.link : peerLink(computer);
}

/// A machine acpmux lists, or this chat's own, that is down or on its way: a pick, which
/// reconnects it. A chat's machine acpmux no longer lists stays no pick.
export function pickableDown(computer: Pick<Environment, "id" | "listed" | "link">): boolean {
  return computer.link !== undefined && (computer.id === "local" || computer.listed === true);
}

/// Whether picking or sending to a machine with this link reconnects it first.
export const reconnectsOnUse = (link: MachineLink | undefined): boolean => link === "offline";

const WORDS: Record<MachineLink, StringKey> = {
  connected: "composer.envConnected",
  connecting: "header.reconnecting",
  offline: "composer.envNotConnected",
  paused: "composer.envNotConnected",
  attention: "composer.envNotConnected",
};

/// The link in words ("Connected", "Reconnecting…"): `words` when the App gave them (this pane's
/// own machine), else the strip's own.
export const linkWords = (link: MachineLink, words?: string): string => words || t(WORDS[link]);

/// The link as one mark: a dot in its color, or the turning ring while the machine is on its way.
/// `words` names it for VoiceOver (the App's words for this pane's own machine).
export function MachineLinkMark({ link, words }: { link: MachineLink; words?: string }) {
  const label = linkWords(link, words);
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a CSS dot or the ring, named as one image
    <span className="acpmux-link-mark" data-link={link} role="img" aria-label={label}>
      {link === "connecting" && <Spinner size={10} strokeWidth={1.75} loading />}
    </span>
  );
}
