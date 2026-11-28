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
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { usePageNow } from "../../ui/pageClock";
import { isFinalSetupState, type ResolvedWorktreeRecipe } from "../../worktreeRecipe";
import { AlertCircle, Check, ChevronDown, ChevronRight, Spinner } from "./conversation/icons";
import { useT } from "./i18n";
import {
  setupAction,
  setupDuration,
  setupFacts,
  setupLabel,
  setupStatus,
  useWorktreeSetup,
  useWorktreeSetupStart,
  type Native,
  type SetupView,
  type Status,
} from "./worktreeSetupModel";
import { forgetWorktreeSetup } from "./worktreeSetupStore";
import "./cloudStart.css";
import "./worktreeSetup.css";

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
