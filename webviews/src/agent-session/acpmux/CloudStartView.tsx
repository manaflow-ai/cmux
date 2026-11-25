import { useEffect, useId, useRef, useState } from "react";
import { experimentArm } from "../../experiments/experiment";
import { usePageNow } from "../../ui/pageClock";
import { cloudStartLook, cloudStartQuietLook } from "./cloudStart.experiment";
import { CloudStartAsk } from "./CloudStartAsk";
import {
  CLOUD_START_STALL_MS,
  CLOUD_START_STEPS,
  cloudStartWayOn,
  type CloudFolderTooBig,
  type CloudStartAsk as Ask,
  type CloudStartProgress,
} from "./cloudStartProgress";
import { AlertCircle, Check, ChevronDown, ChevronRight, Folder } from "./conversation/icons";

import { DelayedSpinner, SPINNER_DELAY_MS } from "./conversation/DelayedSpinner";
import { ShimmerText } from "./conversation/ShimmerText";
import { cloudStartGoes } from "./cloudStartJustGo.experiment";
import { Thinking } from "./conversation/Thinking";
import { CloudSetupCard } from "./conversation/CloudSetupCard";
import { CloudSetupSteps, cloudSetupStep, type CloudSetupStepsLook } from "./conversation/CloudSetupSteps";
import type { CloudSetupAction } from "./cloudSetup";
import { usePaneLanguage, useT, type Translate } from "./i18n";
import { cloudPlanRecoveryLabels } from "./cloudPlanRecoveryLabels";
import type { CloudPlanTeam, CloudPlanTeamRefusal } from "./cloudPlanTeams";
import {
  CLOUD_PLAN_IDS,
  CLOUD_PLANS,
  sizeFits,
  type CloudPlanId,
  type CloudPlanView,
  type CloudSizeLocked,
  cloudPlanMachineWords,
} from "./cloudPlans";
import { useCloudPlanSubscribe, type CloudPlanSubscribeStore } from "./cloudPlanSubscribe";
import { gitHubPickerStore, githubFullName, useGitHubPicker, type GitHubPickerStore } from "./githubRepos";
import "./cloudStart.css";
import { type ChecklistStep, startupChecklist, type QuietStage, quietStage, stageClock } from "./cloudStartViewModel";
import { CLOUD_SIGN_IN_ANSWERS } from "./cloudSignIn";
import { WithFacts } from "./chips/FactsHoverCard";

type QuietLook = "inline" | "stacked" | "hint" | "thinking";

/// When the stage on the line began: the host's start time, else the moment this view first showed
/// the stage, so the clock always counts (a host that sends no start time for a step still gets
/// seconds on its line, never a bare label). A new stage starts its own count.
export function useStageSince(stage: Pick<QuietStage, "id" | "since"> | undefined, now: number): number | undefined {
  // State, not a ref, so the React Compiler keeps compiling the line (check:compiler-bails): a new stage
  // sets it during render, React's pattern for state that follows a prop.
  const [seen, setSeen] = useState<{ id: QuietStage["id"]; at: number } | undefined>(
    stage ? { id: stage.id, at: now } : undefined,
  );
  const id = stage?.id;
  if (seen?.id !== id) {
    const next = stage ? { id: stage.id, at: now } : undefined;
    setSeen(next);
    return stage ? (stage.since ?? now) : undefined;
  }
  return stage ? (stage.since ?? seen?.at) : undefined;
}

