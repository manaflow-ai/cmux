// l10n-allow-file: gallery and test fixtures (sample machine names), not shipped UI.
// Load rows as acpmux sends them (`peers[].load`, placement.rs `load_row`), for the galleries of the
// composer's machine picker and Settings > Machines, which draw the same fixtures.
import type { MachineLoad } from "./machineLoad";

const GB = 1e9;

export const idleLoad: MachineLoad = {
  verdict: "room",
  words: "room for 5",
  room: 5,
  coresBusy: 1.4,
  cores: 16,
  ramFreeBytes: 24 * GB,
  live: 1,
  offlineMs: null,
};

export const busyLoad: MachineLoad = {
  verdict: "busy",
  words: "busy",
  room: 0,
  coresBusy: 12,
  cores: 12,
  ramFreeBytes: 2.4 * GB,
  live: 6,
  offlineMs: null,
};

export const offlineLoad: MachineLoad = {
  verdict: "offline",
  words: "offline 2 min",
  room: null,
  coresBusy: null,
  cores: null,
  ramFreeBytes: null,
  live: null,
  offlineMs: 125_000,
};

/** Three machines: one with room, one busy, one offline for two minutes. */
export const threeMachines: Record<string, MachineLoad> = {
  "gcp-3": idleLoad,
  "build-box": busyLoad,
  "old-laptop": offlineLoad,
};

/** `count` machines `fleet-01`…, cycling through room, busy and offline, for a long list. */
export function manyMachines(count: number): Record<string, MachineLoad> {
  const out: Record<string, MachineLoad> = {};
  for (let i = 0; i < count; i += 1) {
    const name = `fleet-${String(i + 1).padStart(2, "0")}`;
    const kind = i % 5;
    out[name] =
      kind === 3
        ? busyLoad
        : kind === 4
          ? { ...offlineLoad, offlineMs: (i + 1) * 3_600_000, words: `offline ${i + 1} h` }
          : { ...idleLoad, room: 1 + (i % 7), words: `room for ${1 + (i % 7)}`, live: i % 3 };
  }
  return out;
}
