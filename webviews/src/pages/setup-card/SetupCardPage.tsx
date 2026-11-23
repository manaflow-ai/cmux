// The Set Up cmux page's one view: the React card in its shipped look, sized to by the host.
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useSyncExternalStore } from "react";
import type { AccountFamily } from "../shared/signIn/accountSignIn";
import { agentFamily } from "../shared/signIn/ProviderReadiness";
import { useAccountSignIn, type AccountSignInTransport } from "../shared/signIn/useAccountSignIn";
import { useSignInAfterInstall } from "../shared/signIn/useSignInAfterInstall";
import { cardStrings } from "./strings";
import { SetupCard } from "./SetupCard";
import { SETUP_OPS } from "./ops";
import type { SetupAction, SetupState } from "./setupModel";
import type { SetupCardStore } from "./store";

/** The account a provider's sign-in runs on: the daemon's pick when it is one of the accounts, else a new one. */
function accountFor(state: SetupState | null, family: AccountFamily): string | null {
  const account = state?.signIn?.readiness?.providers?.find((provider) => provider.family === family)?.account;
  return account && (state?.signIn?.accounts ?? []).some((row) => row.id === account) ? account : null;
}

export function SetupCardPage({ store }: { store: SetupCardStore }) {
  const state = useSyncExternalStore(store.subscribe, store.getSnapshot, store.getSnapshot);
  const strings = cardStrings();
  const frame = useRef<HTMLDivElement>(null);
  // The in-place sign-in (the one onboarding and Settings run), when the host has it: an agent's Sign In
  // and the sign-in its Install asked for run here, the code and its link in the agents row.
  const transport = useMemo<AccountSignInTransport>(
    () => ({
      run: (params) => store.runAccountSignIn(params),
      // A host that answers a start without a sign-in: the agent's own Sign In (its terminal tab).
      fallback: (family) => store.send(SETUP_OPS.run, { action: { kind: "signInAgent", id: family } }),
    }),
    [store],
  );
  const signIn = useAccountSignIn(transport);
  const inPlace = state?.signIn != null;
  useSignInAfterInstall(inPlace ? state?.signIn?.after : null, (family) =>
    signIn.start(family, accountFor(store.getSnapshot(), family)),
  );
  const onAction = (action: SetupAction) => {
    const family = action.kind === "signInAgent" && inPlace ? agentFamily(action.id) : null;
    if (family) signIn.start(family, accountFor(state, family));
    else store.send(SETUP_OPS.run, { action });
  };
  // The host sizes its view to the card: measured after each render (a state change) and after each
  // layout change. A hidden page gets no ResizeObserver callbacks, so the render's own report is
  // what makes a card the host has not sized yet appear.
  const last = useRef(-1);
  const report = useCallback(() => {
    const node = frame.current;
    if (!node) return;
    const height = Math.ceil(node.getBoundingClientRect().height);
    if (height === last.current) return;
    last.current = height;
    store.send(SETUP_OPS.size, { height });
  }, [store]);
  useLayoutEffect(report);
  useEffect(() => {
    const node = frame.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(report);
    observer.observe(node);
    return () => observer.disconnect();
  }, [report]);
  useEffect(() => {
    const onFocus = () => store.send(SETUP_OPS.focused, {});
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [store]);
  return (
    <div ref={frame} className="setup-card-frame">
      {state && (
        <SetupCard
          strings={strings}
          state={state}
          look="rows"
          onAction={onAction}
          signIn={signIn.running ? { family: signIn.running.family, view: signIn.running.view, ...signIn.card } : null}
          onHide={() => store.send(SETUP_OPS.hide, {})}
        />
      )}
    </div>
  );
}
