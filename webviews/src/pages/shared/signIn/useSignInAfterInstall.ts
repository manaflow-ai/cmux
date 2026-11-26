// An Install that asked for its agent's in-place sign-in (first run, goal first-run-one-screen): the
// host names the agent (`after`) and the page starts its sign-in once, with no click of its own, the
// Install's click having asked for it. The Set Up card and onboarding's agents step both use it.
import { useEffect, useRef } from "react";
import type { AccountFamily } from "./accountSignIn";
import { agentFamily } from "./ProviderReadiness";

/** Starts `after`'s sign-in once each time the host names it; `start` gets its provider family. */
export function useSignInAfterInstall(after: string | null | undefined, start: (family: AccountFamily) => void): void {
  const started = useRef<string | null>(null);
  const begin = useRef(start);
  begin.current = start;
  useEffect(() => {
    if (!after) {
      started.current = null;
      return;
    }
    if (started.current === after) return;
    const family = agentFamily(after);
    if (!family) return;
    started.current = after;
    begin.current(family);
  }, [after]);
}
