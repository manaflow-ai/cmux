import { useEffect, useRef } from "react";
import { translate as t, type StringKey } from "./i18n";
import { type Environment, type EnvironmentSection } from "./environments";
import { type CloudMachine, isCloudMachineRow } from "./cloudMachines";

/// The sections (environments.ts `environmentSections`): This Mac, My machines, Cloud and VMs.
export const SECTION_LABELS: Record<EnvironmentSection, StringKey> = {
  local: "composer.thisMac",
  mine: "composer.envMine",
  fleet: "composer.envFleet",
};
/// A machine a chat cannot start on yet, in words: its link state as acpmux says it.
const STATE_LABELS: Record<string, StringKey> = {
  connecting: "rail.connectorPending",
  degraded: "rail.connectorPending",
  reconnecting: "header.reconnecting",
  // A Cloud machine the account says sleeps (cloudMachines.ts withCloudSleep): a calm state, never
  // a link to fix.
  paused: "composer.envPaused",
  resuming: "composer.envResuming",
};
export function environmentStateLabel(environment: Environment): string {
  if (isCloudMachineRow(environment)) return cloudMachineLabel(environment.cloudMachine);
  return t(STATE_LABELS[environment.state ?? ""] ?? "composer.envNotConnected");
}
/// An account Cloud machine acpmux does not list (cloudMachines.ts): its stage, and what a pick does.
const CLOUD_STAGE_LABELS: Record<string, StringKey> = {
  ready: "composer.envOpenMachine",
  paused: "composer.envPausedResume",
  requesting: "composer.envStarting",
  resuming: "composer.envResuming",
  creating: "composer.envStarting",
  booting: "composer.envStarting",
  connecting: "composer.envStarting",
  // A machine that failed to start says so, never "Not connected", which reads as a link to fix.
  failed: "switch.failedShort",
};
function cloudMachineLabel(machine: CloudMachine): string {
  return t(CLOUD_STAGE_LABELS[machine.stage] ?? "composer.envNotConnected");
}

/// The machines (and saved environments) a list holds before it gets a search field.
export const ENVIRONMENT_SEARCH_MIN = 8;

/// How often an open machine list reads the machines again: acpmux sends no peer events, so a
/// machine that connects or drops while the list is open shows within this long.
export const MACHINES_REFRESH_MS = 5_000;

/// While a machine list is open, `refresh` runs as it opens and then every MACHINES_REFRESH_MS;
/// the timer stops when the list closes or the picker unmounts.
export function useMachineRefresh(open: boolean, refresh: (() => void) | undefined): void {
  const latest = useRef(refresh);
  latest.current = refresh;
  useEffect(() => {
    if (!open) return;
    latest.current?.();
    const timer = setInterval(() => latest.current?.(), MACHINES_REFRESH_MS);
    return () => clearInterval(timer);
  }, [open]);
}

/// How a machine list shows the machines acpmux cannot reach (environments.ts
/// environmentUnavailable). `collapsed` ships: an "Unavailable (N)" row after the reachable
/// machines, above Add Machine…, that opens them in place. `after-add` puts that row below Add
/// Machine…; `hidden` drops them from the list (a search still finds them); `inline` lists them greyed
/// in place, as before (gallery only).
export type UnavailableGroup = "collapsed" | "after-add" | "hidden" | "inline";

/// A machine list's rows with its unavailable machines moved to their group. `rows` is the list as
/// it reads with every machine in place; `actions` the setup rows that end it (Add Machine…);
/// `kept` a row that stays in place however it is (the current pick, never hidden). A typed search
/// lists every match in place, so a machine is always found by name.
export function groupUnavailableRows({
  rows,
  actions,
  unavailable,
  kept,
  searching,
  group,
  toggle,
  expanded,
}: {
  rows: readonly string[];
  actions: readonly string[];
  unavailable: (value: string) => boolean;
  kept?: string;
  searching: boolean;
  group: UnavailableGroup;
  toggle: string;
  expanded: boolean;
}): { rows: string[]; count: number } {
  const down = rows.filter((value) => value !== kept && unavailable(value));
  if (searching || group === "inline" || down.length === 0) return { rows: [...rows, ...actions], count: 0 };
  const gone = new Set(down);
  const up = rows.filter((value) => !gone.has(value));
  const tail = [toggle, ...(expanded ? down : [])];
  if (group === "hidden") return { rows: [...up, ...actions], count: down.length };
  if (group === "after-add") return { rows: [...up, ...actions, ...tail], count: down.length };
  return { rows: [...up, ...tail, ...actions], count: down.length };
}
