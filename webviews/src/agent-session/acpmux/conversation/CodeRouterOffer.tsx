// cmux's own route on a failed turn (Lawrence 2026-10-23: "good opportunity for upsell here"): a
// key, sign-in or capacity failure offers CodeRouter beside Switch model (failureCopy.ts
// offersOwnRoute). The action always does something: with a CodeRouter route that serves the chat
// (the composer's Account menu lists the same ones), one click moves the chat onto it, the way that
// menu does, and sends the turn again; with none, it opens the CodeRouter docs to set one up. A chat
// on CodeRouter already, or one whose routes this pane cannot reach (Web, a peer, cmux Cloud), shows
// nothing.
import { useContext, useEffect, useState } from "react";
import { useT } from "../i18n";
import type { FailureKind, FailureRoute } from "../failureCopy";
import { offersOwnRoute } from "../failureCopy";
import type { ChatAccount } from "../chatAccounts";
import { TurnActionsContext } from "./turnActions";

/// The CodeRouter docs: what it is, signing in and adding an account (`cr login`, `cr add`).
export const CODEROUTER_DOCS = "https://cmux.com/docs/coderouter";

export type CodeRouterChoice = { kind: "use"; account: ChatAccount } | { kind: "setup" };

/// What the failed turn offers of CodeRouter, once the chat's routes are read: undefined while
/// reading, when the kind does not call for it, or when there is nothing to offer.
export function useCodeRouterChoice(kind: FailureKind, route: FailureRoute | undefined): CodeRouterChoice | undefined {
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
  return choice;
}

/// The action itself: a button (`className` sets its look) or, for the `link` arm, a link.
export function CodeRouterAction({
  choice,
  retry,
  className,
  link = false,
}: {
  choice: CodeRouterChoice;
  retry?: () => void;
  className: string;
  link?: boolean;
}) {
  const t = useT();
  const { ownRoute } = useContext(TurnActionsContext);
  const [state, setState] = useState<"idle" | "moving" | "failed">("idle");
  if (choice.kind === "setup")
    return (
      // A web link opens outside the pane (AgentPaneNavigation), as a reply's links do.
      <a className={className} href={CODEROUTER_DOCS} target="_blank" rel="noreferrer">
        {t("turn.failure.setUpCodeRouter")}
      </a>
    );
  const label =
    state === "moving"
      ? t("turn.failure.codeRouterMoving")
      : state === "failed"
        ? t("turn.failure.codeRouterFailed")
        : t("turn.failure.useCodeRouter");
  const move = () => {
    if (!ownRoute || state === "moving") return;
    setState("moving");
    // acpmux binds the route and restarts the agent on it before it answers (an idle chat), so the
    // turn sent again runs there.
    ownRoute.use(choice.account.id).then(
      () => {
        setState("idle");
        retry?.();
      },
      () => setState("failed"),
    );
  };
  return (
    <button
      type="button"
      className={`${className}${link ? " cv-turn-error__link" : ""}`}
      disabled={state === "moving"}
      onClick={move}
    >
      {label}
    </button>
  );
}
