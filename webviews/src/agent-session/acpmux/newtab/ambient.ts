// The New Tab page's ambient widgets (`tabs.newTabWidgets.weather|machines`): a quiet row under the
// composer, so turning one on never moves the field. Weather is the app's last Open-Meteo reading
// (the handshake's `weather`, AgentPaneNewTabWeather.swift); Machines are the composer's computers
// (acpmux's peers and the hosts its chats ran on) and the account's Cloud machines, each with its
// live link, as buttons that start the next chat there, plus Add Machine… (Leo, 2026-10-26: "in
// the new tab page ... we should have buttons for connected cloud machines? and adding new stuff").
import { type CloudMachine, isCloudMachineRow, withCloudMachines } from "../cloudMachines";
import { environmentReady, knownMachines } from "../environments";
import { machineColor } from "../machineColor";
import { type MachineLink, peerLink } from "../machineLink";
import type { AcpmuxSnapshot } from "../model";

/// How long a reading stays current (AgentPaneNewTabWeather.maximumAge): older is drawn dimmed.
export const WEATHER_MAX_AGE_MS = 30 * 60 * 1000;

export type NewTabWeather = {
  place: string;
  temperature: number;
  high: number;
  low: number;
  /// The WMO weather code.
  code: number;
  unit: "celsius" | "fahrenheit";
  /// Milliseconds since 1970.
  readAt: number;
};

/// The handshake's `weather`, or undefined when it is missing or malformed.
export function parseWeather(value: unknown): NewTabWeather | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const v = value as Record<string, unknown>;
  const numbers = [v.temperature, v.high, v.low, v.code, v.readAt];
  if (!numbers.every((n) => typeof n === "number" && Number.isFinite(n))) return undefined;
  if (typeof v.place !== "string" || !v.place) return undefined;
  if (v.unit !== "celsius" && v.unit !== "fahrenheit") return undefined;
  return {
    place: v.place,
    temperature: v.temperature as number,
    high: v.high as number,
    low: v.low as number,
    code: v.code as number,
    unit: v.unit,
    readAt: v.readAt as number,
  };
}

/// true: the reading is older than its refresh (the app could not refresh it: offline).
export function weatherIsStale(weather: NewTabWeather, now: number): boolean {
  return now - weather.readAt >= WEATHER_MAX_AGE_MS;
}

/// A text-presentation glyph for a WMO code: clear, partly cloudy, cloudy, fog, rain, snow, thunder.
export function weatherGlyph(code: number): string {
  if (code === 0) return "☀︎";
  if (code <= 2) return "⛅︎";
  if (code === 3) return "☁︎";
  if (code === 45 || code === 48) return "≋";
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return "❄︎";
  if (code >= 95) return "⚡︎";
  if (code >= 51) return "☂︎";
  return "☁︎";
}

/// A temperature rounded to a whole degree, with its sign and the degree mark ("21°", "-3°").
export function degrees(value: number): string {
  const rounded = Math.round(value);
  return `${Object.is(rounded, -0) ? 0 : rounded}°`;
}

export type MachineKind = "local" | "ssh" | "cloud";
export type NewTabMachine = {
  id: string;
  label: string;
  kind: MachineKind;
  /** A chat can start on it now: this Mac, or a peer whose link finished its handshake. */
  online: boolean;
  /** Its link as the composer strip draws it (machineLink.tsx): none for this Mac, and none for an
   *  older chat's host that acpmux no longer lists (nothing is known of it). */
  link?: MachineLink;
  /** acpmux lists it as a peer: a press picks it (and reconnects it when it is down). */
  listed?: true;
  /** An account Cloud machine acpmux does not list (cloudMachines.ts): a press resumes or opens it. */
  cloudMachine?: CloudMachine;
  /** The machine's identity color (machineColor.ts), as the composer's computer chip draws it; none for this Mac. */
  color?: string;
};

/// The machines a chat can run on: this Mac first (always online), then acpmux's peers with their
/// live link (`peerStates`, followed from acpmux's pushes), then the hosts older chats ran on that
/// acpmux no longer lists (offline), then the account's Cloud machines acpmux does not list
/// (`cloudMachines`: a paused one, say), each with its stage. Each peer's kind is its transport
/// (`peerKinds`, environments.ts); a Cloud chat's host is Cloud, and gives way to the account's
/// machine of its name, which knows its stage.
export function newTabMachines(
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "peers" | "peerConnected" | "peerStates" | "peersUnlisted">,
  peerKinds: Record<string, "ssh" | "cloud">,
  localName: string,
  cloudMachines: readonly CloudMachine[] = [],
): NewTabMachine[] {
  const machines: NewTabMachine[] = [{ id: "local", label: localName, kind: "local", online: true }];
  const peers = snapshot.peers ?? [];
  const listed = new Set(peers);
  const known = knownMachines(
    peers,
    snapshot.sessions,
    peerKinds,
    [],
    snapshot.peerConnected ?? {},
    snapshot.peerStates ?? {},
    !snapshot.peersUnlisted,
  );
  for (const machine of withCloudMachines(known, cloudMachines, peers, "")) {
    const color = machineColor(machine.label);
    if (isCloudMachineRow(machine)) {
      const link = cloudStageLink(machine.cloudMachine.stage);
      machines.push({
        id: machine.id,
        label: machine.label,
        kind: "cloud",
        online: false,
        ...(link ? { link } : {}),
        cloudMachine: machine.cloudMachine,
        color,
      });
      continue;
    }
    if (!listed.has(machine.id)) {
      machines.push({ id: machine.id, label: machine.label, kind: machine.kind, online: false, color });
      continue;
    }
    const link = peerLink(machine);
    machines.push({
      id: machine.id,
      label: machine.label,
      kind: machine.kind,
      online: environmentReady(machine),
      listed: true,
      ...(link ? { link } : {}),
      color,
    });
  }
  return machines;
}

/// An account Cloud machine's stage as a link mark: grey while paused, the spinner while it starts,
/// red once it failed; a ready one acpmux has no link to yet draws none (a press opens it).
export function cloudStageLink(stage: string): MachineLink | undefined {
  if (stage === "paused") return "paused";
  if (["requesting", "creating", "booting", "connecting"].includes(stage)) return "connecting";
  if (stage === "failed") return "offline";
  return undefined;
}

/// What pressing a machine's button does: pick it for the next chat (a peer that is down is
/// reconnected as it is picked; the send waits for its link), resume or open an account Cloud
/// machine, or nothing for an older chat's host acpmux no longer lists.
export type MachinePress = "pick" | "reconnect" | "cloud" | "none";
export function machinePress(machine: NewTabMachine): MachinePress {
  if (machine.cloudMachine) return "cloud";
  if (machine.kind === "local") return "pick";
  if (!machine.listed) return "none";
  return machine.link === "offline" ? "reconnect" : "pick";
}
