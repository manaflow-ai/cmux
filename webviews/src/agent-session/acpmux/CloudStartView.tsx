import { useEffect, useState } from "react";
import { experimentArm } from "../../experiments/experiment";
import { usePageNow } from "../../ui/pageClock";
import { cloudStartLook } from "./cloudStart.experiment";
import { CloudStartAsk } from "./CloudStartAsk";
import {
  CLOUD_START_STALL_MS,
  CLOUD_START_STEPS,
  type CloudStartAsk as Ask,
  type CloudStartProgress,
} from "./cloudStartProgress";
import { AlertCircle, Check, ChevronDown, ChevronRight, Folder, Spinner } from "./conversation/icons";

import { Thinking } from "./conversation/Thinking";
import { usePaneLanguage, useT, type Translate } from "./i18n";
import { cloudPlanRecoveryLabels } from "./cloudPlanRecoveryLabels";
import type { CloudPlanTeam, CloudPlanTeamRefusal } from "./cloudPlanTeams";
import "./cloudStart.css";
import { type ChecklistStep, startupChecklist } from "./cloudStartViewModel";
function mark(step: ChecklistStep, t: Translate) {
  if (step.status === "done")
    return (
      <>
        <Check size={16} />
        <span className="visually-hidden">{t("cloudStartup.state.done")}</span>
      </>
    );
  if (step.status === "running")
    return (
      <>
        <Spinner size={16} loading />
        <span className="visually-hidden">{t("cloudStartup.state.running")}</span>
      </>
    );
  if (step.status === "error")
    return (
      <>
        <AlertCircle size={16} />
        <span className="visually-hidden">{t("cloudStartup.state.error")}</span>
      </>
    );
  if (step.status === "skipped")
    return (
      <>
        <span className="acpmux-cloud-start__skip-mark" aria-hidden />
        <span className="visually-hidden">{t("cloudStartup.state.skipped")}</span>
      </>
    );
  return (
    <>
      <span className="acpmux-cloud-start__pending-mark" aria-hidden />
      <span className="visually-hidden">{t("cloudStartup.state.pending")}</span>
    </>
  );
}

type Fact = { id: string; label: string; value: string };
function facts(start: CloudStartProgress, t: Translate): Fact[] {
  const list: Fact[] = [];
  if (start.folder) list.push({ id: "folder", label: t("composer.folder"), value: start.folder });
  if (start.machine)
    list.push({
      id: "machine",
      label: t("sandbox.vm"),
      value: start.size ? `${start.machine} · ${start.size}` : start.machine,
    });
  if (start.secrets !== undefined)
    list.push({ id: "secrets", label: t("cloudStart.secrets"), value: String(start.secrets) });
  if (start.network)
    list.push({
      id: "network",
      label: t("cloudStart.network"),
      value: t(start.network === "full" ? "cloudStart.networkFull" : "cloudStart.networkLimited"),
    });
  return list;
}

/// The start's question (CloudStartAsk) in a row that opens from no height to its own and closes back,
/// moving what is under it with it (no pop-in, no jump). The last question stays drawn, inert, while
/// the row closes; a newer one replaces it. Nothing is drawn before the first question.
function AskRow({ ask, onAnswer }: { ask?: Ask; onAnswer?: (id: string, button: string) => Promise<boolean> | void }) {
  const [last, setLast] = useState(ask);
  if (ask && ask !== last) setLast(ask);
  if (!last) return null;
  const open = ask !== undefined;
  return (
    <div
      className="acpmux-cloud-ask-row"
      data-open={open ? "true" : "false"}
      aria-hidden={open ? undefined : true}
      inert={!open}
    >
      <div className="acpmux-cloud-ask-row__clip">
        <CloudStartAsk key={last.id} ask={last} {...(open && onAnswer ? { onAnswer } : {})} />
      </div>
    </div>
  );
}

