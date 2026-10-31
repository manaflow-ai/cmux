// The New Tab page's ambient widgets (`tabs.newTabWidgets.weather|machines`): a quiet row under the
// composer, so turning one on never moves the field. Weather is the app's last Open-Meteo reading
// (the handshake's `weather`, AgentPaneNewTabWeather.swift); Machines are the composer's computers
// (acpmux's peers and the hosts its chats ran on), each online while acpmux lists it as a peer.
import { knownMachines } from "../environments";
import { machineColor } from "../machineColor";
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
  online: boolean;
  /** The machine's identity color (machineColor.ts), as the composer's computer chip draws it; none for this Mac. */
  color?: string;
};

/// The machines a chat can run on: this Mac first (always online), then acpmux's peers (online),
/// then the hosts older chats ran on that acpmux no longer lists (offline). Each peer's kind is its
/// transport (`peerKinds`, environments.ts); a Cloud chat's host is Cloud.
export function newTabMachines(
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "peers">,
  peerKinds: Record<string, "ssh" | "cloud">,
  localName: string,
): NewTabMachine[] {
  const machines: NewTabMachine[] = [{ id: "local", label: localName, kind: "local", online: true }];
  const online = new Set(snapshot.peers ?? []);
  for (const machine of knownMachines(snapshot.peers ?? [], snapshot.sessions, peerKinds)) {
    machines.push({ ...machine, online: online.has(machine.id), color: machineColor(machine.label) });
  }
  return machines;
}
