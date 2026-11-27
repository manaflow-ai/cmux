// Fixtures for the AUTO computer gallery entries: one ComputerStatus per state the RFD draws.
import type { ComputerStatus } from "./computerStatus";

export const NOW = Date.UTC(2026, 10, 24, 14, 2, 30);
const base: ComputerStatus = {
  session_id: "fix-login-redirect",
  home: "cloud",
  phase: "running",
  shape: { vcpu: 2, memory_gib: 4 },
  size: { mode: "auto" },
  sleep: { mode: "auto" },
};

export const STATES = {
  local: { ...base, home: "this_mac", shape: undefined },
  cloudAwake: { ...base, why: { at_ms: NOW - 3_600_000, reason: "mac_memory_pressure" } },
  sleeping: { ...base, phase: "sleeping" },
  preparing: { ...base, home: "this_mac", shape: undefined, phase: "preparing", phase_since_ms: NOW - 3_200 },
  moving: {
    ...base,
    home: "this_mac",
    shape: undefined,
    phase: "moving",
    phase_since_ms: NOW - 6_400,
    move: { direction: "to_cloud", cancellable: true },
  },
  moveFailed: {
    ...base,
    home: "this_mac",
    shape: undefined,
    phase: "move_failed",
    move: { direction: "to_cloud", cancellable: false, failure: "network_dropped" },
  },
  pausedAtLimit: { ...base, phase: "paused_spend_cap", why: { at_ms: NOW - 60_000, reason: "spend_cap" } },
  sizePinned: {
    ...base,
    shape: { vcpu: 8, memory_gib: 16 },
    size: { mode: "pinned", vcpu: 8, memory_gib: 16 },
    sleep: { mode: "keep_awake", until_ms: NOW + 4 * 3_600_000 },
    why: { at_ms: NOW - 600_000, reason: "grew_for_memory", command: "cargo build" },
  },
  slotsFull: {
    ...base,
    home: "this_mac",
    shape: undefined,
    phase: "staying_local_slots_full",
    why: { at_ms: NOW - 120_000, reason: "slots_full" },
  },
  reconnecting: { ...base, phase: "reconnecting" },
} satisfies Record<string, ComputerStatus>;

export type StateName = keyof typeof STATES;