/// How the plan refusal in a team reads (gallery `agent-pane.cloud-plan-team` compares them):
/// `notice` (shipped) says it under the message with no startup card, since nothing started;
/// `card` keeps the failed startup card above the same words; `banner` puts the words and the
/// buttons on one line.
export type CloudPlanTeamLook = "notice" | "card" | "banner";

/// "This team has no Cloud plan": a final state, no retry and no wait. It names the team the send
/// was in (the one picked in the team menu, which is easy to miss) and offers the person's own team,
/// which switches and sends again, then the plans; Run on This Mac and Not now stay as before.
function PlanTeamRefusal({
  refusal,
  look,
  onSwitchTeam,
  onUpgrade,
  onRunHere,
  onDismiss,
  runHereLabel,
}: {
  refusal: CloudPlanTeamRefusal;
  look: CloudPlanTeamLook;
  onSwitchTeam?: (team: CloudPlanTeam) => void;
  onUpgrade?: () => void;
  onRunHere?: () => void;
  onDismiss?: () => void;
  runHereLabel: string;
}) {
  const t = useT();
  const switchTo = refusal.switchTo;
  const actions = (
    <span className="acpmux-cloud-ask__actions acpmux-cloud-plan-team__actions">
      {switchTo && onSwitchTeam && (
        <button
          type="button"
          className="acpmux-cloud-ask__button"
          data-role="default"
          data-action="switch-team"
          onClick={() => onSwitchTeam(switchTo)}
        >
          {t("cloudStart.planTeam.switch", { team: switchTo.name })}
        </button>
      )}
      {onUpgrade && (
        <button
          type="button"
          className="acpmux-cloud-ask__button"
          data-role={switchTo && onSwitchTeam ? undefined : "default"}
          data-action="see-plans"
          onClick={() => onUpgrade()}
        >
          {t("cloudStart.planTeam.seePlans")}
        </button>
      )}
      {onRunHere && (
        <button type="button" className="acpmux-cloud-ask__button" data-action="run-here" onClick={() => onRunHere()}>
          {runHereLabel}
        </button>
      )}
      {onDismiss && (
        <button type="button" className="acpmux-cloud-ask__button" data-action="dismiss" onClick={() => onDismiss()}>
          {t("harness.notNow")}
        </button>
      )}
    </span>
  );
  const title = <strong className="acpmux-cloud-plan-team__title">{t("cloudStart.planTeam.title")}</strong>;
  const team = (
    <span className="acpmux-cloud-plan-team__team">{t("cloudStart.planTeam.selected", { team: refusal.team })}</span>
  );
  return (
    <div className="acpmux-cloud-plan-team" data-look={look} role="alert">
      {look === "banner" ? (
        <>
          <div className="acpmux-cloud-plan-team__head">
            <AlertCircle size={14} />
            {title}
            {actions}
          </div>
          {team}
        </>
      ) : (
        <>
          <div className="acpmux-cloud-plan-team__head">
            <AlertCircle size={14} />
            {title}
          </div>
          {team}
          {actions}
        </>
      )}
    </div>
  );
}

/** Start refusals that name what to do in their own card, with no failed step for the checklist to show. */
const POLICY_REFUSALS: ReadonlySet<string> = new Set(["cloud_plan_required", "cloud_spend_cap", "cloud_member_budget"]);

