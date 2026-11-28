// The setups shelf of Make cmux Yours (`experiments.setupShelf`, off by default; hq design
// dp-9eedbe44e5, "Ship six named setups for the first-run Make cmux Yours step"). The four setups are
// the files in examples/setups (cmux#54499): Calm, Dense, Chat-first and Terminal-first. Safe agents
// and Autopilot are not here: their keys are ones only the person may set, so a setup may not.
//
// The rule is the design's rebuttal, as #54499's tests pin it against the files:
//   - each setup owns only its axis's keys; a key it leaves out stays as the person has it;
//   - rivals on an axis (setups that share a key: Chat-first and Terminal-first) replace each other,
//     and setups on other axes stack;
//   - Try snapshots only the keys it writes, Revert puts that snapshot back, Keep drops it.
// Two more, so a click never undoes the person's own later pick: Revert puts back only the keys still
// as the setup left them, and a rival tried over a setup still on trial takes over its snapshot for
// the keys they share (Revert then gives back the person's value, not the replaced setup's) and puts
// back its other keys. Every click is one `cmux.onboarding.makeItYours.walk` op, one publish, so the
// window behind changes once (P11). Skip still puts back everything, the shelf's keys included.
import calm from "../../../../examples/setups/calm/cmux-setup.json";
import chatFirst from "../../../../examples/setups/chat-first/cmux-setup.json";
import dense from "../../../../examples/setups/dense/cmux-setup.json";
import terminalFirst from "../../../../examples/setups/terminal-first/cmux-setup.json";
import type { MakeItYoursState } from "./ops";
import type { WalkValue, WalkValues, WalkWrite } from "./walk";

export type SetupId = "calm" | "dense" | "chatFirst" | "terminalFirst";

export interface ShelfSetup {
  id: SetupId;
  /** The examples/setups folder it is read from. */
  folder: string;
  nameKey: string;
  lineKey: string;
  /** What it writes, by dotted path: its cmux-setup.json `settings`. */
  settings: WalkValues;
}

const setup = (id: SetupId, folder: string, file: { settings: Record<string, unknown> }): ShelfSetup => ({
  id,
  folder,
  nameKey: `onboarding.makeItYours.setup.${id}`,
  lineKey: `onboarding.makeItYours.setup.${id}.line`,
  settings: file.settings as WalkValues,
});

/** In the shelf's order: the quiet one, the dense one, then the two rivals on where the agent lives. */
export const SHELF_SETUPS: readonly ShelfSetup[] = [
  setup("calm", "calm", calm),
  setup("dense", "dense", dense),
  setup("chatFirst", "chat-first", chatFirst),
  setup("terminalFirst", "terminal-first", terminalFirst),
];

/** A setup on trial holds what its keys were before; a kept one holds nothing. */
export type ShelfEntry = { status: "trying"; snapshot: WalkValues } | { status: "kept" };
/** The page's shelf: setups absent from it are neither on trial nor kept. */
export type Shelf = Partial<Record<SetupId, ShelfEntry>>;

const byId = (id: SetupId): ShelfSetup => {
  const found = SHELF_SETUPS.find((s) => s.id === id);
  if (!found) throw new Error(`no setup ${id}`);
  return found;
};

const value = (values: WalkValues, path: string): WalkValue => values[path] ?? null;

/** The settings the shelf reads now: the host's `walk` values (the shelf's paths come with it while
 * the experiment is on) and the step's density, which the host sends as its own field. */
export function shelfValues(choices: MakeItYoursState): WalkValues {
  return { ...(choices.walk ?? {}), "appearance.density": choices.density };
}

/** Two setups are rivals when they write a key in common. */
export function rivals(a: ShelfSetup, b: ShelfSetup): boolean {
  return a.id !== b.id && Object.keys(a.settings).some((path) => path in b.settings);
}

const writesOf = (targets: WalkValues, current: WalkValues): WalkWrite[] =>
  Object.entries(targets)
    .filter(([path, target]) => value(current, path) !== (target ?? null))
    .map(([path, target]) => ({ path, value: target ?? null }));

/** Try `id`: its keys written in one op, a rival replaced, the keys' values before kept for Revert. */
export function trySetup(shelf: Shelf, id: SetupId, current: WalkValues): { shelf: Shelf; writes: WalkWrite[] } {
  const chosen = byId(id);
  const next: Shelf = { ...shelf };
  const targets: WalkValues = {};
  const snapshot: WalkValues = {};
  for (const other of SHELF_SETUPS) {
    const entry = shelf[other.id];
    if (!entry || !rivals(chosen, other)) continue;
    delete next[other.id];
    // A kept rival's values are the person's now: the chosen setup snapshots them as they stand.
    if (entry.status !== "trying") continue;
    for (const [path, was] of Object.entries(entry.snapshot)) {
      if (path in chosen.settings) snapshot[path] = was;
      else if (value(current, path) === value(other.settings, path)) targets[path] = was;
    }
  }
  for (const [path, target] of Object.entries(chosen.settings)) {
    if (!(path in snapshot)) snapshot[path] = value(current, path);
    targets[path] = target;
  }
  next[id] = { status: "trying", snapshot };
  return { shelf: next, writes: writesOf(targets, current) };
}

/** Keep `id`: its snapshot is dropped, so nothing on the shelf puts its keys back. */
export function keepSetup(shelf: Shelf, id: SetupId): Shelf {
  return shelf[id]?.status === "trying" ? { ...shelf, [id]: { status: "kept" } } : shelf;
}

/** Revert `id`: its snapshot back, for the keys still as the setup left them, in one op. */
export function revertSetup(shelf: Shelf, id: SetupId, current: WalkValues): { shelf: Shelf; writes: WalkWrite[] } {
  const entry = shelf[id];
  if (entry?.status !== "trying") return { shelf, writes: [] };
  const chosen = byId(id);
  const targets: WalkValues = {};
  for (const [path, was] of Object.entries(entry.snapshot)) {
    if (value(current, path) === value(chosen.settings, path)) targets[path] = was;
  }
  const next: Shelf = { ...shelf };
  delete next[id];
  return { shelf: next, writes: writesOf(targets, current) };
}
