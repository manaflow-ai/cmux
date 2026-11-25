// A new worktree chat's setup (design/worktree-setup.md): when New Worktree makes a worktree whose
// project has a recipe, the session host copies the include files and runs the setup script after
// its reply (`git.worktree.create` answers `setup`). The chat opens at once; one line above the
// composer follows the setup (`git.worktree.setup`, read again with `since` = the last
// `output_end`) until its state is final, then stops reading. Its Output disclosure opens the
// Cloud start's checklist rows (Copy files, Run setup script) and the output, moving the composer
// with it; a failure opens it once by itself.
//
// A repository's own setup (`.cmux/worktree.toml`) waits in `awaiting_approval` until the person
// reads it: the line opens on the commands it would run and the ignored files it would copy into
// this worktree only, and Run Setup approves that recipe (`git.worktree.setup.run` with `approve`,
// its fingerprint). A failed, timed-out or interrupted setup offers Retry, which runs it again.
import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { usePageNow, visibleInterval } from "../../ui/pageClock";
import {
  SETUP_READ_DEADLINE_MS,
  SETUP_READ_INTERVAL_MS,
  appendSetupOutput,
  isFinalSetupState,
  readSetupReply,
  type ResolvedWorktreeRecipe,
  type WorktreeSetupRun,
  type WorktreeSetupState,
} from "../../worktreeRecipe";
import { AlertCircle, Check, ChevronDown, ChevronRight, Spinner } from "./conversation/icons";
import { useT, type Translate } from "./i18n";
import {
  forgetWorktreeSetup,
  startedWorktreeSetup,
  subscribeWorktreeSetups,
  worktreeSetupsVersion,
  type WorktreeSetupStart,
} from "./worktreeSetupStore";
import "./cloudStart.css";
import "./worktreeSetup.css";

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

export { forgetWorktreeSetup, rememberWorktreeSetup, type WorktreeSetupStart } from "./worktreeSetupStore";

/** The setup this pane follows for `folder`, if any. */
export function useWorktreeSetupStart(folder: string | undefined): WorktreeSetupStart | undefined {
  useSyncExternalStore(subscribeWorktreeSetups, worktreeSetupsVersion);
  return folder ? startedWorktreeSetup(folder) : undefined;
}

/** A setup as the line draws it; `read` is false until the first `git.worktree.setup` answer.
 *  `recipe` is what the host resolved for the worktree, with its approval. */
export type SetupView = { run: WorktreeSetupRun; output: string; read: boolean; recipe?: ResolvedWorktreeRecipe };

type Repeat = (name: string, tick: () => void, every: () => number | null) => () => void;

/** Follows the setup of the worktree at `root`: reads it now, then every second while it is live
 *  and the page is visible (`repeat`, the page clock). It stops at a final state, at the first
 *  failed read (a host that cannot answer) and past the host's own setup deadline, both shown as
 *  interrupted, and when the returned stop runs. Reads never overlap. */