/// The quiet view's one line while a start is on its way: the stage's words in the live line's look
/// (the local Thinking line's shimmer, so the start still reads as a local first turn) and its live
/// clock ("12s", then "1:05"), then the copy's own progress when it reports one (Leo, 2026-11-09:
/// "the ergonomic part is super big for us."; Austin, 2026-11-24: "show the seconds, dont need to
/// show usually under a minute that stuff"). Never the step list: that stays behind a failure
/// (cloudStartQuietLook's arms).
function StageLine({ stage, look, now }: { stage: QuietStage; look: Exclude<QuietLook, "thinking">; now: number }) {
  const since = useStageSince(stage, now);
  const clock = since === undefined ? undefined : stageClock(Math.max(0, now - since));
  const detail = stage.detail && (
    <span className="cv-worked__count acpmux-cloud-start__progress">
      <span className="cv-worked__sep" aria-hidden="true">
        ·
      </span>
      <span>{stage.detail}</span>
    </span>
  );
  return (
    <div className="acpmux-cloud-start__stage" data-look={look} data-stage={stage.id}>
      <div className="cv-worked cv-worked--live" data-find-skip>
        <span className="cv-shimmer__row">
          <output className="cv-thinking is-shimmer">
            <ShimmerText text={stage.label} />
          </output>
          {clock && (
            <time className="cv-worked__time" data-stage-clock>
              {clock}
            </time>
          )}
        </span>
        {look !== "stacked" && detail}
      </div>
      {look === "stacked" && stage.detail && <div className="acpmux-cloud-start__progress-line">{stage.detail}</div>}
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
/// A start's spinners wait 300 ms (Leo, 2026-11-25, "just go"); the `hold` arm shows them at once.
function spinnerDelay(): number {
  return cloudStartGoes() ? SPINNER_DELAY_MS : 0;
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
        <DelayedSpinner size={16} delayMs={spinnerDelay()} />
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

/// One plan of the pricing card: its name, its price a month, the largest machine it includes, and Subscribe.
function PlanOffer({
  plan,
  filled,
  pending,
  onSubscribe,
}: {
  plan: CloudPlanId;
  filled: boolean;
  pending: CloudPlanId | undefined;
  onSubscribe: (plan: CloudPlanId) => void;
}) {
  const t = useT();
  const nameId = useId();
  const offer = CLOUD_PLANS[plan];
  return (
    <li className="acpmux-cloud-plans__plan" data-plan={plan}>
      <span className="acpmux-cloud-ask__title" id={nameId}>
        {offer.name}
      </span>
      <span className="acpmux-cloud-plans__price">{t("cloudStart.plans.perMonth", { price: offer.price })}</span>
      <span className="acpmux-cloud-ask__line">
        {t("cloudStart.plans.includes", { size: cloudPlanMachineWords(plan, t) })}
      </span>
      <button
        type="button"
        className="acpmux-cloud-ask__button"
        data-action="subscribe"
        data-plan={plan}
        aria-describedby={nameId}
        {...(filled ? { "data-role": "default" } : {})}
        disabled={pending !== undefined}
        aria-busy={pending === plan}
        onClick={() => onSubscribe(plan)}
      >
        {t("cloudStart.plans.subscribe")}
      </button>
    </li>
  );
}

/// The pricing card: a Cloud send the account has no plan for (the platform's `cloud_plan_required`, or the page's
/// own hold when `cloudMachine.list` says `plan.state` `none`). A final state, no retry and no wait: cmux NEXT Plus, Pro and
/// Max side by side (or the plans the refusal named, `plans`), each with Subscribe (`cloud.plan.subscribe`, the start
/// goes again by itself once the plan is on, cloudPlanSubscribe.ts), then Run on This Mac and Not now. A refusal in a team (`refusal`) names the team the send
/// was in (the one picked in the team menu, which is easy to miss) and offers the person's own team first, which
/// switches and sends again.
function PlanCard({
  refusal,
  plans: offered = CLOUD_PLAN_IDS,
  look,
  planStore,
  onSwitchTeam,
  onRunHere,
  onDismiss,
  runHereLabel,
  steps,
}: {
  /// A first send's plan step (no team refusal): the setup strip in place of the alert mark.
  steps?: CloudSetupStepsLook;
  refusal?: CloudPlanTeamRefusal;
  plans?: readonly CloudPlanId[];
  look: CloudPlanTeamLook;
  planStore?: CloudPlanSubscribeStore;
  onSwitchTeam?: (team: CloudPlanTeam) => void;
  onRunHere?: () => void;
  onDismiss?: () => void;
  runHereLabel: string;
}) {
  const t = useT();
  const subscriber = useCloudPlanSubscribe(planStore);
  const switchTo = refusal?.switchTo;
  const switchLeads = Boolean(switchTo && onSwitchTeam);
  const subscribe = (plan: CloudPlanId) => subscriber.start(plan, (view: CloudPlanView) => view.state === "active");
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
  const title = (
    <strong className="acpmux-cloud-plan-team__title">
      {t(refusal ? "cloudStart.planTeam.title" : "cloudStart.plans.title")}
    </strong>
  );
  const team = refusal && (
    <span className="acpmux-cloud-plan-team__team">{t("cloudStart.planTeam.selected", { team: refusal.team })}</span>
  );
  const plans = (
    <ul className="acpmux-cloud-plans">
      {offered.map((plan, index) => (
        <PlanOffer
          key={plan}
          plan={plan}
          filled={!switchLeads && index === 0}
          pending={subscriber.state.pending}
          onSubscribe={subscribe}
        />
      ))}
    </ul>
  );
  const error = subscriber.state.error && (
    <output className="acpmux-cloud-start__status" data-subscribe-error="true">
      {subscriber.state.error}
    </output>
  );
  if (steps && !refusal) {
    return (
      <div className="acpmux-cloud-plan-team" data-look={look} data-plans="true" data-setup-step="plan">
        <CloudSetupSteps current="plan" look={steps} />
        {title}
        {plans}
        {actions}
        {error}
      </div>
    );
  }
  return (
    <div className="acpmux-cloud-plan-team" data-look={look} data-plans="true" role="alert">
      {look === "banner" ? (
        <>
          <div className="acpmux-cloud-plan-team__head">
            <AlertCircle size={14} />
            {title}
            {actions}
          </div>
          {team}
          {plans}
          {error}
        </>
      ) : (
        <>
          <div className="acpmux-cloud-plan-team__head">
            <AlertCircle size={14} />
            {title}
          </div>
          {team}
          {plans}
          {actions}
          {error}
        </>
      )}
    </div>
  );
}

/// A folder that needs a larger machine than the plan includes (`cloud_size_locked`): the plan that includes it
/// (Upgrade to Max, `cloud.plan.subscribe`; none on the largest plan already), This Mac, and Retry. The start goes
/// again by itself once the plan read back admits the size.
function SizeLockedActions({
  locked,
  planStore,
  onRunHere,
  onRetry,
  runHereLabel,
}: {
  locked: CloudSizeLocked;
  planStore?: CloudPlanSubscribeStore;
  onRunHere?: () => void;
  onRetry?: () => void;
  runHereLabel: string;
}) {
  const t = useT();
  const subscriber = useCloudPlanSubscribe(planStore);
  const upgrade = locked.upgradePlan;
  return (
    <>
      <span className="acpmux-cloud-ask__actions" data-size-locked={locked.needed}>
        {upgrade && (
          <button
            type="button"
            className="acpmux-cloud-ask__button"
            data-role="default"
            data-action="upgrade"
            data-plan={upgrade}
            disabled={subscriber.state.pending !== undefined}
            aria-busy={subscriber.state.pending === upgrade}
            onClick={() =>
              subscriber.start(upgrade, (view) => view.state === "active" && sizeFits(locked.needed, view.maxSize))
            }
          >
            {t("cloudStart.sizeLocked.upgrade", { plan: CLOUD_PLANS[upgrade].name })}
          </button>
        )}
        {onRunHere && (
          <button
            type="button"
            className="acpmux-cloud-ask__button"
            data-action="run-here"
            {...(upgrade ? {} : { "data-role": "default" })}
            onClick={() => onRunHere()}
          >
            {runHereLabel}
          </button>
        )}
        {onRetry && (
          <button type="button" className="acpmux-cloud-ask__button acpmux-cloud-start__retry" onClick={onRetry}>
            {t("retry.action")}
          </button>
        )}
      </span>
      {subscriber.state.error && (
        <output className="acpmux-cloud-start__status" data-subscribe-error="true">
          {subscriber.state.error}
        </output>
      )}
    </>
  );
}

/** Start refusals that name what to do in their own card, with no failed step for the checklist to show. */
const POLICY_REFUSALS: ReadonlySet<string> = new Set([
  "cloud_plan_required",
  "cloud_spend_cap",
  "cloud_member_budget",
  "cloud_folder_too_big",
  "cloud_setup_required",
  "cloud_size_locked",
]);

/// A folder too big to copy (cloudStartProgress `tooBig`): each repository inside it starts the chat there, then
/// another folder (only when no repository or more than the card lists) and no folder. Never a Retry: it fails the same way.
function TooBigActions({
  tooBig,
  onPickRepo,
  onPickFolder,
  onStartWithoutFolder,
}: {
  tooBig: CloudFolderTooBig;
  onPickRepo?: (path: string) => void;
  onPickFolder?: () => void;
  onStartWithoutFolder?: () => void;
}) {
  const t = useT();
  const repos = onPickRepo ? tooBig.repos : [];
  const offerFolder = onPickFolder && (repos.length === 0 || tooBig.more);
  return (
    <div className="acpmux-cloud-too-big" data-repos={repos.length}>
      {repos.length > 0 && onPickRepo && (
        <>
          <span className="acpmux-cloud-too-big__label">{t("cloudStart.pickRepo")}</span>
          <fieldset
            className="acpmux-cloud-ask__actions acpmux-cloud-too-big__repos"
            aria-label={t("cloudStart.pickRepo")}
          >
            {repos.map((repo) => (
              <WithFacts key={repo.path} facts={[{ value: repo.path, code: true }]}>
                {(facts) => (
                  <button
                    {...facts}
                    type="button"
                    className="acpmux-cloud-ask__button acpmux-cloud-too-big__repo"
                    data-repo={repo.path}
                    onClick={() => onPickRepo(repo.path)}
                  >
                    {repo.name}
                  </button>
                )}
              </WithFacts>
            ))}
          </fieldset>
        </>
      )}
      {(offerFolder || onStartWithoutFolder) && (
        <span className="acpmux-cloud-ask__actions">
          {offerFolder && (
            <button
              type="button"
              className="acpmux-cloud-ask__button"
              data-action="pick-folder"
              {...(repos.length === 0 ? { "data-role": "default" } : {})}
              onClick={() => onPickFolder?.()}
            >
              {t("cloudStart.pickFolder")}
            </button>
          )}
          {onStartWithoutFolder && (
            <button
              type="button"
              className="acpmux-cloud-ask__button"
              data-action="no-folder"
              onClick={() => onStartWithoutFolder()}
            >
              {t("cloudStart.startWithoutFolder")}
            </button>
          )}
        </span>
      )}
    </div>
  );
}

/// A start that connecting GitHub would let go on (`seed.needs_github`: a folder too big to copy whose way is a GitHub
/// clone, or a picked repository the cmux GitHub App does not reach): Connect GitHub opens the install or its settings
/// (`github.connect`, the folder menu's own call), then Retry runs the same start. A refused call says why under it.
///
/// The click names the start's repository (#55104), so the API reuses a connection that already covers it or sends the
/// person through GitHub's authorize page, which comes back to the app. Then the start goes again by itself: at once
/// when a connection covered it, else once the app says it finished the connection.
function ConnectGitHubAction({
  store,
  repository,
  onConnected,
}: {
  store?: GitHubPickerStore;
  repository?: string;
  onConnected?: () => void;
}) {
  const t = useT();
  const picker = store ?? gitHubPickerStore();
  const github = useGitHubPicker(picker);
  const waiting = useRef<(() => void) | undefined>(undefined);
  const retry = useRef(onConnected);
  useEffect(() => {
    retry.current = onConnected;
  }, [onConnected]);
  // Unmounted (the start went on, or the chat closed): a connect still out retries nothing.
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      waiting.current?.();
      waiting.current = undefined;
    };
  }, []);
  const connect = () => {
    void picker.connectRepo(githubFullName(repository)).then((outcome) => {
      if (!mounted.current) return;
      if (outcome === "connected") retry.current?.();
      else if (outcome === "opened" && !waiting.current)
        waiting.current = picker.afterChange(() => {
          waiting.current = undefined;
          retry.current?.();
        });
    });
  };
  return (
    <>
      <button
        type="button"
        className="acpmux-cloud-ask__button"
        data-role="default"
        data-action="connect-github"
        onClick={connect}
      >
        {t("cloudRepository.connect")}
      </button>
      {github.state.connectError && (
        <output className="acpmux-cloud-start__status" data-connect-error="true">
          {github.state.connectError}
        </output>
      )}
    </>
  );
}

