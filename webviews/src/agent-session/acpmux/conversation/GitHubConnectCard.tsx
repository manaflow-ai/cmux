// The turn's Connect GitHub card (githubConnect.ts): one line saying GitHub isn't connected for this
// chat, one filled Connect GitHub button. The tap runs the app's `accounts.githubConnect` with the
// failed call's repository and this chat's link; GitHub's page (or nothing, when an installation
// already covers the repository) does the rest and returns to this chat, and the card sends the
// chat's Continue once the person is back, so the session goes on by itself. Its look is the
// turn's failure card's (TurnRows.tsx TurnFailure), the notice the reader already knows.
import { useContext, useEffect, useState } from "react";
import { useT, type StringKey } from "../i18n";
import { actionRefusal } from "../actionRefusal";
import { experimentArm } from "../../../experiments/experiment";
import { turnErrorCard } from "./turnErrorCard.experiment";
import { settingsAskCard } from "./settingsAskCard.experiment";
import { GitHubMark } from "./icons";
import { useTranscriptReadOnly } from "./readOnly";
import { TurnActionsContext } from "./turnActions";
import {
  afterVisibility,
  cardPhase,
  setCardPhase,
  type GitHubConnectNeed,
  type GitHubConnectOffer,
  type GitHubConnectPhase,
} from "./githubConnect";

const CAUSE: Record<GitHubConnectNeed["reason"], StringKey> = {
  "not-connected": "githubConnect.notConnected",
  "needs-reauth": "githubConnect.needsReauth",
  "not-covered": "githubConnect.notCovered",
  asked: "githubConnect.asked",
};

/// The card as drawn for one phase. `offer` absent: a pane that cannot run the app's actions (View
/// Only, a read-only pane) shows the line alone.
export function GitHubConnectCardView({
  need,
  phase,
  offer,
  onConnect,
  onContinue,
}: {
  need: GitHubConnectNeed;
  phase: GitHubConnectPhase;
  offer: boolean;
  onConnect?: () => void;
  onContinue?: () => void;
}) {
  const t = useT();
  // An agent's own ask (`settings_ask`) draws as the settings-ask-card experiment says; a failed
  // call's card keeps the turn error card's look.
  const asked = need.reason === "asked";
  const askArm = asked ? experimentArm(settingsAskCard) : undefined;
  const arm = askArm === "needs" ? "card" : (askArm ?? experimentArm(turnErrorCard));
  const repo = need.repo;
  const cause = asked
    ? (need.why ??
      (repo
        ? t("githubConnect.askedOrg", { org: repo })
        : need.org
          ? t("githubConnect.askedOrg", { org: need.org })
          : t("githubConnect.asked")))
    : need.reason === "not-covered" && repo
      ? t("githubConnect.notCoveredRepo", { repo })
      : repo && need.reason === "not-connected"
        ? t("githubConnect.notConnectedRepo", { repo })
        : t(CAUSE[need.reason]);
  const line =
    phase.kind === "waiting"
      ? t("githubConnect.finishOnGitHub")
      : phase.kind === "continuing"
        ? t("githubConnect.continuing")
        : phase.kind === "refused"
          ? (phase.reason ?? t("githubConnect.notRun"))
          : cause;
  if (askArm === "needs")
    return (
      <section
        className="cv-settings-ask cv-github-connect"
        data-github-connect={phase.kind}
        data-settings-ask="needs"
        role={phase.kind === "refused" ? "alert" : undefined}
        aria-live={phase.kind === "refused" ? undefined : "polite"}
        aria-label={t("githubConnect.needsYou")}
      >
        <div className="cv-settings-ask__header">{t("githubConnect.needsYou")}</div>
        <div className="cv-settings-ask__row">
          <GitHubMark size={16} className="cv-settings-ask__icon" />
          <span className="cv-settings-ask__line text-fg">{line}</span>
          {offer && phase.kind !== "continuing" && (
            <ConnectButton phase={phase} onConnect={onConnect} onContinue={onContinue} />
          )}
        </div>
      </section>
    );
  return (
    <div
      className={`cv-turn-note cv-turn-error cv-turn-error--${arm}${arm === "card" ? " ui-glass" : ""} cv-github-connect`}
      data-github-connect={phase.kind}
      data-settings-ask={askArm}
      role={phase.kind === "refused" ? "alert" : undefined}
      aria-live={phase.kind === "refused" ? undefined : "polite"}
    >
      <span className="cv-turn-error__cause">
        {arm !== "note" && <GitHubMark size={arm === "card" ? 16 : 14} className="cv-turn-error__icon" />}
        <span className="text-fg">{line}</span>
      </span>
      {offer && phase.kind !== "continuing" && (
        <span className="cv-turn-error__actions">
          <ConnectButton phase={phase} onConnect={onConnect} onContinue={onContinue} />
        </span>
      )}
    </div>
  );
}