export function followWorktreeSetup(
  callNative: Native,
  root: string,
  onView: (view: SetupView) => void,
  repeat: Repeat = visibleInterval,
): () => void {
  let stopped = false;
  let inFlight = false;
  let since = "0";
  let output = "";
  let final = false;
  let last: WorktreeSetupRun | undefined;
  let recipe: ResolvedWorktreeRecipe | undefined;
  const deadline = Date.now() + SETUP_READ_DEADLINE_MS;
  // Reads that end before a final state end the line too, as interrupted, so it never spins on
  // with nothing following it and always offers Dismiss.
  const giveUp = () => {
    if (final || stopped) return;
    final = true;
    const run = last ?? { state: "interrupted", output: "", outputStart: "0", outputEnd: "0" };
    onView({ run: { ...run, state: "interrupted" }, output, read: true, ...(recipe ? { recipe } : {}) });
  };
  const read = () => {
    if (stopped || inFlight || final) return;
    inFlight = true;
    callNative("git.worktree.setup", { path: root, since })
      .then((reply) => {
        // A reply that lands after the deadline gave up changes nothing.
        if (stopped || final) return;
        const answer = readSetupReply(reply);
        // A reply that is not a setup read ends the reads, as a failed one does.
        if (!answer) {
          giveUp();
          return;
        }
        output = appendSetupOutput(output, since, answer.run);
        since = answer.run.outputEnd;
        last = answer.run;
        recipe = answer.recipe ?? recipe;
        final = isFinalSetupState(answer.run.state);
        onView({ run: answer.run, output, read: true, ...(recipe ? { recipe } : {}) });
      })
      .catch(giveUp)
      .finally(() => {
        inFlight = false;
      });
  };
  read();
  const stop = repeat("worktree-setup", read, () => {
    if (!final && Date.now() > deadline) giveUp();
    return final || stopped ? null : SETUP_READ_INTERVAL_MS;
  });
  return () => {
    stopped = true;
    stop();
  };
}

/** The setup of the worktree at `root` as the line draws it: the create reply's state until the
 *  first read answers. A new `generation` (after Run Setup or Retry) follows it again from the
 *  start, keeping the last view until the first new read answers. */
export function useWorktreeSetup(
  callNative: Native,
  root: string | undefined,
  start?: WorktreeSetupStart,
  generation = 0,
): SetupView | undefined {
  const [view, setView] = useState<SetupView | undefined>(undefined);
  const [viewRoot, setViewRoot] = useState(root);
  if (viewRoot !== root) {
    setViewRoot(root);
    setView(undefined);
  }
  useEffect(() => {
    if (!root) return;
    return followWorktreeSetup(callNative, root, setView);
  }, [callNative, root, generation]);
  if (view) return view;
  if (!start) return undefined;
  const run: WorktreeSetupRun = { state: start.state, output: "", outputStart: "0", outputEnd: "0" };
  if (start.port !== undefined) run.port = start.port;
  return { run, output: "", read: false };
}

type Status = "done" | "running" | "error" | "waiting";

export function setupStatus(state: WorktreeSetupState): Status {
  if (state === "awaiting_approval") return "waiting";
  return state === "succeeded" ? "done" : state === "copying" || state === "running" ? "running" : "error";
}

/** What the line offers once a setup stops: Run Setup (with the fingerprint of the recipe the person
 *  reads above it) while a repository recipe waits for its first yes, Retry after a setup that did not
 *  succeed, else nothing. A recipe that changed since its yes asks again rather than retrying. */
export type SetupAction = { kind: "approve"; fingerprint: string } | { kind: "retry" } | undefined;

export function setupAction(view: SetupView | undefined): SetupAction {
  if (!view?.read) return undefined;
  const { state } = view.run;
  const approval = view.recipe?.approval;
  const unanswered = approval && !approval.approved ? approval.fingerprint : undefined;
  if (state === "awaiting_approval")
    return unanswered ? { kind: "approve", fingerprint: unanswered } : { kind: "retry" };
  if (state !== "failed" && state !== "timed_out" && state !== "interrupted") return undefined;
  return unanswered ? { kind: "approve", fingerprint: unanswered } : { kind: "retry" };
}

/** The line's words for a state. A setup with no script that succeeded only copied files. */
export function setupLabel(run: WorktreeSetupRun, t: Translate, hasScript = true): string {
  switch (run.state) {
    case "awaiting_approval":
      return t("worktreeSetup.awaitingApproval");
    case "copying":
      return t("worktreeSetup.copying");
    case "running":
      return t("worktreeSetup.running");
    case "succeeded":
      return hasScript ? t("worktreeSetup.succeeded") : t("worktreeSetup.copied");
    case "timed_out":
      return t("worktreeSetup.timedOut");
    case "interrupted":
      return t("worktreeSetup.interrupted");
    default:
      return t("worktreeSetup.failed");
  }
}

