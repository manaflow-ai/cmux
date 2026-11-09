import { useEffect, useState } from "react";
import { experimentArm } from "../../experiments/experiment";
import { usePageNow } from "../../ui/pageClock";
import { cloudStartLook, cloudStartQuietLook } from "./cloudStart.experiment";
import { CloudStartAsk } from "./CloudStartAsk";
import { CLOUD_START_STEPS, type CloudStartAsk as Ask, type CloudStartProgress } from "./cloudStartProgress";
import { AlertCircle, Check, ChevronDown, ChevronRight, Folder, Spinner } from "./conversation/icons";

import { ShimmerText } from "./conversation/ShimmerText";
import { Thinking } from "./conversation/Thinking";
import { formatDuration } from "./conversation/turns";
import { usePaneLanguage, useT, type Translate } from "./i18n";
import { cloudPlanRecoveryLabels } from "./cloudPlanRecoveryLabels";
import "./cloudStart.css";
import { type ChecklistStep, type QuietStage, quietStage, startupChecklist } from "./cloudStartViewModel";

type QuietLook = "inline" | "stacked" | "hint" | "thinking";

/// The quiet view's one line while a start is on its way: the stage's words in the live line's look
/// (the local Thinking line's shimmer, so the start still reads as a local first turn), its clock,
/// then why the chat waits and for about how long (Leo, 2026-11-09: "the ergonomic part is super big
/// for us."). Never the step list: that stays behind a failure (cloudStartQuietLook's arms).
function StageLine({ stage, look, now }: { stage: QuietStage; look: Exclude<QuietLook, "thinking">; now: number }) {
  const clock = stage.since === undefined ? undefined : formatDuration(Math.max(0, now - stage.since));
  const eta = (
    <span className="cv-worked__count acpmux-cloud-start__eta">
      <span className="cv-worked__sep" aria-hidden="true">
        ·
      </span>
      <span>{stage.eta}</span>
    </span>
  );
  return (
    <div className="acpmux-cloud-start__stage" data-look={look} data-stage={stage.id}>
      <div className="cv-worked cv-worked--live" data-find-skip>
        <span className="cv-shimmer__row">
          <output className="cv-thinking is-shimmer">
            <ShimmerText text={stage.label} />
          </output>
          {clock && <span className="cv-worked__time">{clock}</span>}
        </span>
        {look !== "stacked" && eta}
      </div>
      {look === "stacked" && <div className="acpmux-cloud-start__eta-line">{stage.eta}</div>}
      {look === "hint" && (
        <div className="acpmux-cloud-start__hint" aria-hidden="true">
          {Array.from({ length: stage.steps }, (_, index) => (
            <span
              key={index}
              data-step={index + 1 < stage.step ? "done" : index + 1 === stage.step ? "current" : "next"}
            />
          ))}
        </div>
      )}
    </div>
  );
}
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

export function CloudStartView({
  start,
  bubble = true,
  showSteps = false,
  quietLook,
  onOpenEnvironment,
  onAnswer,
  onRetry,
  onSignIn,
  onUpgrade,
  onRunHere,
  onDismiss,
}: {
  start: CloudStartProgress;
  bubble?: boolean;
  /// The startup steps while the start is on its way (galleries and tests); off, the start reads as a
  /// local first turn and only a failure shows them.
  showSteps?: boolean;
  /// The quiet line's look (galleries and tests); otherwise the `cloud-start-quiet-look` arm.
  quietLook?: QuietLook;
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
}) {
  const t = useT();
  const arm = experimentArm(cloudStartLook);
  const failed = start.state === "failed";
  // The chat shell is useful before the machine is ready, so keep the expensive startup
  // checklist out of the way until someone asks for it. A failure is the one time we open it
  // automatically: the failed row and its log tail explain what needs attention.
  const [expanded, setExpanded] = useState(failed);
  const signInRequired = failed && start.code === "not_signed_in" && onSignIn;
  const [signingIn, setSigningIn] = useState(false);
  const now = usePageNow(!start.initialized && start.state !== "failed");
  useEffect(() => {
    if (failed) setExpanded(true);
    else if (start.initialized) setExpanded(false);
  }, [failed, start.initialized]);
  const language = usePaneLanguage();
  const planLabels = cloudPlanRecoveryLabels(language);
  const rows = startupChecklist(start, t, now, language);
  const known = facts(start, t);
  const look = quietLook ?? experimentArm(cloudStartQuietLook);
  const stage = look === "thinking" ? undefined : quietStage(start, rows, t);
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
  // The line names the stage the start is on, why it waits and about how long (cloudStartViewModel
  // `quietStage`), in the Thinking line's look; once the agent has started it is Thinking again.
  // A start that waits on the person's browser sign-in says that instead: nothing runs until they finish.
  const waitingForSignIn = !failed && start.signingIn === true;
  const signInStatus = (
    <output className="acpmux-cloud-start__status" data-signing-in="true" aria-busy="true">
      <Spinner size={14} loading />
      <span>{t("cloudStart.waitingForSignIn")}</span>
    </output>
  );
  if (!failed && !showSteps) {
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
        {waitingForSignIn ? (
          signInStatus
        ) : stage && look !== "thinking" ? (
          <StageLine stage={stage} look={look} now={now} />
        ) : (
          <Thinking />
        )}
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
      {!failed && !waitingForSignIn && !start.initialized && (
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
      {failed && (
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
      {failed && start.code === "cloud_plan_required" && (onUpgrade || onRunHere || onDismiss) && (
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
