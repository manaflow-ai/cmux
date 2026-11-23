import { useContext, useEffect, useState } from "react";
import type { FailureKind, FailureRoute } from "../failureCopy";
import { offersOwnRoute } from "../failureCopy";
import type { ChatAccount } from "../chatAccounts";
import { TurnActionsContext } from "./turnActions";

/// The CodeRouter docs: what it is, signing in and adding an account (`cr login`, `cr add`).
export const CODEROUTER_DOCS = "https://cmux.com/docs/coderouter";

export type CodeRouterChoice = { kind: "use"; account: ChatAccount } | { kind: "setup" };

/// What the failed turn offers of CodeRouter, once the chat's routes are read: undefined while
/// reading, when the kind does not call for it, or when there is nothing to offer. Moving the chat
/// needs `canResend` (the turn can be sent again): a move alone would leave the card as it was.
export function useCodeRouterChoice(
  kind: FailureKind,
  route: FailureRoute | undefined,
  canResend: boolean,
): CodeRouterChoice | undefined {
  const { ownRoute } = useContext(TurnActionsContext);
  const wanted = Boolean(ownRoute) && offersOwnRoute(kind, route);
  const [choice, setChoice] = useState<CodeRouterChoice | undefined>(undefined);
  useEffect(() => {
    if (!wanted || !ownRoute) {
      setChoice(undefined);
      return;
    }
    let live = true;
    ownRoute.find().then(
      (found) => {
        if (!live) return;
        if (found === "on") setChoice(undefined);
        else setChoice(found ? { kind: "use", account: found } : { kind: "setup" });
      },
      // Routes this pane cannot read: no action rather than one that fails.
      () => live && setChoice(undefined),
    );
    return () => {
      live = false;
    };
  }, [wanted, ownRoute]);
  return choice?.kind === "use" && !canResend ? undefined : choice;
}
