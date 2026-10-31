import { useEffect, useRef, useState } from "react";
import type { ActionStates } from "./screenModel";

/// Asks the host which of a query's action candidates run now (`newTab.actionStates`); undefined for a
/// host that cannot tell (the page then shows no action row).
export type LoadActionStates = (ids: readonly string[]) => Promise<ActionStates | undefined>;

/// The host's states for the candidates `ids` of the query shown now, and whether they are in.
///
/// `ready` is false from the moment the candidates change until the host's answer for exactly those ids
/// arrives: the screen keeps drawing its previous rows meanwhile and draws the new query's rows once, with
/// their final availability, so no row is drawn and then greyed out or removed (lead 2026-10-31). A query
/// with no candidates is ready at once. A failed or missing answer counts as "none of them run".
export function useActionStates(ids: readonly string[], load: LoadActionStates | undefined) {
  const key = ids.join("\n");
  const [answer, setAnswer] = useState<{ key: string; states: ActionStates }>();
  useEffect(() => {
    if (!key) return;
    if (!load) {
      setAnswer({ key, states: {} });
      return;
    }
    let live = true;
    const settle = (states: ActionStates | undefined) => {
      if (live) setAnswer({ key, states: states ?? {} });
    };
    load(key.split("\n")).then(settle, () => settle(undefined));
    return () => {
      live = false;
    };
  }, [key, load]);
  if (!key) return { ready: true, states: {} as ActionStates };
  return answer?.key === key ? { ready: true, states: answer.states } : { ready: false, states: undefined };
}

/// The rows to draw: `rows` once `ready`, else the rows drawn last (the previous query's), so a query's
/// rows appear together with their final states.
export function useHeldRows<T>(rows: T, ready: boolean): T {
  const drawn = useRef(rows);
  if (ready) drawn.current = rows;
  return drawn.current;
}
