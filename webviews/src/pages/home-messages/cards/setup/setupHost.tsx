// The Set Up cmux card on the Messages page (host: CmuxNextOnboarding SetupCardRoute, served on this
// page's `cmux.setup.*`). It was its own small page hosted in the native Home's transcript
// (HomeHostView+SetupCard.swift); the page now draws it itself, in a Chief chat, under the Needs you
// section. The host sends the rows' state as values (setupModel.ts `SetupState`) while the card shows
// (a first run, until Hide or every row done) and null once it ended; the card owns its words.
import { useEffect, useState, type ReactNode } from "react";
import type { PageClient } from "../../../shared/pageClient";
import type { Strings } from "../strings";
import { SetupCard } from "./SetupCard";
import type { SetupAction, SetupState } from "./setupModel";

export const SETUP_OPS = {
  /** `{}` → `SetupState`, or null while no card shows. */
  state: "cmux.setup.state",
  /** Stream: the whole `SetupState` after each change; null once the card ended. */
  changed: "cmux.setup.changed",
  /** `{action}`: a row's button (`SetupAction`), on the person's own click only. */
  run: "cmux.setup.run",
  /** `{}`: Hide; the card leaves for good, on the person's own click only. */
  hide: "cmux.setup.hide",
  /** `{}`: the page gained focus (back from a sign-in): the host checks the sign-ins again. */
  focused: "cmux.setup.focused",
} as const;

/** A host value as the card's state; anything else (null, another build's shape) is no card. */
export function parseSetupState(value: unknown): SetupState | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const state = value as Partial<SetupState>;
  if (!Array.isArray(state.agents) || !state.account || typeof state.account !== "object") return null;
  if (typeof state.cli !== "string") return null;
  return { ...(state as SetupState), classic: state.classic ?? null };
}

/**
 * The card while the host shows it, for the conversation the page shows when `active` (a Chief
 * chat; any other conversation gets none and reads nothing). Subscribes first, then reads: a change
 * that lands before the read's answer is newer. A row's button and Hide are one host call each; a
 * refusal (no click behind it) changes nothing. Focus back on the page reads the sign-ins again.
 */
export function useSetupCard(host: PageClient | null, active: boolean, strings: Strings): ReactNode | undefined {
  const [state, setState] = useState<SetupState | null>(null);
  useEffect(() => {
    setState(null);
    if (!host || !active) return;
    let ended = false;
    let changed = false;
    let stop: (() => void) | undefined;
    const send = (op: string, params: unknown) => void host.call(op, params).catch(() => undefined);
    void host
      .subscribe<unknown>(SETUP_OPS.changed, (event) => {
        changed = true;
        if (!ended) setState(parseSetupState(event));
      })
      .then(async (unsubscribe) => {
        if (ended) return unsubscribe();
        stop = unsubscribe;
        const first = await host.call<unknown>(SETUP_OPS.state, {});
        if (!ended && !changed) setState(parseSetupState(first));
      })
      .catch(() => undefined);
    const onFocus = () => send(SETUP_OPS.focused, {});
    window.addEventListener("focus", onFocus);
    return () => {
      ended = true;
      stop?.();
      window.removeEventListener("focus", onFocus);
    };
  }, [host, active]);
  if (!host || !active || !state) return undefined;
  const send = (op: string, params: unknown) => void host.call(op, params).catch(() => undefined);
  return (
    <SetupCard
      strings={strings}
      state={state}
      look="rows"
      onAction={(action: SetupAction) => send(SETUP_OPS.run, { action })}
      onHide={() => send(SETUP_OPS.hide, {})}
    />
  );
}
