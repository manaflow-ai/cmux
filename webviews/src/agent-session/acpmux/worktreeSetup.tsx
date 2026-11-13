// A new worktree chat's setup (design/worktree-setup.md): when New Worktree makes a worktree whose
// project has a recipe, the session host copies the include files and runs the setup script after
// its reply (`git.worktree.create` answers `setup`). The chat opens at once; one line above the
// composer follows the setup (`git.worktree.setup`, read again with `since` = the last
// `output_end`) until its state is final, then stops reading. Its Output disclosure opens the
// Cloud start's checklist rows (Copy files, Run setup script) and the output, moving the composer
// with it; a failure opens it once by itself.
import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { usePageNow, visibleInterval } from "../../ui/pageClock";
import {
  SETUP_READ_DEADLINE_MS,
  SETUP_READ_INTERVAL_MS,
  appendSetupOutput,
  isFinalSetupState,
  readSetupReply,
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

/** A setup as the line draws it; `read` is false until the first `git.worktree.setup` answer. */
export type SetupView = { run: WorktreeSetupRun; output: string; read: boolean };

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
  const deadline = Date.now() + SETUP_READ_DEADLINE_MS;
  // Reads that end before a final state end the line too, as interrupted, so it never spins on
  // with nothing following it and always offers Dismiss.
  const giveUp = () => {
    if (final || stopped) return;
    final = true;
    const run = last ?? { state: "interrupted", output: "", outputStart: "0", outputEnd: "0" };
    onView({ run: { ...run, state: "interrupted" }, output, read: true });
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
        final = isFinalSetupState(answer.run.state);
        onView({ run: answer.run, output, read: true });
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
 *  first read answers. */
export function useWorktreeSetup(
  callNative: Native,
  root: string | undefined,
  start?: WorktreeSetupStart,
): SetupView | undefined {
  const [view, setView] = useState<SetupView | undefined>(undefined);
  useEffect(() => {
    setView(undefined);
    if (!root) return;
    return followWorktreeSetup(callNative, root, setView);
  }, [callNative, root]);
  if (view) return view;
  if (!start) return undefined;
  const run: WorktreeSetupRun = { state: start.state, output: "", outputStart: "0", outputEnd: "0" };
  if (start.port !== undefined) run.port = start.port;
  return { run, output: "", read: false };
}

type Status = "done" | "running" | "error";

export function setupStatus(state: WorktreeSetupState): Status {
  return state === "succeeded" ? "done" : state === "copying" || state === "running" ? "running" : "error";
}

/** The line's words for a state. A setup with no script that succeeded only copied files. */
export function setupLabel(run: WorktreeSetupRun, t: Translate, hasScript = true): string {
  switch (run.state) {
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
      ) : (
        <AlertCircle size={14} />
      )}
      <span className="visually-hidden">
        {t(
          status === "done"
            ? "cloudStartup.state.done"
            : status === "running"
              ? "cloudStartup.state.running"
              : "cloudStartup.state.error",
        )}
      </span>
    </span>
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
  view,
  onDismiss,
  defaultOpen = false,
}: {
  creating?: boolean;
  view?: SetupView | undefined;
  onDismiss?: () => void;
  defaultOpen?: boolean;
}) {
  const t = useT();
  const state = view?.run.state;
  const live = creating || !state || !isFinalSetupState(state);
  const now = usePageNow(live);
  const failed = state !== undefined && setupStatus(state) === "error";
  const [open, setOpen] = useState(defaultOpen || failed);
  // A failure opens the output once by itself (the Cloud start's rule); the person may close it.
  const [openedForFailure, setOpenedForFailure] = useState(failed);
  if (failed && !openedForFailure) {
    setOpenedForFailure(true);
    setOpen(true);
  }
  if (creating || !view) {
    return (
      <output className="acpmux-switch-notice acpmux-worktree-setup acpmux-worktree-creating" data-state="creating">
        <span className="acpmux-worktree-setup__summary">
          <SetupMark status="running" />
          <span className="acpmux-worktree-setup__label">{t("worktree.creating")}</span>
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
        {!live && onDismiss && (
          <button type="button" className="acpmux-folder-choice-button" onClick={onDismiss}>
            {t("worktree.dismiss")}
          </button>
        )}
      </span>
      <span className="acpmux-worktree-setup__drawer" data-open={detailsShown ? "true" : "false"} inert={!detailsShown}>
        <span className="acpmux-worktree-setup__clip">
          <SetupDetails view={view} now={now} hasScript={hasScript} />
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
}: {
  callNative: Native;
  folder: string | undefined;
  creating: boolean;
}) {
  const start = useWorktreeSetupStart(folder);
  const root = start ? folder : undefined;
  const view = useWorktreeSetup(callNative, root, start);
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
      view={view}
      {...(root ? { onDismiss: () => forgetWorktreeSetup(root) } : {})}
    />
  );
}
