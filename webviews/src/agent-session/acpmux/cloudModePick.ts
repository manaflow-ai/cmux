// The permission mode picked for a new chat whose first send starts it on a Cloud machine (the chat
// composer with Cloud picked). The chip shows it (`AcpmuxSnapshot.cloudStartMode`) and that send
// carries it to the machine (`CloudStart.mode`), which starts the chat in it when the machine is the
// person's own (cmux-tui agent_session_start.rs). Leo, 2026-11-10: "but shouldnt the user be allowed
// to just go through with stuff?". One page holds one pick; every Cloud send from it carries it.
import { useSyncExternalStore } from "react";

type Pick = { harness: string | undefined; mode: string };

let held: Pick | undefined;
const listeners = new Set<() => void>();

function emit() {
  for (const listener of listeners) listener();
}

/** Holds `mode` as the pick for the next Cloud start on `harness`. */
export function holdCloudModePick(harness: string | undefined, mode: string): void {
  held = { harness, mode };
  emit();
}

/** The held pick's mode for `harness`; none when nothing is held or it was picked on another harness. */
export function cloudModePickFor(pick: Pick | undefined, harness: string | undefined): string | undefined {
  return pick && pick.harness === harness ? pick.mode : undefined;
}

/** The Cloud send's `mode` for `harness`. The pick stays held: a send that is refused, held for a
 * check or a sign-in, or retried goes again in the same mode. A start that opens its chat closes
 * this page, and a pick on another harness or a move back to this Mac never applies it. */
export function cloudStartModePick(harness: string | undefined): { mode?: string } {
  const mode = cloudModePickFor(held, harness);
  return mode ? { mode } : {};
}

/** Tests only: drops the pick. */
export function clearCloudModePick(): void {
  held = undefined;
  emit();
}

export function useCloudModePick(): Pick | undefined {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => held,
  );
}