export function CloudStartView({
  start,
  bubble = true,
  showSteps = false,
  onOpenEnvironment,
  onAnswer,
  onRetry,
  onSignIn,
  onUpgrade,
  onRunHere,
  onDismiss,
  onSwitchTeam,
  planTeamLook = "notice",
}: {
  start: CloudStartProgress;
  bubble?: boolean;
  /// The startup steps while the start is on its way (galleries and tests); off, the start reads as a
  /// local first turn and only a failure shows them.
  showSteps?: boolean;
  onOpenEnvironment?: (options: { environmentId?: string; repository?: string; section: "script" }) => void;
  /// The person's click on the start's question: its id and the button's (`cloud.answerStart`).
  onAnswer?: (id: string, button: string) => Promise<boolean> | void;
  /// Sends the same prompt again, a retry of this start (its key is kept): offered on a retryable failure.
  onRetry?: () => void;
  onSignIn?: () => void | Promise<unknown>;
  /// A plan refusal's recovery (`cloud_plan_required`): the app's paid-plan path, the same prompt
  /// on this Mac, or leave the card (the draft stays in the composer).
  onUpgrade?: () => void;
  onRunHere?: () => void;
  onDismiss?: () => void;
  /// A plan refusal in a team: switch to the person's own team (the team picker's switch) and send again.
  onSwitchTeam?: (team: CloudPlanTeam) => void;
  /// The plan-in-a-team look (galleries compare them); the pane draws `notice`.
  planTeamLook?: CloudPlanTeamLook;
}) {
  const t = useT();
  const arm = experimentArm(cloudStartLook);
  const failed = start.state === "failed";
  /// No word from the host for minutes (cloudStartProgress.ts `stalled`): the card opens on where it
  /// stopped and says the composer is open again.
  const stalled = !failed && start.stalled === true;
  // The chat shell is useful before the machine is ready, so keep the expensive startup
  // checklist out of the way until someone asks for it. A failure is the one time we open it
  // automatically: the failed row and its log tail explain what needs attention.
  // A refusal by policy (the plan, the team's spending cap, the member's budget) has no failed step to explain, so the
  // checklist stays shut and the card's actions stay in view in a short pane (#40036 review F1). A stalled start opens
  // it, to name the step it stopped at.
  const autoOpen = (failed && !POLICY_REFUSALS.has(start.code ?? "")) || stalled;
  const [expanded, setExpanded] = useState(autoOpen);
  const signInRequired = failed && start.code === "not_signed_in" && onSignIn;
  const [signingIn, setSigningIn] = useState(false);
  const now = usePageNow(!start.initialized && start.state !== "failed");
  useEffect(() => {
    if (autoOpen) setExpanded(true);
    else if (start.initialized) setExpanded(false);
  }, [autoOpen, start.initialized]);
  const language = usePaneLanguage();
  const planLabels = cloudPlanRecoveryLabels(language);
  const rows = startupChecklist(start, t, now, language);
  const known = facts(start, t);
  const openEnvironment = () => {
    const options = {
      ...(start.environmentId ? { environmentId: start.environmentId } : {}),
      ...(start.repository ? { repository: start.repository } : {}),
      section: "script" as const,
    };
    if (onOpenEnvironment) onOpenEnvironment(options);
    else window.dispatchEvent(new CustomEvent("cmux:open-cloud-environment", { detail: options }));
  };
  const signIn = () => {
    if (!onSignIn || signingIn) return;
    setSigningIn(true);
    void Promise.resolve(onSignIn()).finally(() => setSigningIn(false));
  };
  // A start that is on its way reads as a local chat's first turn: the message, then the normal
  // Thinking line, with no Cloud machine, clone or setup rows (Leo, 2026-11-04: "You actually see
  // nothing. Like the ideal is, of course, you literally have parity with local, and you don't even
  // realize that you entered the cloud"). Only a failure shows the steps, with what to do.
  // A start that waits on the person's browser sign-in says that instead: nothing runs until they finish.
  const waitingForSignIn = !failed && start.signingIn === true;
  const signInStatus = (
    <output className="acpmux-cloud-start__status" data-signing-in="true" aria-busy="true">
      <Spinner size={14} loading />
      <span>{t("cloudStart.waitingForSignIn")}</span>
    </output>
  );
  const planTeam = failed && start.code === "cloud_plan_required" ? start.planTeam : undefined;
  const planTeamRefusal = planTeam && (
    <PlanTeamRefusal
      refusal={planTeam}
      look={planTeamLook}
      runHereLabel={planLabels.runHere}
      {...(onSwitchTeam ? { onSwitchTeam } : {})}
      {...(onUpgrade ? { onUpgrade } : {})}
      {...(onRunHere ? { onRunHere } : {})}
      {...(onDismiss ? { onDismiss } : {})}
    />
  );
  // Nothing started (the plan is checked before any machine), so the notice has no startup card.
  if (planTeamRefusal && planTeamLook !== "card") {
    return (
      <section className="acpmux-cloud-start" data-state="failed" data-plan-team="true">
        {bubble && (
          <div className="cv-user">
            <div className="ui-glass cv-user__bubble selectable">{start.task}</div>
          </div>
        )}
        {planTeamRefusal}
      </section>
    );
  }
  if (!failed && !stalled && !showSteps) {
    return (
      <section
        className="acpmux-cloud-start"
        data-state={start.state}
        data-quiet="true"
        data-signing-in={waitingForSignIn ? "true" : undefined}
      >
        {bubble && (
          <div className="cv-user">
            <div className="ui-glass cv-user__bubble selectable">{start.task}</div>
          </div>
        )}
        {waitingForSignIn ? signInStatus : <Thinking />}
        <AskRow {...(start.ask ? { ask: start.ask } : {})} {...(onAnswer ? { onAnswer } : {})} />
      </section>
    );
  }
  return (
    <section
      className="acpmux-cloud-start"
      data-state={start.state}
      data-look={arm}
      data-initialized={start.initialized ? "true" : undefined}
    >
      {bubble && (
        <div className="cv-user">
          <div className="ui-glass cv-user__bubble selectable">{start.task}</div>
        </div>
      )}
      {waitingForSignIn && signInStatus}
      {stalled && !start.ask && (
        <output className="acpmux-cloud-start__status" data-stalled="true">
          {t("cloudStart.stalled", {
            minutes: String(Math.round(CLOUD_START_STALL_MS / 60_000)),
            step:
              (rows.find((row) => row.status === "running") ?? rows.find((row) => row.status === "pending") ?? rows[0])
                ?.label ?? "",
          })}
        </output>
      )}
      {!failed && !stalled && !waitingForSignIn && !start.initialized && (
        <output className="acpmux-cloud-start__status">
          <Spinner size={14} loading />
          <span>{t("cloudStart.preparing")}</span>
        </output>
      )}
      {!failed && start.initialized && (
        <output className="acpmux-cloud-start__status acpmux-cloud-start__status--ready">
          <Check size={14} />
          <span>{t("cloudStartup.initialized")}</span>
        </output>
      )}
      <AskRow {...(start.ask ? { ask: start.ask } : {})} {...(onAnswer ? { onAnswer } : {})} />
      <div className="acpmux-cloud-start__card">
        <button
          type="button"
          className="acpmux-cloud-start__summary"
          aria-expanded={expanded}
          onClick={() => setExpanded((value) => !value)}
        >
          <span>{start.initialized ? t("cloudStartup.initialized") : t("cloudStartup.title")}</span>
          {expanded ? (
            <ChevronDown size={14} />
          ) : start.initialized ? (
            <span aria-hidden>›</span>
          ) : (
            <ChevronRight size={14} />
          )}
        </button>
        {expanded && (
          <div className="acpmux-cloud-start__details">
            <div className="acpmux-cloud-start__checklist" aria-label={t("cloudStartup.checklist")}>
              {rows.map((step) => (
                <div key={step.id} className="acpmux-cloud-start__row" data-status={step.status} data-step-id={step.id}>
                  <span className="acpmux-cloud-start__mark">{mark(step, t)}</span>
                  <span className="acpmux-cloud-start__row-label">{step.label}</span>
                  {step.duration && <time className="acpmux-cloud-start__time">{step.duration}</time>}
                  {step.id === "setup" && step.action ? (
                    <span className="acpmux-cloud-start__detail">
                      {onOpenEnvironment ? (
                        <button type="button" className="acpmux-cloud-start__link" onClick={openEnvironment}>
                          {t("cloudStartup.setupHint")}
                        </button>
                      ) : (
                        t("cloudStartup.setupHint")
                      )}
                    </span>
                  ) : step.detail ? (
                    <span
                      className={`acpmux-cloud-start__detail${step.logTail ? " acpmux-cloud-start__log-tail" : ""}`}
                    >
                      {step.detail}
                    </span>
                  ) : null}
                  {step.link && (
                    <span className="acpmux-cloud-start__detail">
                      <a className="acpmux-cloud-start__link" href={step.link.href} target="_blank" rel="noreferrer">
                        {step.link.label}
                      </a>
                    </span>
                  )}
                </div>
              ))}
            </div>
            {known.length > 0 && (
              <ul className="acpmux-cloud-start__chips" data-look={arm}>
                {known.map((fact) => (
                  <li key={fact.id} data-fact={fact.id}>
                    {fact.id === "folder" ? (
                      <Folder size={12} />
                    ) : (
                      <span className="acpmux-cloud-start__label">{fact.label}</span>
                    )}
                    <span>{fact.value}</span>
                  </li>
                ))}
              </ul>
            )}
            {arm === "steps" && !failed && (
              <ol className="acpmux-cloud-start__legacy-steps" aria-hidden>
                {CLOUD_START_STEPS.map((name, index) => {
                  const current = start.step ? CLOUD_START_STEPS.indexOf(start.step) : -1;
                  const state = index < current ? "done" : index === current ? "current" : "next";
                  return (
                    <li key={name} data-step={state}>
                      {name}
                    </li>
                  );
                })}
              </ol>
            )}
          </div>
        )}
      </div>
      {planTeamRefusal}
      {failed && !planTeamRefusal && (
        <div className="acpmux-cloud-start__failure" role="alert">
          <output className="acpmux-cloud-start__status">{start.message ?? t("sandbox.failed")}</output>
          {signInRequired && (
            <button
              type="button"
              className="acpmux-cloud-start__sign-in"
              onClick={signIn}
              disabled={signingIn}
              aria-busy={signingIn}
            >
              {t("cloudStart.signInToContinue")}
            </button>
          )}
        </div>
      )}
      {failed && !planTeamRefusal && start.code === "cloud_plan_required" && (onUpgrade || onRunHere || onDismiss) && (
        <span className="acpmux-cloud-ask__actions">
          {onUpgrade && (
            <button type="button" className="acpmux-cloud-ask__button" data-role="default" onClick={() => onUpgrade()}>
              {planLabels.upgrade}
            </button>
          )}
          {onRunHere && (
            <button type="button" className="acpmux-cloud-ask__button" onClick={() => onRunHere()}>
              {planLabels.runHere}
            </button>
          )}
          {onDismiss && (
            <button type="button" className="acpmux-cloud-ask__button" onClick={() => onDismiss()}>
              {t("harness.notNow")}
            </button>
          )}
        </span>
      )}
      {/* The team's spending cap or the member's budget refused the machine (cloudStartProgress `spendRefusal`):
          the card says an admin can raise it; This Mac runs the same prompt now, Not now leaves the draft. */}
      {failed &&
        (start.code === "cloud_spend_cap" || start.code === "cloud_member_budget") &&
        (onRunHere || onDismiss) && (
          <span className="acpmux-cloud-ask__actions">
            {onRunHere && (
              <button
                type="button"
                className="acpmux-cloud-ask__button"
                data-role="default"
                onClick={() => onRunHere()}
              >
                {planLabels.runHere}
              </button>
            )}
            {onDismiss && (
              <button type="button" className="acpmux-cloud-ask__button" onClick={() => onDismiss()}>
                {t("harness.notNow")}
              </button>
            )}
          </span>
        )}
      {failed && start.retryable && onRetry && (
        <span className="acpmux-cloud-ask__actions">
          <button
            type="button"
            className="acpmux-cloud-ask__button acpmux-cloud-start__retry"
            data-role="default"
            onClick={onRetry}
          >
            {t("retry.action")}
          </button>
        </span>
      )}
    </section>
  );
}