/// The card's one button: Connect GitHub (Try again after a refusal), or Continue while GitHub's
/// page is open.
function ConnectButton({
  phase,
  onConnect,
  onContinue,
}: {
  phase: GitHubConnectPhase;
  onConnect?: () => void;
  onContinue?: () => void;
}) {
  const t = useT();
  return phase.kind === "waiting" ? (
    // GitHub's page is open: the chat goes on when the person is back. Continue is the same
    // step by hand, for a return the page did not see.
    <button type="button" className="cv-turn-auth-action" onClick={onContinue}>
      {t("turn.continue")}
    </button>
  ) : (
    <button
      type="button"
      className="cv-turn-auth-action cv-turn-error__primary"
      disabled={phase.kind === "opening"}
      onClick={onConnect}
    >
      {phase.kind === "refused" ? t("githubConnect.tryAgain") : t("githubConnect.connect")}
    </button>
  );
}

/// Sets a card's phase in the store (it outlives a redraw) and in the component.
function storePhase(phaseKey: string, setPhase: (next: GitHubConnectPhase) => void, next: GitHubConnectPhase) {
  setCardPhase(phaseKey, next);
  setPhase(next);
}

/// Sends Continue once: a card already continuing does nothing.
function continueOnce(
  phaseKey: string,
  setPhase: (next: GitHubConnectPhase) => void,
  offer: GitHubConnectOffer | undefined,
) {
  if (!offer || cardPhase(phaseKey).kind === "continuing") return;
  storePhase(phaseKey, setPhase, { kind: "continuing" });
  void offer.continue();
}

/// The card under a turn whose GitHub call asked for a connect (TurnFooter). `phaseKey` names the
/// chat and turn, so the card keeps its phase when the transcript draws it again.
export function GitHubConnectCard({ need, phaseKey }: { need: GitHubConnectNeed; phaseKey: string }) {
  const { githubConnect } = useContext(TurnActionsContext);
  const readOnly = useTranscriptReadOnly();
  const offer: GitHubConnectOffer | undefined = readOnly ? undefined : githubConnect;
  const [phase, setPhase] = useState<GitHubConnectPhase>(() => cardPhase(phaseKey));
  const set = (next: GitHubConnectPhase) => storePhase(phaseKey, setPhase, next);
  useEffect(() => setPhase(cardPhase(phaseKey)), [phaseKey]);
  const goOn = () => continueOnce(phaseKey, setPhase, offer);
  // While GitHub's page is open: leaving the page (the browser in front, the app in the background)
  // marks the card, and coming back after that sends Continue once. An event, never a timer.
  const waiting = phase.kind === "waiting";
  useEffect(() => {
    if (!waiting || !offer) return;
    const seen = (visible: boolean) => {
      const next = afterVisibility(cardPhase(phaseKey), visible);
      if (next === "continue") return continueOnce(phaseKey, setPhase, offer);
      if (next !== cardPhase(phaseKey)) storePhase(phaseKey, setPhase, next);
    };
    const onVisibility = () => seen(document.visibilityState !== "hidden");
    // Focus moving into a frame of this page is not leaving it.
    const onBlur = () => !document.hasFocus() && seen(false);
    const onFocus = () => seen(true);
    document.addEventListener("visibilitychange", onVisibility);
    window.addEventListener("blur", onBlur);
    window.addEventListener("focus", onFocus);
    return () => {
      document.removeEventListener("visibilitychange", onVisibility);
      window.removeEventListener("blur", onBlur);
      window.removeEventListener("focus", onFocus);
    };
  }, [waiting, offer, phaseKey]);
  const connect = () => {
    if (!offer) return;
    set({ kind: "opening" });
    offer.connect(need.repo, need.org).then(
      () => cardPhase(phaseKey).kind === "opening" && set({ kind: "waiting", left: false }),
      (error: unknown) => set({ kind: "refused", reason: actionRefusal(error) }),
    );
  };
  return (
    <GitHubConnectCardView
      need={need}
      phase={phase}
      offer={offer !== undefined}
      onConnect={connect}
      onContinue={goOn}
    />
  );
}