/** "4.2s", "1m 12s": the Cloud start's step durations. */
export function setupDuration(
  startedMs: number | undefined,
  finishedMs: number | undefined,
  now: number,
): string | undefined {
  if (startedMs === undefined) return undefined;
  const ms = Math.max(0, (finishedMs ?? now) - startedMs);
  if (ms < 1000) return "<1s";
  if (ms < 60_000) return `${Math.round(ms / 100) / 10}s`;
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
}

/** The Cloud start checklist's mark: a spinner, a check, or the failure glyph, with its words for
 *  screen readers only (hidden in the mark's own box, never drawn over the label). */
export function SetupMark({ status }: { status: Status }) {
  const t = useT();
  return (
    <span className="acpmux-cloud-start__mark">
      {status === "done" ? (
        <Check size={14} />
      ) : status === "running" ? (
        <Spinner size={14} loading />
      ) : status === "waiting" ? (
        <span className="acpmux-cloud-start__pending-mark" aria-hidden />
      ) : (
        <AlertCircle size={14} />
      )}
      <span className="visually-hidden">
        {t(
          status === "done"
            ? "cloudStartup.state.done"
            : status === "running"
              ? "cloudStartup.state.running"
              : status === "waiting"
                ? "cloudStartup.state.pending"
                : "cloudStartup.state.error",
        )}
      </span>
    </span>
  );
}

/** What a repository recipe would do, read before it runs: its setup command, its teardown, and the
 *  ignored files it copies from the main checkout into this worktree only. */
export function SetupReview({ recipe }: { recipe: ResolvedWorktreeRecipe }) {
  const t = useT();
  const setup = recipe.setup?.trim();
  const teardown = recipe.teardown?.trim();
  return (
    <div className="acpmux-worktree-setup__details acpmux-worktree-setup__review">
      {setup && (
        <div className="acpmux-worktree-setup__review-part" data-part="setup">
          <span className="acpmux-worktree-setup__review-label">{t("worktreeSetup.reviewSetup")}</span>
          <pre className="acpmux-worktree-setup__output selectable">{setup}</pre>
        </div>
      )}
      {teardown && (
        <div className="acpmux-worktree-setup__review-part" data-part="teardown">
          <span className="acpmux-worktree-setup__review-label">{t("worktreeSetup.reviewTeardown")}</span>
          <pre className="acpmux-worktree-setup__output selectable">{teardown}</pre>
        </div>
      )}
      {recipe.include.length > 0 && (
        <div className="acpmux-worktree-setup__review-part" data-part="include">
          <span className="acpmux-worktree-setup__review-label">{t("worktreeSetup.reviewInclude")}</span>
          <pre className="acpmux-worktree-setup__output selectable">{recipe.include.join("\n")}</pre>
        </div>
      )}
    </div>
  );
}