/// A failed start's way on when it has no recovery of its own (cloudStartProgress `cloudStartWayOn`): each button only
/// where App passes its handler, the first filled. Never Retry for a refusal that fails the same way again.
function WayOnActions({
  start,
  handlers,
  runHereLabel,
}: {
  start: CloudStartProgress;
  handlers: {
    retry?: () => void;
    "pick-folder"?: () => void;
    "no-folder"?: () => void;
    "new-cloud-chat"?: () => void;
    "run-here"?: () => void;
    dismiss?: () => void;
  };
  runHereLabel: string;
}) {
  const t = useT();
  const shown = cloudStartWayOn(start).flatMap((id) => {
    const run = handlers[id];
    return run ? [{ id, run }] : [];
  });
  if (shown.length === 0) return null;
  const label = (id: (typeof shown)[number]["id"]) => {
    switch (id) {
      case "retry":
        return t("retry.action");
      case "pick-folder":
        return t("cloudStart.pickFolder");
      case "no-folder":
        return t("cloudStart.startWithoutFolder");
      case "new-cloud-chat":
        return t("cloudStart.openNewCloudChat");
      case "run-here":
        return runHereLabel;
      case "dismiss":
        return t("harness.notNow");
    }
  };
  return (
    <span className="acpmux-cloud-ask__actions acpmux-cloud-start__way-on">
      {shown.map(({ id, run }, index) => (
        <button
          key={id}
          type="button"
          className={`acpmux-cloud-ask__button${id === "retry" ? " acpmux-cloud-start__retry" : ""}`}
          data-action={id}
          {...(index === 0 ? { "data-role": "default" } : {})}
          onClick={() => run()}
        >
          {label(id)}
        </button>
      ))}
    </span>
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
  onRunHere,
  onDismiss,
  onSwitchTeam,
  onPickRepo,
  onPickFolder,
  onStartWithoutFolder,
  onSetUp,
  onSetUpDismiss,
  onOpenNewCloudChat,
  githubStore,
  planStore,
  planTeamLook = "notice",
  setupStepsLook = "rail",
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
  /// A plan refusal's recovery (`cloud_plan_required`, `cloud_size_locked`): the same prompt on this Mac, or leave
  /// the card (the draft stays in the composer). Its Subscribe goes through `planStore`.
  onRunHere?: () => void;
  onDismiss?: () => void;
  /// A plan refusal in a team: switch to the person's own team (the team picker's switch) and send again.
  onSwitchTeam?: (team: CloudPlanTeam) => void;
  /// A folder too big to copy (`cloud_folder_too_big`): start the same prompt in a repository inside it (its path),
  /// in another folder the person picks, or with no folder.
  onPickRepo?: (path: string) => void;
  onPickFolder?: () => void;
  onStartWithoutFolder?: () => void;
  /// Set up Cloud's buttons (`cloud_setup_required`, cloudSetup.ts): one of Settings > Models' ways in, then
  /// the start goes again by itself once a connection serves the model; and its Not now.
  onSetUp?: (action: CloudSetupAction) => void;
  onSetUpDismiss?: () => void;
  /// A start refused because a chat is already starting in this tab (`unavailable_now`): a new Cloud chat with the
  /// same prompt and folder, as the held send's refusal offers.
  onOpenNewCloudChat?: () => void;
  /// The GitHub connection Connect GitHub uses (`seed.needs_github`); the page's own when absent (galleries and tests pass theirs).
  githubStore?: GitHubPickerStore;
  /// The pricing card's Subscribe and its wait for the plan (cloudPlanSubscribe.ts); the page's own when absent.
  planStore?: CloudPlanSubscribeStore;
  /// The plan-in-a-team look (galleries compare them); the pane draws `notice`.
  planTeamLook?: CloudPlanTeamLook;
  /// The first-send setup strip's look (galleries compare them); the pane draws `rail`.
  setupStepsLook?: CloudSetupStepsLook;
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
  const signInTitleId = useId();
  const now = usePageNow(!start.initialized && start.state !== "failed");
  useEffect(() => {
    if (autoOpen) setExpanded(true);
    else if (start.initialized) setExpanded(false);
  }, [autoOpen, start.initialized]);
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
      <DelayedSpinner size={14} delayMs={spinnerDelay()} />
      <span>{t("cloudStart.waitingForSignIn")}</span>
    </output>
  );
  const needsGitHub = failed && start.code === "seed.needs_github";
  const sizeLocked = failed && start.code === "cloud_size_locked" ? start.sizeLocked : undefined;
  const planTeamRefusal = failed && start.code === "cloud_plan_required" && (
    <PlanCard
      look={planTeamLook}
      steps={setupStepsLook}
      runHereLabel={planLabels.runHere}
      {...(start.planTeam ? { refusal: start.planTeam } : {})}
      {...(start.plans ? { plans: start.plans } : {})}
      {...(planStore ? { planStore } : {})}
      {...(onSwitchTeam ? { onSwitchTeam } : {})}
      {...(onRunHere ? { onRunHere } : {})}
      {...(onDismiss ? { onDismiss } : {})}
    />
  );
  // Nothing serves the picked model (checked before any machine): Set up Cloud in place of the start,
  // also while a button's way in is out (`signingIn`), until the start goes again.
  const setup = (failed && start.code === "cloud_setup_required") || start.signingIn ? start.cloudSetup : undefined;
  if (setup) {
    return (
      <section className="acpmux-cloud-start" data-state={start.state} data-setup="true">
        {bubble && (
          <div className="cv-user">
            <div className="ui-glass cv-user__bubble selectable">{start.task}</div>
          </div>
        )}
        <CloudSetupCard
          need={setup}
          steps={setupStepsLook}
          waiting={!failed}
          {...(onSetUp ? { onSetUp } : {})}
          {...(onSetUpDismiss ? { onDismiss: onSetUpDismiss } : {})}
          {...(onSetUpDismiss && !failed ? { onCancel: onSetUpDismiss } : {})}
        />
      </section>
    );
  }
  // Not signed in (checked before anything starts): the first setup step, not a failure. The card says what Cloud
  // needs and keeps the prompt; Sign in opens the browser and the start goes again by itself, This Mac runs it here,
  // Not now leaves the draft. While the browser is out the same card waits, so the person keeps their place.
  if (cloudSetupStep(start) === "account") {
    const timedOut = failed && start.message === CLOUD_SIGN_IN_ANSWERS.expired.message;
    return (
      <section className="acpmux-cloud-start" data-state="setup" data-setup-step="account">
        {bubble && (
          <div className="cv-user">
            <div className="ui-glass cv-user__bubble selectable">{start.task}</div>
          </div>
        )}
        <section
          className="acpmux-cloud-setup"
          aria-labelledby={signInTitleId}
          data-waiting={waitingForSignIn || undefined}
        >
          <CloudSetupSteps current="account" look={setupStepsLook} />
          <strong className="acpmux-cloud-setup__title" id={signInTitleId}>
            {t("cloudSetup.title")}
          </strong>
          <p className="acpmux-cloud-setup__body">
            {timedOut ? start.message : t("cloudSetup.signIn.body")} {t("cloudSetup.keepsPrompt")}
          </p>
          {waitingForSignIn && signInStatus}
          <span className="acpmux-cloud-ask__actions acpmux-cloud-setup__actions">
            <button
              type="button"
              className="acpmux-cloud-ask__button acpmux-cloud-start__sign-in"
              data-role="default"
              data-action="sign-in"
              onClick={signIn}
              disabled={signingIn || waitingForSignIn || !onSignIn}
              aria-busy={signingIn || waitingForSignIn}
            >
              {t("cloudStart.signInToContinue")}
            </button>
            {/* Only once the start has failed: while the browser is out the prompt is held for the sign-in, so
                Run on This Mac there would switch modes and send an empty composer. */}
            {onRunHere && failed && (
              <button
                type="button"
                className="acpmux-cloud-ask__button"
                data-action="run-here"
                onClick={() => onRunHere()}
              >
                {planLabels.runHere}
              </button>
            )}
            {onDismiss && failed && (
              <button
                type="button"
                className="acpmux-cloud-ask__button"
                data-action="dismiss"
                onClick={() => onDismiss()}
              >
                {t("harness.notNow")}
              </button>
            )}
          </span>
        </section>
      </section>
    );
  }
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
      {/* What Return queued during the start: it goes with the started chat's first prompt. */}
      {bubble &&
        start.queued?.map((text, index) => (
          <div className="cv-user" key={index} data-queued="true">
            <div className="ui-glass cv-user__bubble selectable">{text}</div>
          </div>
        ))}
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
          <DelayedSpinner size={14} delayMs={spinnerDelay()} />
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
      {sizeLocked && (
        <SizeLockedActions
          locked={sizeLocked}
          runHereLabel={planLabels.runHere}
          {...(planStore ? { planStore } : {})}
          {...(onRunHere ? { onRunHere } : {})}
          {...(onRetry ? { onRetry } : {})}
        />
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
      {failed && start.code === "cloud_folder_too_big" && start.tooBig && (
        <TooBigActions
          tooBig={start.tooBig}
          {...(onPickRepo ? { onPickRepo } : {})}
          {...(onPickFolder ? { onPickFolder } : {})}
          {...(onStartWithoutFolder ? { onStartWithoutFolder } : {})}
        />
      )}
      {failed && (
        <WayOnActions
          start={start}
          runHereLabel={planLabels.runHere}
          handlers={{
            ...(onRetry ? { retry: onRetry } : {}),
            ...(onPickFolder ? { "pick-folder": onPickFolder } : {}),
            ...(onStartWithoutFolder ? { "no-folder": onStartWithoutFolder } : {}),
            ...(onOpenNewCloudChat ? { "new-cloud-chat": onOpenNewCloudChat } : {}),
            ...(onRunHere ? { "run-here": onRunHere } : {}),
            ...(onDismiss ? { dismiss: onDismiss } : {}),
          }}
        />
      )}
      {failed && !planTeamRefusal && !sizeLocked && ((start.retryable && onRetry) || needsGitHub) && (
        <span className="acpmux-cloud-ask__actions">
          {needsGitHub && (
            <ConnectGitHubAction
              {...(githubStore ? { store: githubStore } : {})}
              {...(start.repository ? { repository: start.repository } : {})}
              {...(start.retryable && onRetry ? { onConnected: onRetry } : {})}
            />
          )}
          {start.retryable && onRetry && (
            <button
              type="button"
              className="acpmux-cloud-ask__button acpmux-cloud-start__retry"
              {...(needsGitHub ? {} : { "data-role": "default" })}
              onClick={onRetry}
            >
              {t("retry.action")}
            </button>
          )}
        </span>
      )}
    </section>
  );
}
