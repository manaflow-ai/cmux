// The trajectory view: how an agent's steps (its tool calls and thoughts) draw in the transcript,
// customizable (Leo, 2026-11-17 standup: "customize trajectory GUI (look into [a reference
// app])"). Four settings, each off by default, so a chat without them draws as it always has:
//
// - `agentPane.display.trajectory.layout`: `default`, or `rail` (each step's glyph hangs on one thin
//   line down the icon column, as a timeline; trajectory.css).
// - `agentPane.display.trajectory.density`: `default` (22px rows), `compact` (20px) or `relaxed`
//   (26px), as a tool call density setting. The row estimator (model.ts `toolRowHeight`) reads the same
//   pitch, so rows measured before paint match what draws.
// - `agentPane.display.trajectory.grouping`: `default` (runs of one kind under one line, "Ran 3
//   commands", and a run between asides folded), or `separate`: every step on its own row.
// - `agentPane.display.trajectory.hide`: the kinds of step left out (`thinking`, `reads`, `searches`,
//   `commands`, `edits`, `tools`). A failed step or one that waits for permission always shows: hiding
//   is for routine work, never for what needs the person. Messages to other agents, sub-sessions and
//   asides always show.
//
// The host sends the keys with the chat's other display keys (Swift AgentPaneDisplaySetting, rows in
// schemas/settings/source/agent-pane-display.json), so `cmux settings set`, Settings > Agent Chat and
// a customize draft all reach it, and resetting a key draws the default again. This module only keeps
// the resolved value; toolGroups.ts applies `hide` and `grouping` to the groups both ToolRows
// (TurnRows.tsx) and the estimator (model.ts) read, so they never disagree.
import { useSyncExternalStore } from "react";

export const TRAJECTORY_LAYOUT_KEY = "agentPane.display.trajectory.layout";
export const TRAJECTORY_DENSITY_KEY = "agentPane.display.trajectory.density";
export const TRAJECTORY_GROUPING_KEY = "agentPane.display.trajectory.grouping";
export const TRAJECTORY_HIDE_KEY = "agentPane.display.trajectory.hide";

export const TRAJECTORY_LAYOUTS = ["default", "rail"] as const;
export const TRAJECTORY_DENSITIES = ["default", "compact", "relaxed"] as const;
export const TRAJECTORY_GROUPINGS = ["default", "separate"] as const;
export const TRAJECTORY_STEPS = ["thinking", "reads", "searches", "commands", "edits", "tools"] as const;

export type TrajectoryLayout = (typeof TRAJECTORY_LAYOUTS)[number];
export type TrajectoryDensity = (typeof TRAJECTORY_DENSITIES)[number];
export type TrajectoryGrouping = (typeof TRAJECTORY_GROUPINGS)[number];
export type TrajectoryStep = (typeof TRAJECTORY_STEPS)[number];

export interface Trajectory {
  layout: TrajectoryLayout;
  density: TrajectoryDensity;
  grouping: TrajectoryGrouping;
  /// The kinds of step left out, in TRAJECTORY_STEPS order.
  hide: readonly TrajectoryStep[];
}

export const DEFAULT_TRAJECTORY: Trajectory = Object.freeze({
  layout: "default",
  density: "default",
  grouping: "default",
  hide: Object.freeze([]) as readonly TrajectoryStep[],
});

/// One step row's pitch per density other than the default, in px at scale 1
/// (`--cv-tool-row-height`, trajectory.css).
export const TRAJECTORY_ROW_HEIGHT: Record<Exclude<TrajectoryDensity, "default">, number> = {
  compact: 20,
  relaxed: 26,
};

const pick = <T extends string>(choices: readonly T[], value: unknown): T =>
  choices.includes(value as T) ? (value as T) : choices[0]!;

/// The trajectory the host's display map asks for; any value a row would refuse reads as its default.
export function resolveTrajectory(raw: unknown): Trajectory {
  const values = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as Record<string, unknown>;
  const hidden = values[TRAJECTORY_HIDE_KEY];
  const hide = Array.isArray(hidden) ? TRAJECTORY_STEPS.filter((step) => hidden.includes(step)) : [];
  const layout = pick(TRAJECTORY_LAYOUTS, values[TRAJECTORY_LAYOUT_KEY]);
  const density = pick(TRAJECTORY_DENSITIES, values[TRAJECTORY_DENSITY_KEY]);
  const grouping = pick(TRAJECTORY_GROUPINGS, values[TRAJECTORY_GROUPING_KEY]);
  if (layout === "default" && density === "default" && grouping === "default" && hide.length === 0)
    return DEFAULT_TRAJECTORY;
  return { layout, density, grouping, hide };
}

const same = (a: Trajectory, b: Trajectory) =>
  a.layout === b.layout && a.density === b.density && a.grouping === b.grouping && a.hide.join() === b.hide.join();

let current: Trajectory = DEFAULT_TRAJECTORY;
const listeners = new Set<() => void>();

/// The document attributes trajectory.css draws from; a default value sets none.
function applyAttributes(trajectory: Trajectory): void {
  const root = typeof document === "undefined" ? undefined : document.documentElement;
  if (!root) return;
  const set = (name: string, value: string, fallback: string) => {
    if (value === fallback) root.removeAttribute(name);
    else root.setAttribute(name, value);
  };
  set("data-trajectory-layout", trajectory.layout, "default");
  set("data-trajectory-density", trajectory.density, "default");
}

/// The host's display map (chatDisplay.ts `setChatDisplay`). Returns whether the trajectory changed,
/// so the chat measures its rows again (a new look) only then.
export function configureTrajectory(raw: unknown): boolean {
  const next = resolveTrajectory(raw);
  if (same(next, current)) return false;
  current = next;
  applyAttributes(next);
  for (const listener of listeners) listener();
  return true;
}

/// The trajectory now (toolGroups.ts and the estimator read it while they shape rows).
export const trajectory = (): Trajectory => current;

/// The step pitch the estimator places a one-line step at, before the chrome scale: `pitch` (the
/// transcript grid's line row) at the default density.
export const trajectoryRowHeight = (pitch: number): number =>
  current.density === "default" ? pitch : TRAJECTORY_ROW_HEIGHT[current.density];

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
const snapshot = () => current;

/// The trajectory as a hook: a component that shapes steps (ToolRows) shapes them again on a change.
export const useTrajectory = (): Trajectory => useSyncExternalStore(subscribe, snapshot, snapshot);