/** The two Cloud start rows a worktree setup has (Copy files, Run setup script) and its output. */
export function SetupDetails({ view, now, hasScript }: { view: SetupView; now: number; hasScript: boolean }) {
  const t = useT();
  const { run } = view;
  const copyStatus: Status =
    run.state === "copying" ? "running" : run.state === "failed" && !hasScript ? "error" : "done";
  const scriptStatus: Status | undefined = !hasScript
    ? undefined
    : run.state === "copying"
      ? undefined
      : setupStatus(run.state);
  const log = useRef<HTMLPreElement>(null);
  const pinned = useRef(true);
  useLayoutEffect(() => {
    const element = log.current;
    if (element && pinned.current) element.scrollTop = element.scrollHeight;
  }, [view.output]);
  return (
    <div className="acpmux-worktree-setup__details acpmux-cloud-start">
      <div className="acpmux-cloud-start__checklist">
        <div className="acpmux-cloud-start__row" data-status={copyStatus} data-step-id="copy">
          <SetupMark status={copyStatus} />
          <span className="acpmux-cloud-start__row-label">{t("worktreeSetup.copyStep")}</span>
          {run.include && run.include.copied > 0 && (
            <span className="acpmux-cloud-start__time">
              {t("worktreeSetup.copiedCount", { count: run.include.copied })}
            </span>
          )}
        </div>
        {hasScript && (
          <div className="acpmux-cloud-start__row" data-status={scriptStatus ?? "pending"} data-step-id="setup">
            {scriptStatus ? (
              <SetupMark status={scriptStatus} />
            ) : (
              <span className="acpmux-cloud-start__mark">
                <span className="acpmux-cloud-start__pending-mark" aria-hidden />
                <span className="visually-hidden">{t("cloudStartup.state.pending")}</span>
              </span>
            )}
            <span className="acpmux-cloud-start__row-label">{t("cloudStartup.setup")}</span>
            {scriptStatus && (
              <time className="acpmux-cloud-start__time">{setupDuration(run.startedMs, run.finishedMs, now)}</time>
            )}
          </div>
        )}
      </div>
      {view.output && (
        <pre
          ref={log}
          className="acpmux-worktree-setup__output selectable"
          onScroll={(event) => {
            const element = event.currentTarget;
            pinned.current = element.scrollHeight - element.scrollTop - element.clientHeight < 8;
          }}
        >
          {view.output}
        </pre>
      )}
    </div>
  );
}

/** The summary's trailing facts: the duration, the exit code of a failed script, the port. */
export function setupFacts(run: WorktreeSetupRun, now: number, t: Translate): string[] {
  const facts: string[] = [];
  const duration = setupDuration(run.startedMs, run.finishedMs, now);
  if (duration) facts.push(duration);
  if (run.state === "failed" && run.exitCode !== undefined)
    facts.push(t("worktreeSetup.exitCode", { code: run.exitCode }));
  if (run.port !== undefined) facts.push(t("worktreeSetup.port", { port: run.port }));
  return facts;
}

/** The line above the composer: Creating worktree… while the host makes it, then the setup's
 *  state in the same row (no swap of rows, so the composer does not move), its facts, Output
 *  and, once the setup is over, Dismiss. */
