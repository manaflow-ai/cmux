// A menu's rows as they settle while it is open. A menu opens with its final rows (the state its
// rows depend on is read before it shows: cloudMachines.ts keeps the Cloud account across page
// loads), so on open nothing moves. When the data truly changes while the menu is open (a machine
// connects, an account answer lands), a row that arrives grows in and fades in, and one that goes
// keeps its place, disabled, while it shrinks and fades out: height and opacity in one transition,
// never a pop (Leo, 2026-11-07: "if we do ever encounter those situations, we want to have, like,
// some sort of nice, comfortable transition"). A change of what the menu shows (another list, a
// search typed) is no data change: its rows replace the old ones at once, as filtering always did.
import { useEffect, useState } from "react";
import { isAgentMotionOff } from "../shared/motion";

/// How long a leaving row stays in the list: the menu row motion's length (`--agent-motion-move`,
/// cmux-motion standard), read from the page when it can be.
const LEAVE_FALLBACK_MS = 180;

/// `swap`: the row stays and only its words change (Cloud to Sign in for Cloud); they fade in.
export type RowMotion = "enter" | "leave" | "swap";

type Presence = {
  key: string;
  open: boolean;
  context: string;
  rows: string[];
  labels: ReadonlyMap<string, string>;
  entering: ReadonlySet<string>;
  leaving: ReadonlySet<string>;
  swapped: ReadonlySet<string>;
};

const SEPARATOR = "\u0001";

function reducedMotion(): boolean {
  if (isAgentMotionOff()) return true;
  // The app's motion gate (WebTheme `data-cmux-motion`): off or reduced moves no rows.
  const gate = typeof document === "undefined" ? undefined : document.documentElement.dataset.cmuxMotion;
  if (gate === "off" || gate === "reduced") return true;
  try {
    return globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
  } catch {
    return false;
  }
}

function leaveMs(): number {
  try {
    const value = getComputedStyle(document.documentElement).getPropertyValue("--agent-motion-move").trim();
    const number = Number.parseFloat(value);
    if (!Number.isFinite(number) || number < 0) return LEAVE_FALLBACK_MS;
    return value.endsWith("ms") ? number : value.endsWith("s") ? number * 1000 : number;
  } catch {
    return LEAVE_FALLBACK_MS;
  }
}

/// `next` with every row of `previous` it lost put back where it stood: after the nearest row that
/// preceded it and is still listed, else first.
export function mergeLeavingRows(previous: readonly string[], next: readonly string[]): string[] {
  const kept = new Set(next);
  const merged = [...next];
  previous.forEach((value, index) => {
    if (kept.has(value)) return;
    let at = 0;
    for (let before = index - 1; before >= 0; before -= 1) {
      const found = merged.indexOf(previous[before]!);
      if (found >= 0) {
        at = found + 1;
        break;
      }
    }
    merged.splice(at, 0, value);
  });
  return merged;
}

/// The rows to draw for `rows` while the menu is `open`, and each row's motion. `context` names
/// what the menu shows (its list and search): when it changes, rows replace at once. `label` is a
/// row's words, so a row whose words change in place fades them in.
export function useRowPresence(
  rows: readonly string[],
  open: boolean,
  context: string,
  label: (value: string) => string = () => "",
): { rows: readonly string[]; motion(value: string): RowMotion | undefined } {
  const labels = new Map(rows.map((value) => [value, label(value)]));
  const key = rows.map((value) => `${value}\u0002${labels.get(value)}`).join(SEPARATOR);
  const [state, setState] = useState<Presence>(() => ({
    key,
    open,
    context,
    rows: [...rows],
    labels,
    entering: new Set(),
    leaving: new Set(),
    swapped: new Set(),
  }));
  let current = state;
  if (state.key !== key || state.open !== open || state.context !== context) {
    // Closed, opening, or another list or search: the rows as they are, with no motion.
    const settled = !open || !state.open || state.context !== context || reducedMotion();
    if (settled) {
      current = {
        key,
        open,
        context,
        rows: [...rows],
        labels,
        entering: new Set(),
        leaving: new Set(),
        swapped: new Set(),
      };
    } else {
      const shown = new Set(state.rows);
      const now = new Set(rows);
      const entering = new Set([...state.entering].filter((value) => now.has(value)));
      for (const value of rows) if (!shown.has(value) || state.leaving.has(value)) entering.add(value);
      const leaving = new Set([...state.rows].filter((value) => !now.has(value)));
      const swapped = new Set([...state.swapped].filter((value) => now.has(value)));
      for (const value of rows)
        if (shown.has(value) && !state.leaving.has(value) && state.labels.get(value) !== labels.get(value))
          swapped.add(value);
      current = {
        key,
        open,
        context,
        rows: mergeLeavingRows(state.rows, rows),
        labels,
        entering,
        leaving,
        swapped,
      };
    }
    setState(current);
  }
  // A leaving row goes once its motion ends; an entering or swapped one is plain from then on.
  const moving = current.entering.size > 0 || current.leaving.size > 0 || current.swapped.size > 0;
  useEffect(() => {
    if (!moving) return;
    const timer = setTimeout(
      () =>
        setState((previous) =>
          previous.key === key
            ? {
                ...previous,
                rows: previous.rows.filter((value) => !previous.leaving.has(value)),
                entering: new Set(),
                leaving: new Set(),
                swapped: new Set(),
              }
            : previous,
        ),
      leaveMs(),
    );
    return () => clearTimeout(timer);
  }, [moving, key]);
  return {
    rows: current.rows,
    motion: (value) =>
      current.leaving.has(value)
        ? "leave"
        : current.entering.has(value)
          ? "enter"
          : current.swapped.has(value)
            ? "swap"
            : undefined,
  };
}
