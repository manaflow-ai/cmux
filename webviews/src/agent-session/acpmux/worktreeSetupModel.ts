import { useEffect, useState, useSyncExternalStore } from "react";
import { visibleInterval } from "../../ui/pageClock";
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
import type { Translate } from "./i18n";
import {
  startedWorktreeSetup,
  subscribeWorktreeSetups,
  worktreeSetupsVersion,
  type WorktreeSetupStart,
} from "./worktreeSetupStore";

export type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

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

export type Status = "done" | "running" | "error" | "waiting";

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
  // Under a second reads "0s", never "<1s", like the turn's Working for (#60596).
  if (ms < 1000) return "0s";
  if (ms < 60_000) return `${Math.round(ms / 100) / 10}s`;
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
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