export function WorktreeSetupLine({
  creating = false,
  cloning,
  view,
  onDismiss,
  onRun,
  runPending = false,
  defaultOpen = false,
}: {
  creating?: boolean;
  /// The GitHub repository (`owner/name`) whose checkout comes first: the line says it gets it ready.
  cloning?: string;
  view?: SetupView | undefined;
  onDismiss?: () => void;
  /// Run Setup (`approve`: the fingerprint of the recipe the person read) or Retry (no `approve`).
  onRun?: (approve?: string) => void;
  /// A Run Setup or Retry the host has not answered yet: its button waits.
  runPending?: boolean;
  defaultOpen?: boolean;
}) {
  const t = useT();
  const state = view?.run.state;
  const live = creating || !state || !isFinalSetupState(state);
  const now = usePageNow(live);
  const failed = state !== undefined && setupStatus(state) === "error";
  const action = onRun ? setupAction(view) : undefined;
  const review = action?.kind === "approve" ? view?.recipe : undefined;
  const [open, setOpen] = useState(defaultOpen || failed || Boolean(review));
  // A failure, or a recipe waiting to be read, opens the details once by itself (the Cloud start's
  // rule); the person may close them.
  const [openedForFailure, setOpenedForFailure] = useState(failed || Boolean(review));
  if ((failed || review) && !openedForFailure) {
    setOpenedForFailure(true);
    setOpen(true);
  }
  if (creating || !view) {
    return (
      <output className="acpmux-switch-notice acpmux-worktree-setup acpmux-worktree-creating" data-state="creating">
        <span className="acpmux-worktree-setup__summary">
          <SetupMark status="running" />
          <span className="acpmux-worktree-setup__label">
            {cloning ? t("worktree.preparingRepo", { repo: cloning }) : t("worktree.creating")}
          </span>
        </span>
      </output>
    );
  }
  const { run } = view;
  // Before the first read the start's state is all the line knows: count on a script.
  const hasScript = Boolean(run.setup?.trim()) || !view.read;
  const facts = setupFacts(run, now, t);
  const detailsShown = open;
  return (
    <output className="acpmux-switch-notice acpmux-worktree-setup" data-state={run.state} aria-live="polite">
      <span className="acpmux-worktree-setup__summary">
        <SetupMark status={setupStatus(run.state)} />
        <span className="acpmux-worktree-setup__label" role={failed ? "alert" : undefined}>
          {setupLabel(run, t, hasScript)}
        </span>
        {facts.map((fact) => (
          <span key={fact} className="acpmux-worktree-setup__fact">
            {fact}
          </span>
        ))}
        <button
          type="button"
          className="acpmux-folder-choice-button acpmux-worktree-setup__toggle"
          aria-expanded={detailsShown}
          onClick={() => setOpen((value) => !value)}
        >
          {t("worktreeSetup.output")}
          {detailsShown ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
        </button>
        {action && onRun && (
          <button
            type="button"
            className="acpmux-folder-choice-button"
            disabled={runPending}
            onClick={() => onRun(action.kind === "approve" ? action.fingerprint : undefined)}
          >
            {t(action.kind === "approve" ? "worktreeSetup.runSetup" : "worktreeSetup.retry")}
          </button>
        )}
        {!live && onDismiss && (
          <button type="button" className="acpmux-folder-choice-button" onClick={onDismiss}>
            {t("worktree.dismiss")}
          </button>
        )}
      </span>
      <span className="acpmux-worktree-setup__drawer" data-open={detailsShown ? "true" : "false"} inert={!detailsShown}>
        <span className="acpmux-worktree-setup__clip">
          {review ? <SetupReview recipe={review} /> : <SetupDetails view={view} now={now} hasScript={hasScript} />}
        </span>
      </span>
    </output>
  );
}

/** The line for the chat in `folder`, following its setup; forgets a finished one when it goes. */
export function WorktreeSetupNotice({
  callNative,
  folder,
  creating,
  cloning,
}: {
  callNative: Native;
  folder: string | undefined;
  creating: boolean;
  cloning?: string;
}) {
  const start = useWorktreeSetupStart(folder);
  const root = start ? folder : undefined;
  const [generation, setGeneration] = useState(0);
  const [runPending, setRunPending] = useState(false);
  const view = useWorktreeSetup(callNative, root, start, generation);
  // Run Setup and Retry: the host runs the worktree's setup again (or for the first time, with the
  // person's yes to the recipe they read); the line then follows it from the start. A refusal (the
  // recipe changed, a setup already running) shows what the next read says.
  const run = (approve?: string) => {
    if (!root || runPending) return;
    setRunPending(true);
    callNative("git.worktree.setup.run", {
      path: root,
      idempotency_key: crypto.randomUUID(),
      ...(approve ? { approve } : {}),
    })
      .catch(() => undefined)
      .finally(() => {
        setRunPending(false);
        setGeneration((value) => value + 1);
      });
  };
  const final = view ? isFinalSetupState(view.run.state) : false;
  const finalRef = useRef(final);
  finalRef.current = final;
  useEffect(
    () => () => {
      // A chat left after its setup ended does not show the line again.
      if (root && finalRef.current) forgetWorktreeSetup(root);
    },
    [root],
  );
  return (
    <WorktreeSetupLine
      creating={creating && !view}
      {...(cloning && creating ? { cloning } : {})}
      view={view}
      {...(root ? { onDismiss: () => forgetWorktreeSetup(root), onRun: run } : {})}
      runPending={runPending}
    />
  );
}
