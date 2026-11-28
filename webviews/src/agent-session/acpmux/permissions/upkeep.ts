// The grouped permissions' chat-wide work, apart from the panel that draws them (Panel.tsx): the
// app's Check and retry, Revoke and Refresh actions (page events `cmux-acpmux-permission*`), and the
// read that failed, asked again on its own (autoRetry.ts). The panel draws only while a group waits
// or a line has to show, so this runs in the pane for as long as the chat does: a Revoke after
// Always, with nothing left to draw, still revokes, and a read that keeps failing keeps its backoff
// and its quiet line instead of starting over each time a retry clears the error.
import { useEffect, useRef } from "react";
import { useAutoRetry } from "../autoRetry";
import type { PermissionClientState } from "./protocol";

type Actions = { onRetry(): void; onRevoke(): void; onRefresh(): void };

/// The chat's permission requests are being read: `ready` false, nothing in doubt, and a read
/// failed or runs. `failed` when the last read failed.
export function permissionReading(state: PermissionClientState | undefined) {
  const reading = !!state?.supported && !state.ready && !state.uncertain && (!!state.error || state.loading);
  return { reading, failed: reading && !!state?.error };
}

/// Runs the chat-wide work for `state` and says whether a failed read has lasted past the deadline
/// (the panel's one quiet line). `enabled` false runs nothing, for a panel whose pane runs it.
export function usePermissionUpkeep(
  state: PermissionClientState | undefined,
  actions: Actions,
  enabled = true,
): boolean {
  const stateRef = useRef(state);
  const actionsRef = useRef(actions);
  useEffect(() => {
    stateRef.current = state;
    actionsRef.current = actions;
  });
  useEffect(() => {
    if (!enabled) return;
    const usable = () => {
      const current = stateRef.current;
      return current?.supported && !current.busy && !current.loading ? current : undefined;
    };
    const handlers: [string, EventListener][] = [
      [
        "permissionRetry",
        () => {
          if (usable()?.uncertain) actionsRef.current.onRetry();
        },
      ],
      [
        "permissionRevoke",
        () => {
          const current = usable();
          if (current?.chatAllowance && current.ready !== false && !current.uncertain) actionsRef.current.onRevoke();
        },
      ],
      [
        "permissionRefresh",
        () => {
          if (usable()?.error) actionsRef.current.onRefresh();
        },
      ],
    ];
    for (const [name, handler] of handlers) window.addEventListener(`cmux-acpmux-${name}`, handler);
    return () => {
      for (const [name, handler] of handlers) window.removeEventListener(`cmux-acpmux-${name}`, handler);
    };
  }, [enabled]);
  const { reading, failed } = permissionReading(state);
  const { stillTrying } = useAutoRetry(
    enabled && failed ? state?.error : undefined,
    () => actionsRef.current.onRefresh(),
    { busy: !!state?.loading || !!state?.busy },
  );
  return enabled && reading && stillTrying;
}
