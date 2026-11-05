// A turn in the transcript: the prompt, a "Worked for 15s" disclosure that holds
// the commentary and tool calls, the final answer, the turn's edited files, then a footer.
// A pure pass over the client's rows (direct.ts keeps them in event order), so the
// virtualized transcript still lays out one row per entry. After the reference prototype's
// derive.ts (`deriveTurn`, `formatDuration`).
//
// Stop-gap seam: acpmux owns the turn structure (spec acp-ui.md, OWNERSHIP-PRINCIPLES.md). When
// acpmux serves turn-structured rows (`acp.view.subscribe`, `_acpmux/view`), `turnView` becomes
// a field-for-field mapping of them and nothing else in the pane changes.
import {
  pathKey,
  TURN_RETRY,
  type AcpmuxActivity,
  type AcpmuxFileDiff,
  type AcpmuxPlanEntry,
  type AcpmuxRow,
} from "../model";
import type { Folds } from "./viewFolds";
import { continuesTurn, opensTurn } from "../turnStart";
import { findRowIndex } from "./chatFind";
import { renderCall } from "./renderCall";
import { showsTimestamp, type TurnTimes } from "./timestamps";
import { isRunGroup, isSubagentGroup, WORKFLOW_CARD } from "../subagents/subagentRows";
import { STARTED_SESSIONS } from "../started/startedSessions";
import { QUESTION_RECORD } from "../question/record";
import { chosenAnswer, nextStepAsk, pickedAnswer } from "./nextStepAsk";
import { lastWrapUp, withoutWrapUp } from "./wrapUp";
import type { Translate } from "../i18n";
import { editedPaths, isBareShellName, toolLabel } from "../toolPaths";
import { shortCommand } from "./shortCommand";
import { awaitsPermission, groupId, isDraftCall, isFailed as callFailed, isRunning, toolGroups } from "./toolGroups";
import { acpmuxMcpSends } from "./acpmuxMcpSends";
import { acpmuxSendCalls } from "./acpmuxSends";
import { subsessionCall } from "./subsessionCalls";
import { agentCall } from "./agentCalls";
import { experimentArm } from "../../../experiments/experiment";
import { finishedTaskLook } from "./taskLine.experiment";
import { startedTasks, startsTask, TASK_LINE } from "./taskLines";
import { isWaitingMessage } from "./pendingMessages";
import { appendLaneNotice } from "./laneNoticeBatches";
import { agentMessage } from "./agentMessages";
import { turnCopyParts } from "./turnCopy";
import { isVisiblyEmptyMessage, isVisiblyEmptyText } from "./visibleMessage";
import { isThought, thoughtDuration } from "./thoughts";
import {
  BACKGROUND_TURN,
  backgroundTurnRowId,
  collectFoldedBackgroundId,
  foldBackgroundTurns,
  foldsBackground,
  openBackgroundTurns,
} from "./backgroundTurns";
import { foldMessageRuns, messageRunFoldFor, messageRunRevealKey, openMessageRuns } from "./messageRuns";
import { backgroundRunFoldFor, foldBackgroundRuns, openBackgroundRuns } from "./backgroundRuns";
import { turnFoldStyle, type TurnFoldStyle } from "./turnFoldStyle";

/// A row added by this pass: the "Worked for" disclosure of the turn opened by `turnId`.
export const WORKED = "worked";
/// A row added by this pass: the timestamp line over a turn (timestamps.ts).
export const DATE = "date";
/// Rows added for the turn still running: "Thinking" until it has output, then a ticking
/// "Working for 42s" line over its work, where "Worked for" lands when the turn ends.
export const THINKING = "thinking";
/// The last turn's Thinking line has one id from send to the first output: the sent prompt's row
/// changes id when acpmux echoes it, the line keeps its place (cx-ncc.58).
const LIVE_THINKING = `${THINKING}-live`;
export const WORKING = "working";
/// The running turn's activity line under its todo list (Debug Settings `agent.sessionStatus`,
/// cx-ncc.102): what the agent is doing now and how long the turn has run.
export const ACTIVITY_LINE = "activityLine";
/// A row added for each render call of an ended turn (renderCall.ts), above its answer: the
/// render card, with the call as its one item.
export const RENDER = "render";
/// A row added for an ended turn whose answer ends on one tagged ask (nextStepAsk.ts): the ask as a
/// card with its answers as buttons (NextStepCard.tsx), right under the answer, which drops the
/// ask's lines. Its `nextStep` carries the ask; `settleNextSteps` adds the answer a later prompt
/// picked, or folds it once a later card takes over.
export const NEXT_STEP = "nextStep";
/// The id prefix of the footer `supersededFooters` adds where the person came in on a stretch of a
/// turn: before a steer that landed in it, or at the end of a turn a new prompt opened over.
export const SUPERSEDED = "superseded";
/// Activity rows shown inside an open disclosure are copies under this suffix, so the
/// edited-files card after the answer keeps the original id.
const FOLDED = ":fold";

/// "1m 16s", "42s", "1h 3m"; zero units dropped, under one second is "0s".
export function formatDuration(ms: number): string {
  const total = Math.floor(ms / 1000);
  if (total <= 0) return "0s";
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return [h && `${h}h`, m && `${m}m`, s && `${s}s`].filter(Boolean).join(" ");
}

export const toolCalls = (t: Translate, count = 0) => t("turn.toolCalls", { n: count });

/// The disclosure's label: "Worked for 1m 16s", "You stopped after 40s",
/// or "34 previous messages" for a Codex fold that mixes the agent's messages with its work
/// (`foldMixesMessages`). It shows no tool-call count.
export function workedLabel(t: Translate, row: AcpmuxRow): string {
  if (row.previous !== undefined)
    return row.previous === 1 ? t("turn.previous.one") : t("turn.previous.other", { n: row.previous });
  if (row.durationMs === undefined) return toolCalls(t, row.toolCount);
  const time = formatDuration(row.durationMs);
  return row.status === "cancelled" ? t("turn.stopped", { time }) : t("turn.worked", { time });
}

/// A turn summary for a turn that was stopped (Stop, Esc, or an interruption) and did not go on
/// under a prompt sent now (`continued`).
/// A turn that ended on an error (its card, TurnRows.tsx TurnFailure).
export const isFailed = (row: AcpmuxRow) =>
  row.kind === "turnSummary" && (row.status === "failed" || row.status === "error");

export const isStopped = (row: AcpmuxRow) =>
  row.kind === "turnSummary" && (row.status === "cancelled" || row.status === "interrupted") && !row.continued;

/// What a turn's footer says before its buttons, or nothing: a turn whose work folds under "Worked
/// for" says it there, and a turn under a second says nothing, since "Worked for 0s" is no news
/// (Leo, 2026-10-21: "IF WE 0 SECONDS THEN IT DOESNT NEED TO TAKE UP SPACE"). A stopped turn still
/// says it stopped, and a footer without timing (history paged in mid-turn) its count.
export function footerLabel(t: Translate, row: AcpmuxRow): string | undefined {
  return footerSays(row) ? workedLabel(t, row) : undefined;
}
const footerSays = (row: AcpmuxRow) =>
  !row.folded &&
  // A stretch the person came in on (`supersededFooters`) has no time of its own to say.
  !row.superseded &&
  (row.previous !== undefined || row.durationMs === undefined || row.durationMs >= 1000 || row.status === "cancelled");

/// A footer with nothing to show at rest and only hover controls (Pin, Fork, its time): no answer to
/// copy or read aloud, the turn did not fail, and it offers no Continue (a stopped last turn whose
/// work folds draws its line for Continue alone). Its "Worked for" label is the time's tooltip now,
/// never a word in the row (TurnRows.tsx TurnFooter), so it no longer keeps the line. It takes no line in the transcript
/// (conversation.css `.cv-turn-actions--empty`, model.ts fallbackRowHeight); pointed at, its controls
/// show over the turn gap below, so nothing moves.
///
/// The chat's last turn (`retryable`: no prompt after it) that spoke and then ended on work, with no
/// reply after its last call, is not empty: it ends the chat, so its row with Copy (the whole turn,
/// turnCopy.ts) shows once it ends, as ChatGPT's does under every finished turn (Leo, 2026-11-02:
/// "the latest copy buttons auto showing when the turn is done like chatgpt"). Before, that footer
/// drew nothing, so the chat ended on a blank band with no buttons. A footer that is empty never
/// carries Retry: the prompt keeps it (`retryPlacement`).
export const isEmptyFooter = (row: AcpmuxRow) =>
  row.kind === "turnSummary" &&
  row.status !== "failed" &&
  row.status !== "error" &&
  !row.text &&
  !row.resumable &&
  !endsChatOnWork(row);

/// The footer with the person's last prompt to send again (TurnRows.tsx TurnFooter's Retry): the
/// chat's last turn, or the last one a prompt opened when every turn after it came from a notice
/// or a reminder (`retryTarget`). transcriptGrid.ts rowMark and model.ts isBlankFooter repeat it inline.
export const offersRetry = (row: AcpmuxRow) =>
  row.retryTarget === true && Boolean(row.prompt) && Boolean(row.retryRowId);

/// A prompt row that drew its own Retry on base, before Retry moved to the reply footer (cmux#34779),
/// taken over unchanged: the row UserBubble draws (the person's own prompt: no `incoming`, not a
/// `received` result; App.tsx's registry draws those as message cards), with its footer (not
/// `failed`), not `pending` and not still sending, with text to send (`resend`, else `text`). Whether
/// the chat can send and the reader may act are ``retryPlacement``'s (base: PromptRetry's `retry` and
/// read-only checks). Only which row draws Retry moved; which prompts can be retried did not.
export const isRetryablePrompt = (row: AcpmuxRow) =>
  row.kind === "user" &&
  !row.incoming &&
  row.received === undefined &&
  !row.failed &&
  !row.pending &&
  row.delivery?.state !== "sending" &&
  Boolean(row.resend ?? row.text);

/// The chat's one Retry in the transcript (cmux#34779): the last prompt that would have drawn its
/// own Retry on base (``isRetryablePrompt``, `promptId`), and its turn's footer when that footer
/// draws Retry for it (`footerId`). Read by ``retryPlacement``. A steer's turn footer resends the
/// turn's opener, not the steer, so a steer keeps Retry under its bubble (held while it waits, as
/// on base).
export type RetryTarget = { promptId?: string; footerId?: string };
export const NO_RETRY_TARGET: RetryTarget = {};

export function retryTargetIn(rows: readonly AcpmuxRow[]): RetryTarget {
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (!isRetryablePrompt(row)) continue;
    // Its turn's footer is the first summary after it. A turn with none (history that ended
    // without a turn result, or one still running) reaches the next turn's summary, which resends
    // another prompt: then the prompt keeps Retry.
    for (let next = at + 1; next < rows.length; next += 1) {
      const footer = rows[next]!;
      if (footer.kind !== "turnSummary") continue;
      return offersRetry(footer) && footer.retryRowId === row.id && !isEmptyFooter(footer)
        ? { promptId: row.id, footerId: footer.id }
        : { promptId: row.id };
    }
    return { promptId: row.id };
  }
  return NO_RETRY_TARGET;
}

/// Where the transcript draws its one Retry: on the reply footer when that footer shows and offers
/// it (the person's last prompt's turn ended with a footer that has something at rest, or failed),
/// else under the prompt, as the prompt's Retry was drawn before Retry moved to the footer, so
/// Retry never vanishes where it was (a turn of tool calls alone, whose empty footer draws nothing;
/// history with no turn result; a turn still running). Nowhere when the reader may not act (read
/// only) or the chat cannot send now (no `retry`, as while disconnected). The Messages view, which
/// draws no footer for a turn that ended well, keeps Retry under its prompts.
export type RetryPlace = "footer" | "prompt" | "none";
export function retryPlacement(
  target: RetryTarget,
  ctx: { canRetry: boolean; readOnly: boolean; messages: boolean },
): RetryPlace {
  if (!target.promptId || !ctx.canRetry || ctx.readOnly) return "none";
  if (ctx.messages || !target.footerId) return "prompt";
  return "footer";
}

/// The turn whose footer may offer Retry: the last one a prompt opened that would have drawn its own
/// Retry on base (``isRetryablePrompt``), whatever came after it (a notice's, a reminder's, another
/// agent's or a task result's turn), as that prompt kept its Retry under it before Retry moved to
/// the footer (cmux#34779). -1: none.
function retryTargetAt(rows: readonly AcpmuxRow[], starts: readonly number[]): number {
  for (let at = starts.length - 1; at >= 0; at -= 1) if (isRetryablePrompt(rows[starts[at]!]!)) return at;
  return -1;
}

/// The last turn's footer when the turn said something and ended on work (`isEmptyFooter` above).
/// transcriptGrid.ts rowMark repeats it inline (that module imports nothing).
export const endsChatOnWork = (row: AcpmuxRow) => row.retryable === true && (row.turnCopy?.length ?? 0) > 0;

const isEditTool = (tool: { kind?: string } | undefined) => tool?.kind === "edit" || tool?.kind === "fileChange";
const isEdit = (row: AcpmuxRow) => row.kind === "activity" && (row.items ?? []).some((item) => isEditTool(item.tool));

/// A completed whole-file tool diff proves a file changed only when both before and after text are
/// known. A path-only or unknown-old write can be a no-op (even when its replacement text is
/// non-empty), so it stays neutral for the reply Retry hint. Comparing the first before and final
/// after also keeps an edit that is reverted within one turn neutral (A -> B -> A). Fragment edits
/// are deliberately excluded because their net file contents are not available here.
const turnChangedFiles = (rows: readonly AcpmuxRow[]) => {
  const byPath = new Map<string, { diffs: AcpmuxFileDiff[]; uncertain: boolean }>();
  const keysByBasename = new Map<string, Set<string>>();
  for (const row of rows) {
    if (row.kind !== "activity") continue;
    for (const item of row.items ?? []) {
      const tool = item.tool;
      if (tool?.status !== "completed" || !isEditTool(tool)) continue;
      for (const diff of tool.diffs ?? []) {
        const key = pathKey(diff);
        const entry = byPath.get(key) ?? { diffs: [], uncertain: false };
        // An unknown-old or fragment write can hide a no-op or a later revert. Keep the path
        // marked uncertain instead of filtering that event out and claiming a net change from
        // the remaining diffs.
        if (diff.fragment === true || diff.oldText === undefined) entry.uncertain = true;
        else entry.diffs.push(diff);
        byPath.set(key, entry);
        const basename = diff.path.slice(diff.path.lastIndexOf("/") + 1);
        const keys = keysByBasename.get(basename) ?? new Set<string>();
        keys.add(key);
        keysByBasename.set(basename, keys);
      }
    }
  }
  // A path can gain its canonical spelling after an earlier event (`file.ts` then
  // `/repo/file.ts` with canonical `/repo/file.ts`). If a basename has multiple path keys, keep
  // all of those histories neutral: the net chain cannot be proven without a path resolver.
  for (const keys of keysByBasename.values()) {
    if (keys.size < 2) continue;
    for (const key of keys) {
      const entry = byPath.get(key);
      if (entry) entry.uncertain = true;
    }
  }
  return [...byPath.values()].some(({ diffs, uncertain }) => {
    if (uncertain) return false;
    const first = diffs[0];
    const last = diffs[diffs.length - 1];
    if (!first || !last || first.oldText === undefined) return false;
    // A missing chain link means the file's net contents are not proven by this snapshot.
    for (let index = 1; index < diffs.length; index++)
      if (diffs[index]!.oldText !== diffs[index - 1]!.newText) return false;
    return first.oldText !== last.newText;
  });
};

/// The rows to draw. `expanded` holds the ids of open disclosures; `working` says the last
/// turn is still running (the snapshot's `isWorking`); `now` dates the turns (timestamps.ts);
/// `clockOffset` (the snapshot's `clockOffsetMs`) moves the running turn's start onto this
/// computer's clock, so its "Working for" counts from the prompt. `sessionStatus` (the Debug
/// toggle `agent.sessionStatus`) puts a running turn's todo list under its work, with the
/// activity line under it.
export function turnView(
  rows: readonly AcpmuxRow[],
  expanded: Folds,
  options: {
    now?: number;
    working?: boolean;
    clockOffset?: number;
    liveRuns?: boolean;
    sessionStatus?: boolean;
    lineBelow?: boolean;
    /** The session's harness family, which picks how a finished turn folds (turnFoldStyle.ts). */
    agentFamily?: string;
    /** The running turn's foreground subagents the running tray took out of `rows`. */
    trayAgents?: number;
  } = {},
): AcpmuxRow[] {
  return turnViewFrom(rows, expanded, options).rows;
}

/// A turn view (``turnViewFrom``) with what it was drawn from, for the next snapshot to build on.
export type TurnView = {
  source: readonly AcpmuxRow[];
  expanded: Folds;
  clockOffset: number;
  liveRuns: boolean;
  lineBelow: boolean;
  agentFamily?: string;
  working: boolean;
  sessionStatus: boolean;
  messageBreaks: readonly number[];
  trayAgents?: number;
  /// Unchanged display prefix, excluding its last row whose fold boundary can change.
  reusedRows?: number;
  /// The steers that wait (snapshot `waitingSteers`): a new list draws the running turn again.
  waitingSteers?: readonly string[];
  /// Other sessions' messages in the last turn the agent has not read yet, which it does not draw:
  /// they are in the group of waiting messages (pendingMessages.ts).
  pending: readonly AcpmuxRow[];
  /// Where the first prompt is: the rows before it draw as they are.
  lead: number;
  /// The turn whose footer offers Retry (`retryTargetAt`), -1 for none.
  retryAt: number;
  /// Each turn's prompt index in `source`, its times, whether it is dated, and how many drawn
  /// rows there are up to its end.
  starts: number[];
  times: TurnTimes[];
  dated: boolean[];
  firstVisible?: number;
  /// Background owners whose closed lines hide rows across prompt boundaries.
  foldedBackground: ReadonlySet<string>;
  /// Each boundary keeps its count and last row before the next prompt extends a fold.
  ends: { count: number; row: AcpmuxRow | undefined; visible?: number }[];
  /// Where each next-step card is in `rows`, with the row as its turn shaped it
  /// (`settleNextSteps`).
  nextSteps: NextStepAt[];
  rows: AcpmuxRow[];
};

/// ``turnView``, building on `previous`: the turns before the one holding the first row that
/// differs from `previous.source` (by object) keep their drawn rows, so a long chat's snapshot
/// shapes only its last turns.
const NO_MESSAGE_BREAKS: readonly number[] = [];
const NO_PENDING: readonly AcpmuxRow[] = [];

const sameIds = (a: ReadonlySet<string>, b: ReadonlySet<string>) =>
  a.size === b.size && [...a].every((id) => b.has(id));

const firstDateUnchanged = (view: TurnView, now: number) =>
  view.firstVisible === undefined ||
  showsTimestamp(view.times[view.firstVisible]!, undefined, now, view.lead === 0) === view.dated[view.firstVisible];

export function turnViewFrom(
  rows: readonly AcpmuxRow[],
  expanded: Folds,
  {
    now = Date.now(),
    working = false,
    clockOffset = 0,
    liveRuns = false,
    sessionStatus = false,
    lineBelow = false,
    agentFamily,
    waitingSteers,
    messageBreaks = NO_MESSAGE_BREAKS,
    trayAgents = 0,
  }: {
    now?: number;
    working?: boolean;
    clockOffset?: number;
    liveRuns?: boolean;
    sessionStatus?: boolean;
    lineBelow?: boolean;
    agentFamily?: string;
    /// The steers the agent has not read yet (snapshot `waitingSteers`), one array while they hold.
    waitingSteers?: readonly string[];
    /// Sorted insertion times of synthetic rows that must separate received message runs.
    messageBreaks?: readonly number[];
    /// The running turn's foreground subagents still running, counted by the caller when the
    /// running tray took their groups out of `rows` (runningTray.ts `withSubagentLines`), so the
    /// live line still reads "Waiting on 2 subagents" (``trayWaitAgents``).
    trayAgents?: number;
  } = {},
  previous?: TurnView,
): TurnView {
  if (
    previous &&
    previous.source === rows &&
    previous.expanded === expanded &&
    previous.clockOffset === clockOffset &&
    previous.liveRuns === liveRuns &&
    previous.lineBelow === lineBelow &&
    previous.agentFamily === agentFamily &&
    previous.messageBreaks === messageBreaks &&
    previous.working === working &&
    previous.sessionStatus === sessionStatus &&
    previous.waitingSteers === waitingSteers &&
    previous.trayAgents === trayAgents &&
    firstDateUnchanged(previous, now)
  )
    return previous;
  // The turn to shape from: the one holding the first changed row. The turn before it may
  // have ended there, and the last turn draws differently once another follows it.
  const reuseFoldedBackground = previous?.source === rows && previous.expanded === expanded;
  const foldedBackground = reuseFoldedBackground ? previous!.foldedBackground : new Set<string>();
  let reuse = 0;
  if (
    previous &&
    previous.expanded === expanded &&
    previous.clockOffset === clockOffset &&
    previous.liveRuns === liveRuns &&
    previous.lineBelow === lineBelow &&
    previous.agentFamily === agentFamily &&
    previous.messageBreaks === messageBreaks &&
    previous.starts.length
  ) {
    const shared = previous.source;
    if (rows === shared) reuse = previous.starts.length;
    else {
      let from = 0;
      while (from < rows.length && from < shared.length && rows[from] === shared[from]) {
        if (!reuseFoldedBackground) collectFoldedBackgroundId(foldedBackground as Set<string>, rows[from]!, expanded);
        from += 1;
      }
      while (reuse < previous.starts.length && previous.starts[reuse]! < from) reuse += 1;
    }
    reuse = Math.max(0, reuse - 1);
  }
  // The first visible turn's line depends on `now`.
  if (reuse > 0 && !firstDateUnchanged(previous!, now)) reuse = 0;
  let reusedRows = 0;
  let index: number;
  let lead: number;
  let out: AcpmuxRow[];
  let starts: number[];
  let times: TurnTimes[];
  let dated: boolean[];
  let ends: TurnView["ends"];
  let nextSteps: NextStepAt[];
  if (reuse > 0) {
    lead = previous!.lead;
    index = previous!.starts[reuse]!;
    const boundary = previous!.ends[reuse - 1];
    reusedRows = Math.max(0, (boundary?.count ?? 0) - 1);
    out = previous!.rows.slice(0, boundary?.count);
    if (boundary?.row && out.length) out[out.length - 1] = boundary.row;
    starts = previous!.starts.slice(0, reuse);
    times = previous!.times.slice(0, reuse);
    dated = previous!.dated.slice(0, reuse);
    ends = previous!.ends.slice(0, reuse);
    nextSteps = previous!.nextSteps.filter((card) => card.at < out.length);
  } else {
    out = [];
    index = 0;
    // Rows before the first prompt (a greeting, or history paged in mid-turn) draw as they are,
    // a quiet turn the agent ran on its own folded to its line (backgroundTurns.ts).
    while (index < rows.length && rows[index]!.kind !== "user") {
      const row = rows[index++]!;
      if (!reuseFoldedBackground) collectFoldedBackgroundId(foldedBackground as Set<string>, row, expanded);
      if (!isVisiblyEmptyMessage(row)) out.push(row);
    }
    out = foldBackgroundRuns(foldBackgroundTurns(out, expanded), expanded);
    lead = index;
    starts = [];
    times = [];
    dated = [];
    ends = [];
    nextSteps = [];
  }
  const first = starts.length;
  // The cards before the last reused one keep their state: what follows each, up to the next card,
  // is reused too.
  const keptCards = nextSteps.length;
  let firstVisible =
    previous?.firstVisible !== undefined && previous.firstVisible < first ? previous.firstVisible : undefined;
  let visible = ends.at(-1)?.visible;
  const fromStart = lead === 0;
  const pending: AcpmuxRow[] = [];
  // Each turn is its prompt's index up to the next accepted prompt: its rows, and any prompt not
  // yet accepted (sent while this turn runs, or refused), which sorts among them by its send time
  // and neither ends the turn nor folds into it. A steer goes on with the turn it went into
  // (``continuesTurn``). Indexes, not arrays: a long chat's snapshot only copies the rows of a
  // turn that changed (shapedTurn).
  while (index < rows.length) {
    const start = index++;
    if (!reuseFoldedBackground) collectFoldedBackgroundId(foldedBackground as Set<string>, rows[start]!, expanded);
    let answerAt: number | undefined;
    while (
      index < rows.length &&
      (rows[index]!.kind !== "user" || isUnsent(rows[index]!) || continuesTurn(rows[index]!))
    ) {
      if (!reuseFoldedBackground) collectFoldedBackgroundId(foldedBackground as Set<string>, rows[index]!, expanded);
      if (isAnswer(rows[index]!)) answerAt = rows[index]!.at;
      index += 1;
    }
    starts.push(start);
    const turn = { promptAt: rows[start]!.at, answerAt };
    times.push(turn);
  }
  const retryAt = retryTargetAt(rows, starts);
  // Reused turns were drawn with the previous view's folds. A row after them can change which
  // background turns fold (cmux#30535), so a different set draws every turn again. So does a Retry
  // that moves off or onto a reused turn (`retryTargetAt`).
  const retryMoved =
    reuse > 0 && retryAt !== previous!.retryAt && [retryAt, previous!.retryAt].some((at) => at >= 0 && at < first);
  if (reuse > 0 && (!sameIds(foldedBackground, previous!.foldedBackground) || retryMoved))
    return turnViewFrom(rows, expanded, {
      now,
      working,
      clockOffset,
      liveRuns,
      sessionStatus,
      lineBelow,
      agentFamily,
      waitingSteers,
      messageBreaks,
      trayAgents,
    });
  for (let at = first; at < starts.length; at += 1) {
    const start = starts[at]!;
    const end = at + 1 < starts.length ? starts[at + 1]! : rows.length;
    // Only the last turn can still be running.
    const last = at === starts.length - 1;
    const live = working && last;
    dated[at] = showsTimestamp(times[at]!, visible === undefined ? undefined : times[visible], now, fromStart);
    const shaped = shapedTurn(
      rows,
      start,
      end,
      expanded,
      live,
      last,
      clockOffset,
      dated[at]!,
      liveRuns,
      sessionStatus,
      lineBelow,
      agentFamily,
      foldedBackground,
      live ? trayAgents : 0,
      at === retryAt,
    );
    // Other sessions' messages the agent read stay each its own line where it read them
    // (IncomingMessageCard.tsx). One it has not read yet (a steer that waits for its step) leaves
    // the running turn for the one group of waiting messages at the end (pendingMessages.ts).
    // Reuse batches while tokens change: only a newly arrived notice computes a new descriptor.
    // The boundary is this turn; unrelated rows and report/inbox kind changes end a batch.
    const drawn: AcpmuxRow[] = [];
    for (const row of shaped) {
      // The local turn may contain a late done line whose background owner is in a prior
      // prompt. Its original background line still controls disclosure of that completion.
      if (row.inBackground !== undefined && foldedBackground.has(row.inBackground)) continue;
      if (last && isWaitingMessage(row)) pending.push(row);
      else appendLaneNotice(drawn, row);
    }
    // Invisible turns cannot consume a gap or the first visible turn's age threshold. Store
    // the preceding visible turn at each reusable boundary, avoiding a history scan per token.
    if (drawn.some((row) => row.kind !== DATE && !isVisiblyEmptyMessage(row))) {
      firstVisible ??= at;
      visible = at;
    } else dated[at] = false;
    for (const row of drawn) {
      if (row.kind === NEXT_STEP && row.nextStep) nextSteps.push({ at: out.length, row });
      out.push(row);
    }
    ends.push({ count: out.length, row: out.at(-1), visible });
  }
  // A reused card a later one now supersedes changed: the unchanged prefix ends before it.
  reusedRows = Math.min(reusedRows, settleNextSteps(out, nextSteps, Math.max(0, keptCards - 1)));
  return {
    source: rows,
    expanded,
    clockOffset,
    liveRuns,
    lineBelow,
    agentFamily,
    working,
    sessionStatus,
    messageBreaks,
    trayAgents,
    reusedRows,
    ...(waitingSteers ? { waitingSteers } : {}),
    pending: pending.length ? pending : NO_PENDING,
    lead,
    retryAt,
    starts,
    times,
    dated,
    firstVisible,
    foldedBackground,
    ends,
    nextSteps,
    rows: out,
  };
}

/// A next-step card in a turn view: its index in the drawn rows and the row as its turn shaped it.
type NextStepAt = { at: number; row: AcpmuxRow };

/// A card's version spans its shaped version and its settled state (none, answered, superseded,
/// both), so its memo and height cache redraw when it settles.
const SETTLED_STATES = 4;
/// Each shaped card's settled row, kept while its state holds, so the memo and height cache keep it.
const settledCards = new WeakMap<AcpmuxRow, { answer?: string; superseded: boolean; row: AcpmuxRow }>();

/// The person's own prompt, sent or on its way: what can answer a card. A prompt that failed to
/// send answered nothing, so its card stays answerable.
const personPrompt = (row: AcpmuxRow) =>
  row.kind === "user" && !row.incoming && !row.received && !row.failed && row.text ? row.text : undefined;

/// Each next-step card in `out` from `cards[from]` on, settled by what follows it. Another prompt
/// leaves a card answerable (Leo, 2026-11-05, on Claude desktop's box: "after i sent a prompt
/// icouldn't select the thing... we can make a better thing in cmux-next for y'all to call"): a
/// prompt after it that picks one of its answers settles it with that answer, and a later card
/// (the agent's next wrap-up or tagged ask) supersedes it, showing what the person said after it.
/// Until then its buttons still send, whatever the person typed between. Returns the first index
/// whose row it changed, `out.length` for none.
function settleNextSteps(out: AcpmuxRow[], cards: readonly NextStepAt[], from: number): number {
  let changed = out.length;
  const put = (at: number, row: AcpmuxRow) => {
    if (out[at] !== row) changed = Math.min(changed, at);
    out[at] = row;
  };
  for (let index = from; index < cards.length; index += 1) {
    const { at, row } = cards[index]!;
    const { ask } = row.nextStep!;
    const next = index + 1 < cards.length ? cards[index + 1]!.at : out.length;
    const superseded = index + 1 < cards.length;
    let answer: string | undefined;
    let first: string | undefined;
    if (ask.question)
      for (let later = at + 1; later < next && answer === undefined; later += 1) {
        const said = personPrompt(out[later]!);
        if (said === undefined) continue;
        first ??= said;
        answer = pickedAnswer(ask, said);
      }
    if (answer === undefined && superseded && first !== undefined) answer = chosenAnswer(ask, first);
    if (answer === undefined && !superseded) {
      put(at, row);
      continue;
    }
    const kept = settledCards.get(row);
    if (kept && kept.answer === answer && kept.superseded === superseded) {
      put(at, kept.row);
      continue;
    }
    const settled: AcpmuxRow = {
      ...row,
      version: row.version + (answer === undefined ? 0 : 1) + (superseded ? 2 : 0),
      nextStep: { ask, ...(answer !== undefined && { answer }), ...(superseded && { superseded }) },
    };
    settledCards.set(row, { answer, superseded, row: settled });
    put(at, settled);
  }
  return changed;
}

/// A turn as drawn, kept while its rows (by identity) and what shapes them stay the same: a long
/// chat's snapshot rebuilds only the turns that changed, and an unchanged turn's derived rows stay
/// the same objects, so the row memos and the height cache keep them.
type ShapedTurn = {
  /// The turn's rows after its prompt, held prompts included, as last shaped.
  source: readonly AcpmuxRow[];
  /// Which of its folds are open (`openFolds`).
  open: string;
  /// Which of its background turns' lines are open (backgroundTurns.ts `openBackgroundTurns`).
  background: string;
  /// Which of its message runs' lines are open (messageRuns.ts `openMessageRuns`).
  messageRuns: string;
  /// Which of its background-task runs' lines are open (backgroundRuns.ts `openBackgroundRuns`).
  backgroundRuns: string;
  last: boolean;
  /// Whether its footer offers Retry (`retryTargetAt`).
  retryTarget: boolean;
  clockOffset: number;
  dated: boolean;
  liveRuns: boolean;
  /// Whether the live line draws below (`liveSlot`): a prompt waiting for its turn shapes its line in that slot.
  lineBelow: boolean;
  agentFamily?: string;
  /// The family's fold style as read for this shape (turnFoldStyle.ts): its opt-in can change
  /// without the family changing, and the cached turn must fold anew when it does.
  foldStyle: TurnFoldStyle;
  /// The person's own prompt opened the next turn (`supersededFooters`).
  endedByPerson: boolean;
  rows: AcpmuxRow[];
};
const shapedTurns = new WeakMap<AcpmuxRow, ShapedTurn>();

/// A completed turn has one disclosure, keyed by its original prompt. Live rows do not read it,
/// so a remembered open state never changes the transcript while the next turn is running. A
/// history page can begin at a landed steer; accept that provisional key until the older prompt
/// arrives, so loading history does not erase an explicit open choice.
function openFolds(rows: readonly AcpmuxRow[], start: number, end: number, expanded: Folds): string {
  if (expanded.size === 0) return "";
  if (expanded.has(`${WORKED}-${rows[start]!.id}`)) return "1";
  for (let index = start + 1; index < end; index += 1) {
    const row = rows[index]!;
    if (row.kind === "user" && continuesTurn(row) && expanded.has(`${WORKED}-${row.id}`)) return "1";
  }
  return "";
}

/// `rows` with each agent reply of a lone "." marked `answersPerson` when `user` is the person's own
/// prompt, so it still draws (visibleMessage.ts): a reply to the person is theirs to see, however
/// short (Leo, 2026-11-03, on hiding punctuation-only replies: "well there are cases (rare) that you
/// would want to see it..."). The "." answering another agent's message stays hidden: the walk stops
/// at the turn's summary, the first background row or another agent's steered message, since what
/// follows is not an answer to the person. Only a bare reply is copied; without one, `rows` itself.
function answeringPerson(user: AcpmuxRow, rows: AcpmuxRow[]): AcpmuxRow[] {
  if (user.kind !== "user" || user.incoming || user.received || user.inBackground !== undefined) return rows;
  let out: AcpmuxRow[] | undefined;
  for (let at = 0; at < rows.length; at += 1) {
    const row = rows[at]!;
    if (row.kind === "turnSummary" || row.kind === BACKGROUND_TURN || row.kind === "backgroundTask") break;
    // Another agent's message steered into the turn: what follows answers it.
    if (row.kind === "user" && row.incoming) break;
    if (row.kind !== "assistant" || row.inBackground !== undefined || row.answersPerson) continue;
    if (!isVisiblyEmptyMessage(row) || isVisiblyEmptyMessage({ ...row, answersPerson: true })) continue;
    out ??= rows.slice();
    out[at] = { ...row, answersPerson: true };
  }
  return out ?? rows;
}

/// The drawn rows of the turn at `rows[start]` (its prompt) up to `end`, then its held prompts.
function shapedTurn(
  rows: readonly AcpmuxRow[],
  start: number,
  end: number,
  expanded: Folds,
  live: boolean,
  last: boolean,
  clockOffset: number,
  dated: boolean,
  liveRuns = false,
  sessionStatus = false,
  lineBelow = false,
  agentFamily?: string,
  foldedBackground: ReadonlySet<string> = new Set(),
  trayAgents = 0,
  retryTarget = false,
): AcpmuxRow[] {
  const user = rows[start]!;
  // A running turn changes with every event: it is neither read from nor kept in the cache, so its
  // open-fold key is never needed, and a streamed token does no work over its rows for it.
  const open = live ? "" : openFolds(rows, start, end, expanded);
  const background = openBackgroundTurns(rows, start + 1, end, expanded);
  const messageRuns = live ? "" : openMessageRuns(rows, start + 1, end, expanded);
  const backgroundRuns = live ? "" : openBackgroundRuns(rows, start + 1, end, expanded);
  const source = rows
    .slice(start + 1, end)
    .filter((row) => row.inBackground === undefined || !foldedBackground.has(row.inBackground));
  // The person's own prompt opened the turn after this one: a turn with no summary ended there
  // (`supersededFooters`). Part of the cache key, since that prompt is not in `source`.
  const opener = rows[end];
  const endedByPerson = !live && !last && opener?.kind === "user" && !opener.incoming && !opener.received;
  const foldStyle = turnFoldStyle(agentFamily);
  const cached = live ? undefined : shapedTurns.get(user);
  if (
    cached &&
    cached.open === open &&
    cached.background === background &&
    cached.messageRuns === messageRuns &&
    cached.backgroundRuns === backgroundRuns &&
    cached.last === last &&
    cached.retryTarget === retryTarget &&
    cached.clockOffset === clockOffset &&
    cached.dated === dated &&
    cached.liveRuns === liveRuns &&
    cached.lineBelow === lineBelow &&
    cached.agentFamily === agentFamily &&
    cached.foldStyle === foldStyle &&
    cached.endedByPerson === endedByPerson &&
    cached.source.length === source.length
  ) {
    let same = true;
    for (let index = 0; same && index < source.length; index += 1) same = cached.source[index] === source[index];
    if (same) return cached.rows;
  }
  // A steer draws where it went into the turn; bookkeeping sent in draws nothing
  // (incomingMessage.ts). The summary of the turn a prompt sent now stopped is not a Stop: the
  // turn goes on under that prompt, so it neither ends nor times the turn.
  // Nor does it before the steer's own record comes, while it is the turn's last summary: the turn
  // is about to go on, and would read "You stopped after" for that moment.
  const kept = source.filter(
    (row, at) =>
      (row.kind !== "user" || (continuesTurn(row) && row.incoming?.kind !== "hidden")) &&
      !(
        row.kind === "turnSummary" &&
        row.continued &&
        (source.slice(at + 1).some(continuesTurn) ||
          (last && !source.slice(at + 1).some((later) => later.kind === "turnSummary")))
      ),
  );
  // A turn the agent ran on its own after this one ended (no prompt starts it) draws in its tail:
  // a quiet one, or one still running, as its one line (backgroundTurns.ts).
  const turn = foldBackgroundTurns(answeringPerson(user, kept), expanded);
  const held = source.filter((row) => row.kind === "user" && !continuesTurn(row));
  const visibleTurn =
    !isVisiblyEmptyMessage(user) || turn.some((row) => row.kind !== "turnSummary" && !isVisiblyEmptyMessage(row));
  const date = dated && visibleTurn ? [{ id: `${DATE}-${user.id}`, version: 1, at: user.at, kind: DATE }] : [];
  // Keep the logical prompt boundary for turn consumers; an invisible prompt draws null and
  // measures zero. Only a wholly invisible completed turn is omitted below.
  const drawnUser = user.incoming?.kind === "hidden" ? [] : [user];
  // A sent prompt waiting for its turn to open draws the Thinking line already, also while its
  // agent still starts (harnessSwitch): no "Starting Claude Code…" and no Cancel there (Leo,
  // 2026-11-01: "i hate the "Starting Claude Code... cancel" thing that it starts with"; the
  // composer's Stop takes the prompt back). The line never jumps from under the bubble to the
  // turn's status row, nor leaves for a frame (cx-ncc.58).
  const waiting = !live && last && user.pending && !user.failed && turn.length === 0 && held.length === 0;
  let shaped: AcpmuxRow[];
  if (waiting) {
    const line: AcpmuxRow = {
      id: LIVE_THINKING,
      version: 1,
      at: user.at,
      kind: THINKING,
      verbKey: user.id,
      // The running turn's slot from the send (`liveSlot`): the turn opening never resizes the line.
      ...liveSlot(lineBelow),
    };
    // Held behind the agent's start: the line draws the start look (agentStart.experiment.ts), with
    // no time yet. The sent prompt's row is stamped when it goes, so a time here would jump from
    // "Thinking 20s" back to 0s when the turn opens (cmux#30642).
    if (user.queued) Object.assign(line, { queued: user.queued, untimed: true });
    shaped = [...date, ...drawnUser, line];
  } else {
    // The person's prompt after the turn, which answers a tagged ask its answer ended on: one sent
    // and still held in the turn, else the prompt that opens the next turn.
    const next = held[0] ?? rows[end];
    const reply = next?.kind === "user" && !next.incoming && next.text ? next.text : undefined;
    const shapedBody = shapeTurn(
      user,
      turn,
      expanded,
      open === "1",
      live,
      last,
      last && held.length === 0,
      retryTarget && (!last || held.length === 0),
      clockOffset,
      liveRuns,
      sessionStatus,
      lineBelow,
      agentFamily,
      reply,
      trayAgents,
      endedBackgroundTurns(source),
    );
    // Where its runs fold, a run of them that carries messages between agents folds under one line
    // (messageRuns.ts; Leo, 2026-11-01: "this should be collapsible").
    const messaged = liveRuns || foldStyle.runs ? foldMessageRuns(shapedBody, expanded) : shapedBody;
    // A run of background-task notifications folds under one line (backgroundRuns.ts; Leo,
    // 2026-11-02: "why do you still do these").
    // A stretch the person came in after ends there, with the end-of-turn footer (`supersededFooters`).
    const body = supersededFooters(foldBackgroundRuns(messaged, expanded), turn, endedByPerson);
    // A running turn's line drawn below stays its last row, under the prompts it holds (a steer
    // waiting for the agent, a prompt that failed to send).
    const liveLine = held.length && body.at(-1)?.below ? body.splice(-1) : [];
    // A prompt sent after the latest turn ended that acpmux has not written yet (its record and the
    // turn it opens come over the event stream, seconds later on a busy daemon) draws the Thinking
    // line under it already, as the chat's first prompt does (`waiting`): from the send on the chat
    // reads as working, never as a finished turn with a bubble under it (Leo, 2026-11-04: "WHY DOES
    // IT LOOK KLIKE YOU'RE NOT RESPONDING HERE???", "this is bad. it looks like you're not working.").
    // The line is the first prompt's (`waiting` above), by id, so the turn that opens goes on with it.
    const sent = last && liveLine.length === 0 ? sentAfterTurn(held) : undefined;
    const line = sent ? [sentLine(sent, lineBelow)] : liveLine;
    const emptyCompleted =
      isVisiblyEmptyMessage(user) &&
      body.length === 0 &&
      turn.some((row) => row.kind === "turnSummary" && row.status === "completed");
    shaped = [
      ...date,
      // Bookkeeping alone starts a turn but draws nothing (incomingMessage.ts).
      ...(emptyCompleted ? [] : drawnUser),
      ...body,
      ...held,
      ...line,
    ];
    // Legacy/history turns can end without a turn_result. Keep the normal turn rhythm at the
    // composer for the latest completed turn without restoring the permanent runway under every
    // turn. The marker is consumed by the row estimator and CSS only for this terminal row.
    if (last && !live && held.length === 0 && !turn.some((row) => row.kind === "turnSummary")) {
      let final = shaped.length - 1;
      while (final >= 0 && (shaped[final]!.kind === DATE || shaped[final]!.kind === "user")) final -= 1;
      if (final >= 0) shaped[final] = { ...shaped[final]!, lastTurn: true };
    }
  }
  if (!live)
    shapedTurns.set(user, {
      source,
      open,
      background,
      messageRuns,
      backgroundRuns,
      last,
      retryTarget,
      clockOffset,
      dated,
      liveRuns,
      lineBelow,
      agentFamily,
      foldStyle,
      endedByPerson,
      rows: shaped,
    });
  return shaped;
}

/// The person's latest prompt held after a turn that ended, still sending or taken but not yet
/// written by acpmux (`pending`), or none: a failed one waits for Retry, and another session's
/// message draws in the group of waiting messages.
function sentAfterTurn(held: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  const sent = held.at(-1);
  return sent?.pending && !sent.failed && !sent.incoming && !sent.received ? sent : undefined;
}

/// The Thinking line under `sent` (``sentAfterTurn``), drawn as the chat's first prompt's is
/// (`waiting` in ``shapedTurn``): the same id, so the turn that opens goes on with it, and one held
/// behind its agent's start draws the start look with no time yet (agentStart.experiment.ts,
/// cmux#30642).
function sentLine(sent: AcpmuxRow, lineBelow: boolean): AcpmuxRow {
  const line: AcpmuxRow = {
    id: LIVE_THINKING,
    version: 1,
    at: sent.at,
    kind: THINKING,
    verbKey: sent.id,
    ...liveSlot(lineBelow),
  };
  if (sent.queued) Object.assign(line, { queued: sent.queued, untimed: true });
  return line;
}

/// The slot a sent prompt's Thinking line takes before its turn opens: with the line drawn below
/// (`lineBelow`), the running turn's last row, the footer's slot (model.ts `fallbackRowHeight`), as
/// the turn's line is from then on. As a plain status row it was 28 px and became 32 when the turn
/// opened, moving every row above it in the middle of the send (Leo, 2026-11-05: "there's the gap
/// between when you send off a message versus otherwise, like it's like there's a one-two
/// discontinuity. That's not good.").
const liveSlot = (lineBelow: boolean): Partial<AcpmuxRow> => (lineBelow ? { below: true } : {});

const isAnswer = (row: AcpmuxRow) => row.kind === "assistant";

/// A tool call after a turn's last text: the turn ended on work, so that text was its narration.
/// Edits join the turn's card and render calls draw as their own cards, so neither counts; a
/// step that edited and then ran something does.
const isWork = (row: AcpmuxRow) =>
  row.kind === "activity" &&
  (row.items ?? []).some((item) => item.tool && !isEditTool(item.tool) && !renderCall(item.tool));

/// Where a finished turn's answer is in `rows`: its last takeaway, or its last nonempty reply
/// after the final tool call. -1: none, so all of it folds. Earlier takeaways are intermediate
/// dialogue once the turn ends; they remain readable when its disclosure opens.
function answerAt(rows: readonly AcpmuxRow[]): number {
  let stepped = false;
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (isReply(row) && (isTakeaway(row) || !stepped)) return at;
    if (isWork(row)) stepped = true;
  }
  return -1;
}

/// A reply with something to read: an empty segment of the agent's text is never a takeaway.
const isReply = (row: AcpmuxRow) => isAnswer(row) && !isVisiblyEmptyText(row.text);

/// A fold holds a mix when the agent's own messages sit between its work, as Codex's "N previous
/// messages" header counts; work alone is one contiguous stretch, its "Worked for".
const foldMixesMessages = (work: readonly AcpmuxRow[]) =>
  work.some(isReply) && work.some((row) => row.kind !== "assistant" && !(row.kind === "user" && !row.incoming));
/// The fold's messages, as Codex counts them: each of the agent's messages, each call or thought
/// in its work, and each report received.
const foldedMessages = (work: readonly AcpmuxRow[]) =>
  work.reduce(
    (n, row) =>
      n +
      (row.kind === "activity"
        ? Math.max(1, row.items?.length ?? 0)
        : isReply(row) || row.kind !== "assistant"
          ? 1
          : 0),
    0,
  );

/// The finished turn's one disclosure, its final answer, and work recorded after that answer.
export type FoldSegment = { anchor: AcpmuxRow; rows: AcpmuxRow[]; takeaway?: AcpmuxRow; after?: AcpmuxRow[] };

/// Once the turn finishes, all intermediate dialogue and received reports fold together. The
/// original prompt remains its stable anchor even if the answer or a steer's row changes.
export function foldSegments(opener: AcpmuxRow, rows: readonly AcpmuxRow[]): FoldSegment[] {
  const drawn = rows.filter((row) => row.kind !== "typing");
  const final = answerAt(drawn);
  return [
    {
      anchor: opener,
      rows: final < 0 ? drawn : drawn.slice(0, final),
      ...(final >= 0 && { takeaway: drawn[final], after: drawn.slice(final + 1) }),
    },
  ];
}

const isUnsent = (row: AcpmuxRow) => Boolean(row.pending || row.failed);

/// The ids of a finished turn's replies to the person, which keep their action row inside its open
/// fold (model.ts hasReplyActions): each takeaway, and the last words before each steer or received
/// message (the reply after the part's last step). Short narration between steps stays quiet.
function repliesIn(body: readonly AcpmuxRow[]): Set<string> {
  const replies = new Set<string>();
  let stepped = false;
  let answered = false;
  for (let at = body.length - 1; at >= 0; at -= 1) {
    const row = body[at]!;
    if (row.kind === "user") {
      stepped = answered = false;
      continue;
    }
    if (isReply(row) && (isTakeaway(row) || (!stepped && !answered))) {
      replies.add(row.id);
      answered = true;
    }
    if (isWork(row)) stepped = true;
  }
  return replies;
}

function shapeTurn(
  user: AcpmuxRow,
  turn: AcpmuxRow[],
  expanded: Folds,
  foldOpen: boolean,
  live: boolean,
  last: boolean,
  retryable: boolean,
  retryTarget: boolean,
  clockOffset = 0,
  liveRuns = false,
  sessionStatus = false,
  lineBelow = false,
  agentFamily?: string,
  reply?: string,
  trayAgents = 0,
  endedBackground: ReadonlySet<string> = new Set(),
): AcpmuxRow[] {
  const end = turn.findIndex((row) => row.kind === "turnSummary");
  // A turn still running shows its work as it happens, under its live status; one without a
  // summary that is no longer running draws as it came.
  if (end < 0)
    return live
      ? liveTurn(user, turn, clockOffset, liveRuns, sessionStatus, lineBelow, trayAgents)
      : last
        ? planLast(turn.flatMap(withoutDrafts).map(endedPlan))
        : settledWithoutSummary(turn);
  const summary = turn[end]!;
  // The agent's own wrap-up call (wrapUp.ts) is the card, not a row of its work.
  const worked = turn.slice(0, end);
  const wrapUp = summary.status === "completed" ? lastWrapUp(worked) : undefined;
  const body = withoutWrapUp(worked).filter((row) => !isVisiblyEmptyMessage(row));
  // Each harness family ends a turn as its own app does (Leo, 2026-11-01: "separate it per
  // harness/model family. claude gets claude behaviour, codex gets codex"). Codex and ChatGPT fold
  // the whole turn's work under one "Worked for". Claude, as Claude desktop: no "Worked for"; each
  // run of calls, the short notes inside it with it, folds into its own summary line, and a longer
  // message between runs stays in place (Leo, 2026-11-04: "you can't do it for Claude ... it's just
  // too lossy if you do it for Claude"); its whole-turn "Worked for" is an opt-in only.
  // The family's row of the one table (turnFoldStyle.ts) says how: Codex and ChatGPT under one
  // "Worked for", Claude, Gemini and Muse with no turn fold.
  const style = turnFoldStyle(agentFamily);
  // Notification turns can contain an empty assistant segment and a summary solely for
  // bookkeeping. With no visible prompt or work, omit the whole turn, including its footer.
  if (isVisiblyEmptyMessage(user) && body.length === 0 && summary.status === "completed") return [];
  const final = answerAt(body);
  const answer = final >= 0 ? body[final] : undefined;
  // A tagged ask the answer ends on (nextStepAsk.ts) draws as a card under it, answerable until a
  // later prompt picks one of its answers or a later card takes over (`settleNextSteps`). Read
  // once per ended turn, never while the turn runs. A turn that stopped or failed, or that another agent's message
  // follows, keeps the ask in its prose.
  // The agent's wrap-up call goes before a tagged ask in its prose, and stays as the turn's recap
  // once a prompt follows. A recap alone needs no reply to wait for.
  const tagged = !live && !wrapUp && summary.status === "completed" ? nextStepAsk(answer?.text) : undefined;
  const ask = live ? undefined : (wrapUp ?? tagged);
  // Where nothing can answer it (another agent's message follows), a wrap-up keeps its recap alone.
  const answerable = ask && (reply !== undefined || retryable || !ask.question);
  const nextStep = answerable ? ask : wrapUp?.recap ? { ...wrapUp, question: "", options: [] } : undefined;
  const shaped: AcpmuxRow[] = [];
  // A derived row's version must change whenever what it draws does: the memoized rows and the
  // height cache compare versions only. Answer versions stay far below VERSION_SPAN.
  const version = summary.version * VERSION_SPAN + (answer?.version ?? 0);
  const edits: AcpmuxRow[] = [];
  const replies = repliesIn(body);
  const steerDialogue = steerDialogueIn(body);
  let folded = false;
  // Where the sub-sessions a folded turn started stay in sight (taskLine.experiment.ts).
  const taskLook = style.conclusion ? experimentArm(finishedTaskLook) : undefined;
  // A completed turn gets one fold for its work; personal steers keep their dialogue visible. The
  // row boundary above is still opensTurn/continuesTurn: an unrelated incoming prompt starts a
  // separate turn and is never gathered by adjacency alone.
  for (const segment of foldSegments(user, body)) {
    const said = segment.takeaway;
    const before = segment.rows;
    const after = segment.after ?? [];
    // Work after the last answer folds with the work before it, so the answer stays last.
    // Edits after it join the card too, so its Undo covers the whole turn.
    const id = `${WORKED}-${segment.anchor.id}`;
    // A family with no turn fold draws as an open "Worked for" without the line.
    const open = !style.conclusion || foldOpen || expanded.has(id);
    // A call still waiting for its permission stays in sight: beside the closed fold, and in its
    // folded run once the fold opens (TurnRows.tsx `staysInSight`).
    const out = (row: AcpmuxRow) =>
      staysOut(row) ||
      (!open && taskLook === "card" && startsTask(row)) ||
      (!open &&
        (steerDialogue.has(row.id) ||
          (row.kind === "activity" && (row.items ?? []).some((item) => awaitsPermission(item.tool)))));
    const work = [...before, ...after].filter((row) => !out(row));
    // A row drawn beside the closed fold is not in the card too: the card takes its first row's id.
    edits.push(...work.filter(isEdit));
    // A turn of nothing but the agent's replies and the person's own steers did no work to fold:
    // it stays drawn as it ran, the steer between the replies (agent-pane-steer-split.test.ts).
    // Reports received from other agents fold like work.
    const dialogue = work.every((row) => (row.kind === "user" && !row.incoming) || isAnswer(row));
    // The tasks this fold hides, as one line each beside it (TaskLine.tsx).
    const tasks = !open && taskLook && taskLook !== "card" && work.length && !dialogue ? startedTasks(work) : [];
    const taskLine: AcpmuxRow | undefined = tasks.length
      ? { id: `${TASK_LINE}-${segment.anchor.id}`, version, at: segment.anchor.at, kind: TASK_LINE, tasks }
      : undefined;
    if (work.length && !dialogue) {
      folded = style.conclusion;
      const from = segment.anchor.at;
      // Its label counts the fold's messages (`previous`), which can change while the summary's and
      // the answer's versions do not: the count is part of the version, so the memoized row redraws.
      const previous = style.countsMessages && foldMixesMessages(work) ? foldedMessages(work) : undefined;
      const worked: AcpmuxRow = {
        id,
        version: (version * 2 + (open ? 1 : 0)) * PREVIOUS_SPAN + Math.min(PREVIOUS_SPAN - 1, previous ?? 0),
        at: from,
        kind: WORKED,
        foldOpen: open,
        status: summary.status,
        toolCount: summary.toolCount,
        tokens: summary.tokens,
        durationMs: summary.durationMs ?? Math.max(0, summary.at - user.at),
        // Codex's header (Leo, 2026-11-02: "i assume the x previous messages are when there's a mix
        // and the worked for is if it's one contiguous thing ... let's follow those"): work with the
        // agent's own messages between it reads "N previous messages", one stretch of work alone
        // "Worked for".
        ...(previous !== undefined && { previous }),
      };
      if (style.conclusion) shaped.push(worked);
      if (taskLine && taskLook === "after-fold") shaped.push(taskLine);
      // Open, each run of its work folds into its summary line between the commentary, as in a
      // running turn (codexRuns). A run that edited folds too: its edits stay in sight between the
      // summary lines of the work around them (TurnRows.tsx `runStretches`).
      // A steer's reply never joins a run: it stays in sight beside the steer.
      const runs = liveRuns || style.runs;
      if (open)
        shaped.push(
          ...(runs ? mergeShortNotes(work, steerDialogue, style.runs) : work).flatMap(withoutDrafts).map((row) => ({
            ...endedPlan(row),
            id: isEdit(row) ? `${row.id}${FOLDED}` : row.id,
            settled: true,
            // A finished turn's earlier replies fold here too; each keeps its action row, while a
            // short note stays quiet (Leo, 2026-10-29: replies keep their action row).
            ...(replies.has(row.id) && { foldedReply: true }),
            // A folded run draws otherwise, so its version moves (memos compare versions).
            ...(runs && row.kind === "activity" && { foldRun: true, version: row.version * RUN_STATES + 3 }),
          })),
        );
    }
    // Context and actionable rows stay available beside the fold. Render cards keep their
    // source order among them, before or after the answer exactly where the call happened.
    // The segment's todo list leaves its place among them: it closes the segment, under the answer,
    // where it stood pinned while the turn ran (shapeLiveTurn), so the turn's end only folds it.
    const outside = (rows: readonly AcpmuxRow[]) =>
      rows.flatMap((row) =>
        isPlan(row) ? [] : out(row) ? [endedPlan(row)] : dialogue ? [row] : renderRows([row], version),
      );
    shaped.push(...outside(before));
    // Waiting as shaped: whether a later prompt answered it is `settleNextSteps`'s to say.
    const card = (at: number): AcpmuxRow => ({
      id: `${NEXT_STEP}-${segment.anchor.id}`,
      version: version * SETTLED_STATES,
      at,
      kind: NEXT_STEP,
      nextStep: { ask: nextStep! },
    });
    const underAnswer = Boolean(said && nextStep && said === answer);
    if (underAnswer) {
      // A wrap-up's answer stays whole. A tagged ask's answer drops the ask's lines, which the
      // card draws; a new version, so its memo redraws.
      if (wrapUp) shaped.push(said!);
      else if (nextStep!.rest) shaped.push({ ...said!, text: nextStep!.rest, version: said!.version * 2 + 1 });
      shaped.push(card(said!.at));
    } else if (said) shaped.push(said);
    shaped.push(...outside(after));
    shaped.push(...[...before, ...after].filter(isPlan).map(endedPlan));
    // A wrap-up in a turn with no answer to hang under goes after the turn's last row.
    if (nextStep && wrapUp && !underAnswer) shaped.push(card(summary.at));
    if (taskLine && taskLook === "after-reply") shaped.push(taskLine);
  }
  shaped.push(...editsCard(edits));
  // The footer copies the answer, so it carries the answer's text; the last turn's also retries
  // its prompt, and stops offering to once a later prompt goes (or waits to). A last turn the
  // reader stopped also offers Continue, as Codex does, until a prompt follows it or it runs again.
  // After a turn the agent started on its own (a later summary in its tail), that turn's summary is
  // the one that offers it, when the reader stopped that one.
  let lastSummary = -1;
  for (let at = turn.length - 1; at > end && lastSummary < 0; at -= 1)
    if (turn[at]!.kind === "turnSummary") lastSummary = at - end - 1;
  const offers = retryable && !live;
  // A late/replayed result can sit beside the stopped turn. Only a summary carrying this turn's
  // identity may authorize Continue; legacy records without ids retain the existing behavior.
  const summaryBelongsToTurn =
    summary.turnId === undefined || user.turnId === undefined || summary.turnId === user.turnId;
  const resumable = offers && lastSummary < 0 && summaryBelongsToTurn && isStopped(summary);
  // A failed last turn goes on with Continue when it did work (it keeps what the turn had done) or
  // has no prompt to send again; one where nothing ran is sent again with Retry (errorRecovery.ts).
  // A notice-started turn has no prompt to send again, so it goes on too; acpmux's own retry attempt
  // (a hidden prompt row) where nothing ran stays Retry.
  const noticeStarted = user.incoming?.kind === "notice" || user.incoming?.kind === "inbox";
  const continuable =
    offers && lastSummary < 0 && isFailed(summary) && (noticeStarted || body.some((row) => row.kind !== "user"));
  // The hint is only rendered for a settled retry target. Avoid scanning the turn body on each
  // live snapshot/token while the turn is still running.
  const changedFiles = (retryable || retryTarget) && !live ? turnChangedFiles(body) : false;
  shaped.push({
    ...summary,
    folded,
    text: answer?.text ?? summary.text,
    // The footer's Copy copies the whole turn (turnCopy.ts): its replies and tool lines in order.
    turnCopy: turnCopyParts(body),
    ...(resumable && { resumable }),
    ...(retryable && { retryable }),
    ...(retryTarget && { retryTarget }),
    ...(continuable && { continuable }),
    ...(changedFiles && { changedFiles: true as const }),
    ...(answer && { answerId: answer.id }),
    // Retry sends the prompt as the agent got it: an incoming message with its sender. A
    // notification, or acpmux's inbox notice, is not a prompt to send again (incomingMessage.ts).
    // The retry target's prompt (``isRetryablePrompt``, which implies the rest), or, as on base, the
    // chat's last turn's for a failed turn's Retry (TurnFooter `failedRetry`, unchanged).
    ...((retryable || retryTarget) &&
      user.incoming?.kind !== "notice" &&
      user.incoming?.kind !== "inbox" &&
      (user.resend ?? user.text) && {
        prompt: user.resend ?? user.text,
        retryRowId: user.id,
        retryAttachments: user.retryAttachments,
      }),
    // A turn is either stopped or failed, so Continue's bit serves both.
    version:
      version * 16 +
      (retryable ? 1 : 0) +
      (resumable || continuable ? 2 : 0) +
      (retryTarget ? 4 : 0) +
      (changedFiles ? 8 : 0),
  });
  // Anything after the summary (late tool updates, or a turn the agent started on its own)
  // draws as it came.
  // A turn the agent started on its own while still working keeps its plan live. Once it runs tools
  // the Codex layout draws it as a running turn (a task notification's work, Leo 2026-10-21: four
  // bare command rows stacked under "Worked for 1s"): its finished runs folded, the call in
  // flight on the one live line under them, timed from the summary.
  const tail = turn.slice(end + 1);
  // Its version moves past any acpmux gives the row (VERSION_SPAN), so the memoized footer redraws.
  const tailSummary = tail[lastSummary];
  // A tail summary is a turn the agent started on its own, so it names another turn than the prompt's.
  // One naming the prompt's own turn (or this turn's summary's) is that turn's result replayed: no Continue.
  const tailIsItsOwnTurn =
    tailSummary?.turnId === undefined || (tailSummary.turnId !== user.turnId && tailSummary.turnId !== summary.turnId);
  if (offers && lastSummary >= 0 && tailIsItsOwnTurn && isStopped(tailSummary)) {
    const stopped = tailSummary;
    tail[lastSummary] = { ...stopped, resumable: true, version: stopped.version + VERSION_SPAN };
  }
  // A turn the agent started on its own that failed has no prompt of its own to send again: Continue.
  if (offers && lastSummary >= 0 && isFailed(tail[lastSummary]!)) {
    const failed = tail[lastSummary]!;
    tail[lastSummary] = { ...failed, continuable: true, version: failed.version + VERSION_SPAN };
  }
  // Its clock runs from the running turn's first row, after the last turn the agent ended on its
  // own, never from the prompt's turn's end: a chat that woke itself all night read "Thinking 11h"
  // under a turn that had just started (Leo, 2026-10-29: "why the fuck are you still depicted as
  // thinking for 11 hours?").
  const ended = tail[lastSummary]?.at ?? summary.at;
  const since = Math.max(ended, tail[lastSummary + 1]?.at ?? ended);
  // Each turn the agent started on its own ends as a prompt's turn does: its reply's footer is a row
  // with the reply to copy, in the slot its live line held while the reply streamed (a reply alone
  // too, not only work), so its end moves nothing (design/transcript-spacing.md "Reply footer").
  const answered = withTailAnswers(tail, endedBackground, summary.seq);
  if (
    live &&
    liveRuns &&
    lineBelow &&
    (tail.some((row) => row.kind === "activity") || tail.slice(lastSummary + 1).some(isReply))
  )
    shaped.push(
      ...liveTurn({ ...summary, at: since }, answered, clockOffset, liveRuns, sessionStatus, lineBelow, trayAgents),
    );
  else shaped.push(...(live ? answered : answered.flatMap(withoutDrafts).map(endedPlan)));
  return shaped;
}

/// `tail` with each of its summaries carrying the reply of the turn it ends, as `shapeTurn` gives the
/// prompt's own summary: a reply's footer is a 32 row of its own, never an empty one laid over the
/// gap (transcriptGrid.ts MARK_FOOTER_ROW). A summary after no reply stays as it came.
function withTailAnswers(tail: AcpmuxRow[], endedBackground: ReadonlySet<string>, seq?: number): AcpmuxRow[] {
  let from = 0;
  let out: AcpmuxRow[] | undefined;
  for (let at = 0; at < tail.length; at += 1) {
    const row = tail[at]!;
    if (row.kind !== "turnSummary") continue;
    const body = tail.slice(from, at);
    from = at + 1;
    if (row.text) continue;
    const answer = body[answerAt(body)];
    if (!answer) continue;
    out ??= [...tail];
    out[at] = {
      ...row,
      text: answer.text,
      answerId: answer.id,
      turnCopy: turnCopyParts(body),
      version: row.version * VERSION_SPAN + answer.version,
    };
  }
  return backgroundFooters(out ?? tail, endedBackground, seq);
}

/// The id prefix of the footer `backgroundFooters` adds under a turn the agent ran on its own.
export const BACKGROUND_END = "backgroundEnd";

/// The ids of the turns the agent ran on its own in `rows` that ended with something to say, so
/// draw their rows (backgroundTurns.ts `foldsBackground`): a running or quiet one is its line.
function endedBackgroundTurns(rows: readonly AcpmuxRow[]): ReadonlySet<string> {
  const ended = new Set<string>();
  for (const row of rows)
    if (row.kind === BACKGROUND_TURN && row.background && !foldsBackground(row)) ended.add(row.background.id);
  return ended;
}

/// `tail` with a footer (copy, fork, pin, read aloud, its time) under the reply of each turn the agent
/// ran on its own (a background task's notification, a scheduled wakeup) that ended with something to
/// say, as a prompt's turn ends (Leo, 2026-11-04: "also i want to be able to copy/voice/fork/whatever at
/// the very bottom... it feels like idk sometimes we're not counting your turns and enabling stuff").
/// acpmux ends such a Claude turn with its `background_turn` ended record, never a `turn_result`
/// (hub/background_turn.rs), so it had no summary to carry a footer and the chat's last reply drew
/// none. Its Copy copies that turn's rows (turnCopy.ts); its Fork goes through the last turn acpmux
/// ended before it (`seq`, or a later one in `tail`), as acpmux forks only there (fork_through.rs),
/// which keeps everything up to the next prompt. One a summary already ends gets none more.
function backgroundFooters(tail: AcpmuxRow[], endedBackground: ReadonlySet<string>, seq?: number): AcpmuxRow[] {
  if (endedBackground.size === 0) return tail;
  const bodies = new Map<string, { rows: AcpmuxRow[]; last: number }>();
  tail.forEach((row, at) => {
    const id = row.inBackground;
    if (id === undefined || !endedBackground.has(id)) return;
    const body = bodies.get(id) ?? { rows: [], last: at };
    body.rows.push(row);
    body.last = at;
    bodies.set(id, body);
  });
  if (bodies.size === 0) return tail;
  const out: AcpmuxRow[] = [];
  let through = seq;
  tail.forEach((row, at) => {
    out.push(row);
    if (row.kind === "turnSummary" && row.seq !== undefined) through = row.seq;
    const id = row.inBackground;
    const body = id === undefined ? undefined : bodies.get(id);
    if (!body || body.last !== at || tail[at + 1]?.kind === "turnSummary") return;
    if (body.rows.some((each) => each.kind === "turnSummary")) return;
    const answer = body.rows[answerAt(body.rows)];
    const parts = answer && !answer.streaming ? turnCopyParts(body.rows) : undefined;
    if (!answer || !parts) return;
    out.push({
      id: `${BACKGROUND_END}-${id}`,
      kind: "turnSummary",
      // The memoized footer redraws when its turn's rows do.
      version: body.rows.reduce((sum, each) => (sum * 31 + each.version) % 2_147_483_647, body.rows.length),
      at: row.at,
      status: "completed",
      durationMs: Math.max(0, row.at - body.rows[0]!.at),
      text: answer.text,
      answerId: answer.id,
      turnCopy: parts,
      ...(through !== undefined && { seq: through }),
    });
  });
  return out;
}

const VERSION_SPAN = 1_000_000;
/// Room in a Worked for row's version for its fold's message count (`previous`).
const PREVIOUS_SPAN = 4096;

/// One render card per render call in `body`, in call order.
function renderRows(body: readonly AcpmuxRow[], version: number): AcpmuxRow[] {
  return body.flatMap((row) =>
    row.kind === "activity"
      ? (row.items ?? []).flatMap((item, index) =>
          item.tool && renderCall(item.tool)
            ? [
                {
                  id: `${RENDER}-${item.tool.id || `${row.id}-${index}`}`,
                  version,
                  at: row.at,
                  kind: RENDER,
                  items: [item],
                },
              ]
            : [],
        )
      : [],
  );
}

/// One edited-files card per ended turn: the turn's edit rows merged into the first one (its id,
/// so View changes still finds the turn), every edit's items in order. It is `ended`, so it
/// offers Undo; its version is odd, so the card the turn's live edit row became redraws.
function editsCard(edits: AcpmuxRow[]): AcpmuxRow[] {
  if (edits.length === 0) return [];
  const [first] = edits as [AcpmuxRow, ...AcpmuxRow[]];
  return [
    {
      ...first,
      version: edits.reduce((sum, row) => sum + row.version, 0) * 2 + 1,
      items: edits.flatMap((row) => row.items ?? []),
      toolCount: edits.reduce((sum, row) => sum + (row.toolCount ?? 0), 0),
      ended: true,
      merged: edits.map((row) => row.id),
    },
  ];
}

/// A row that draws under a finished turn's fold line rather than inside it: a subagent group,
/// the turn's todo list (cx-ncc.80), whose last state is what the turn got done, and the notes
/// below. Where a subagent ended and a compaction are the turn's work and fold with it (Leo,
/// 2026-10-21: fold only the work, "compaction and subagent/system notices" among it).
const staysOut = (row: AcpmuxRow) =>
  isSubagentGroup(row) ||
  (row.kind === "plan" && row.plan !== undefined) ||
  row.kind === "backgroundTask" ||
  // An error or a refusal the pane noted, and an ask still waiting on the person.
  row.kind === "notice" ||
  row.kind === "permission" ||
  // A move to the fallback harness changes who answers the rest of the turn; folded, nobody would
  // see it happened.
  row.kind === "failover" ||
  // A recap is about the whole chat, not the turn above it.
  row.kind === "recap" ||
  // A policy the harness cannot keep: the agent runs without the asks the person chose.
  row.kind === "policyUnenforced" ||
  // A paused agent pair waits for the person's Resume.
  row.kind === "agentPair" ||
  // Where the session started: what it runs on.
  row.kind === "sessionStart" ||
  // A session offer waits for the person's Start or Dismiss.
  row.kind === "sessionOffer" ||
  // A chat the turn started keeps its card in sight (started/startedSessions.ts).
  row.kind === STARTED_SESSIONS ||
  // So does a Claude workflow it started (Labs, summary/WorkflowCard.tsx).
  row.kind === WORKFLOW_CARD ||
  // What the person answered an agent's question, which shaped the rest of the turn.
  row.kind === QUESTION_RECORD;

/// A turn's todo list (an ACP `plan` update's row, direct.ts) that has its entries.
const isPlan = (row: AcpmuxRow) => row.kind === "plan" && row.plan !== undefined;

/// The running turn's todo list, if it has one: the last plan row whose turn has not ended, which
/// App.tsx moves into the hat over the composer (subagents/SubagentTray.tsx `plan`).
export function liveTurnPlan(rows: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind === "plan" && row.plan?.length && !row.turnEnded) return row;
  }
  return undefined;
}

/// Whether two todo lists read the same (each step's words and state).
export function samePlanEntries(
  a: readonly AcpmuxPlanEntry[] | undefined,
  b: readonly AcpmuxPlanEntry[] | undefined,
): boolean {
  if (a === b) return true;
  if (!a || !b || a.length !== b.length) return false;
  return a.every((entry, index) => entry.content === b[index]!.content && entry.status === b[index]!.status);
}

/// The latest todo list with entries among a turn's rows, if any.
const latestPlan = (rows: readonly AcpmuxRow[]) => {
  for (let at = rows.length - 1; at >= 0; at -= 1) if (isPlan(rows[at]!) && rows[at]!.plan!.length) return rows[at];
  return undefined;
};

/// `rows` with their todo lists moved after the rest, in order: an ended turn keeps its list where
/// it stood pinned while it ran.
const planLast = (rows: AcpmuxRow[]): AcpmuxRow[] =>
  rows.some(isPlan) ? [...rows.filter((row) => !isPlan(row)), ...rows.filter(isPlan)] : rows;

/// A finished turn's todo list: a step the agent left in progress no longer spins. The version
/// moves off the live one (v to 2v + 1), so the memoized row draws again when the turn ends.
const endedPlan = (row: AcpmuxRow): AcpmuxRow =>
  row.kind === "plan" && row.plan ? { ...row, turnEnded: true, version: row.version * 2 + 1 } : row;

/// A turn that ended without a summary: a later prompt came before it (another agent's message
/// that arrived while it ran splits it here) or it is history from before acpmux kept summaries.
/// It draws as it came: the agent's messages stay in place, each on its own, and nothing folds
/// that the person did not fold (Leo, 2026-10-20: never auto-collapse messages into "N previous
/// messages").
/// Its edits still close it as one card, which offers Undo.
function settledWithoutSummary(turn: AcpmuxRow[]): AcpmuxRow[] {
  const rows = turn.filter((row) => row.kind !== "typing");
  return [
    ...planLast(
      rows
        .filter((row) => !isEdit(row))
        .flatMap(withoutDrafts)
        .map(endedPlan),
    ),
    ...editsCard(rows.filter(isEdit)),
  ];
}

/// `drawn` with an end-of-turn footer (copy, pin, read aloud, its time) under each stretch of the
/// turn the person came in on: the agent's replies and work before a steer that landed (a message sent
/// into the running turn, or one sent now), and the end of a turn with no summary that a new prompt
/// of his opened over (`endedByPerson`). Those stretches count as ended once he comes in, though the
/// turn goes on or never got a clean end, as Claude Code desktop draws them (Leo, 2026-11-03: "i also
/// think a lot of these should've been counted as "ended"-ish turns that allow me to copy/paste your
/// stuff / cuz look claude code lets that happen if the user comes in"). Its Copy copies the stretch
/// (turnCopy.ts). A stretch that said nothing, or whose reply still streams, gets none; nor does one
/// that already ends on a footer. `turn` is the turn's rows before shaping, in order.
function supersededFooters(drawn: AcpmuxRow[], turn: readonly AcpmuxRow[], endedByPerson: boolean): AcpmuxRow[] {
  let out: AcpmuxRow[] | undefined;
  let from = 0;
  const close = (to: number, at: number | undefined, key: string) => {
    const stretch = turn.slice(from, to).filter((row) => row.kind !== "turnSummary");
    from = to + 1;
    // Its last reply, also one with work after it: the stretch ended where the person came in.
    let answer: AcpmuxRow | undefined;
    for (let back = stretch.length - 1; back >= 0 && !answer; back -= 1)
      if (isReply(stretch[back]!)) answer = stretch[back];
    const list = out ?? drawn;
    const place = at ?? list.length;
    if (!answer || answer.streaming || list[place - 1]?.kind === "turnSummary") return;
    const parts = turnCopyParts(stretch);
    if (!parts) return;
    out ??= [...drawn];
    out.splice(place, 0, {
      id: `${SUPERSEDED}-${key}`,
      kind: "turnSummary",
      // The memoized footer redraws when its stretch does.
      version: stretch.reduce((sum, row) => (sum * 31 + row.version) % 2_147_483_647, stretch.length),
      at: stretch.at(-1)!.at,
      status: "completed",
      superseded: true,
      text: answer.text,
      answerId: answer.id,
      turnCopy: parts,
    });
  };
  for (let index = 0; index < turn.length; index += 1) {
    const row = turn[index]!;
    if (row.kind !== "user" || row.incoming || row.received || !continuesTurn(row) || row.steer === "waiting") continue;
    const at = (out ?? drawn).findIndex((each) => each.id === row.id);
    if (at < 0) from = index + 1;
    else close(index, at, row.id);
  }
  if (endedByPerson && !turn.some((row) => row.kind === "turnSummary"))
    close(turn.length, undefined, turn.at(-1)?.id ?? "end");
  return out ?? drawn;
}

/// An activity row without the calls it has nothing to show for yet (toolGroups.ts `isDraftCall`),
/// or no row when they were all it held, so bare "Running a command" rows never stack up (Leo,
/// 2026-10-21: they should replace each other, as Thinking does). A running turn's live line names
/// the newest (codexLiveTurn); an ended turn's never got their input. Which calls it drops follows
/// from the row's items, so its version stands.
function withoutDrafts(row: AcpmuxRow): AcpmuxRow[] {
  if (isVisiblyEmptyMessage(row)) return [];
  if (row.kind !== "activity") return [row];
  const items = row.items ?? [];
  const kept = items.filter((item) => !(item.tool && isDraftCall(item.tool)));
  if (kept.length === items.length) return [row];
  return kept.length ? [{ ...row, items: kept }] : [];
}

/// The live status. With `lineBelow` (the default in the app, Debug Settings
/// `agentPane.debug.liveLineBelow`) it is the turn's last row from send to end, as Claude desktop
/// draws it: what the agent is doing now ("Thinking" before any output, the call in flight, else
/// "Working for") and
/// the turn's time, which ticks until the turn ends, so the bottom of a running chat always moves.
/// It keeps one id from the Thinking line the prompt opened (LIVE_THINKING), so its row never
/// leaves and comes back.
///
/// Otherwise it is shaped as the turn will fold when it ends: rows before the latest text are
/// its work, so a turn so far only streaming its answer draws no status (it ends without a
/// fold). The line is timed from the prompt and draws its own clock; while text streams, the
/// clock stops at that text's start, where "Worked for" would time the turn if it ended there.
/// The client's empty "typing" placeholder gives way to it.
/// With `sessionStatus` and a todo list, the list sits under the work and the activity line under
/// it takes the status's place (cx-ncc.102, Claude Code desktop's in-session status).
function liveTurn(
  user: AcpmuxRow,
  turn: AcpmuxRow[],
  clockOffset: number,
  liveRuns = false,
  sessionStatus = false,
  lineBelow = false,
  trayAgents = 0,
): AcpmuxRow[] {
  return withRetry(turn, shapeLiveTurn(user, turn, clockOffset, liveRuns, sessionStatus, lineBelow, trayAgents));
}

/// The running turn's retries (the client's `TURN_RETRY` row, direct.ts) on its "Thinking" line:
/// while its harness retries a failed model request the line says the model cannot be reached,
/// never "Thinking" (Leo, 2026-11-03, on "Thinking 7m 49s" for a chat whose model gateway was down:
/// "i feel like this mac session just keeps "thinking""). Once the model answers, the time the
/// retries took leaves the line's "Thinking" clock, which before the first output times the turn
/// from its prompt. A fresh line object, so the memoized row draws again.
export function withRetry(turn: readonly AcpmuxRow[], shaped: AcpmuxRow[]): AcpmuxRow[] {
  const retryRow = turn.find((row) => row.id === TURN_RETRY);
  if (!retryRow?.retry && !retryRow?.retriedMs) return shaped;
  const at = shaped.length - 1;
  const line = shaped[at];
  if (line?.kind !== THINKING) return shaped;
  const timedFromPrompt = line.doing === undefined && line.liveState === undefined && !line.turnTotal;
  const next: AcpmuxRow = {
    ...line,
    ...(retryRow.retry && { retry: retryRow.retry }),
    ...(!retryRow.retry && retryRow.retriedMs && timedFromPrompt && { at: line.at + retryRow.retriedMs }),
  };
  return [...shaped.slice(0, at), next];
}

function shapeLiveTurn(
  user: AcpmuxRow,
  turn: AcpmuxRow[],
  clockOffset: number,
  liveRuns = false,
  sessionStatus = false,
  lineBelow = false,
  trayAgents = 0,
): AcpmuxRow[] {
  const drawn = turn.filter((row) => row.kind !== "typing" && !isVisiblyEmptyMessage(row));
  // A started chat's card that no row follows yet is not the turn's latest step. The latest step is
  // read before the Codex-style runs fold it: the call it runs is what the live line names.
  let last: AcpmuxRow | undefined;
  for (let index = drawn.length - 1; index >= 0 && !last; index -= 1)
    if (drawn[index]!.kind !== STARTED_SESSIONS) last = drawn[index];
  // The Codex-style live line names the call in flight; a command still running in an earlier run
  // (a parallel `cp` while the agent messages others) leaves its run for the line too.
  const named = lineBelow && liveRuns && last ? lineCall(drawn, last) : undefined;
  // A reply before a steer never joins a run, as in the ended turn (steerDialogueIn).
  const rows = liveRuns ? codexRuns(mergeShortNotes(drawn, steerDialogueIn(drawn)), named?.tool.id) : drawn;
  // The status ticks on this computer's clock, from the prompt moved onto it.
  const at = user.at + clockOffset;
  if (lineBelow && liveRuns) {
    const shaped = codexLiveTurn(user, drawn, rows, last, named, at, clockOffset, sessionStatus, trayAgents);
    // The line is the turn's last row, made fresh here.
    if (named?.earlier) shaped.at(-1)!.linedCall = named.tool.id;
    return shaped;
  }
  if (lineBelow) {
    const shown = withLiveStep(rows, last);
    // The todo list is pinned under the latest message, the live line under it (Leo, 2026-11-03).
    const plan = latestPlan(shown);
    // With agent.sessionStatus the activity line under the list is the live line (cx-ncc.102); it
    // is already the turn's last row and ticks from the prompt.
    if (plan && sessionStatus && last?.kind !== "assistant") {
      const work = shown.filter((row) => row !== plan);
      return [...work, plan, activityLine(user, work, plan, clockOffset, undefined, true)];
    }
    const status: AcpmuxRow = { id: LIVE_THINKING, version: 2, at, kind: WORKING, below: true };
    const doing = last && inFlightCall(last);
    // A running command's ⌃B hint is the line's, never its row's (WorkingFor.tsx); none while the
    // agent still writes the command (`doingDraft`).
    if (doing?.command) status.doingCommand = true;
    if (doing?.draft) status.doingDraft = true;
    // One running call reads once: not here while its own row names it (`ownRow`).
    if (doing && doing.row !== true) {
      status.doing = doing.title;
      Object.assign(status, sendingTo(doing.tool));
      if (doing.row) Object.assign(status, { doingGroup: doing.row.key, doingGroupOpen: doing.row.open });
    }
    // Before any output it reads "Thinking"; a thought coming in labels itself (ThoughtRow.tsx).
    else if (!last) status.thinkingNow = true;
    // The answer streams over the list, and the line stays under both.
    if (plan) return [...shown.filter((row) => row !== plan), plan, status];
    return [...shown, status];
  }
  // A turn with only its started chats' card so far keeps the card under its thinking line.
  if (!last) return [{ id: LIVE_THINKING, version: 1, at: user.at, kind: THINKING, verbKey: user.id }, ...rows];
  const answering = last.kind === "assistant";
  if (answering && rows.length === 1) return rows;
  const status: AcpmuxRow = { id: `${WORKING}-${user.id}`, version: 1, at, kind: WORKING };
  if (answering) Object.assign(status, { version: 2, durationMs: Math.max(0, last.at - user.at) });
  // While a call runs the line names it, as Claude desktop's does (WorkingFor.tsx), unless the
  // call's own row, right under it, already does: one running call reads once. The Codex-style
  // runs draw no call in flight (codexRuns), so there the line always names it.
  else {
    const doing = inFlightCall(last);
    if (doing?.command) status.doingCommand = true;
    if (doing?.draft) status.doingDraft = true;
    if (doing && (liveRuns || doing.row !== true)) {
      status.doing = doing.title;
      Object.assign(status, sendingTo(doing.tool));
      if (doing.row && doing.row !== true && !liveRuns)
        Object.assign(status, { doingGroup: doing.row.key, doingGroupOpen: doing.row.open });
    }
  }
  // The Codex-style runs hold no streaming thought (codexRuns).
  const shown = liveRuns ? rows : withLiveStep(rows, last);
  const plan = latestPlan(shown);
  if (!plan) return [status, ...shown];
  const work = shown.filter((row) => row !== plan);
  // The list is pinned under the latest message; the answer streams over it.
  if (answering) return [...work, plan];
  if (!sessionStatus) return [status, ...work, plan];
  return [
    ...work,
    plan,
    activityLine(
      user,
      drawn.filter((row) => row !== plan),
      plan,
      clockOffset,
    ),
  ];
}

/// A running turn as the Codex app draws it (Debug toggles `codexToolRuns` and `liveLineBelow`, both
/// on by default): each finished run folded into its summary line between the paragraphs
/// (codexRuns), and at the bottom the turn's one live block, a line that each step replaces in place
/// (Leo 2026-10-20: "Thinking (shimmer) -> Running <short label> -> Thinking"): "Thinking 18s"
/// (the turn's time) while the agent thinks, "Running <what the call does> 13s" while a call runs.
/// Nothing draws over the turn's work (Leo 2026-10-21: a "Working for" there sat far above the
/// line, past his steers). The line keeps the Thinking line's id from send to the turn's end, so it never leaves and
/// comes back. While text streams it stays and reads "Writing" (`quietKey`, Thinking.tsx). With a todo list (`sessionStatus`) the list sits just over the line.
function codexLiveTurn(
  user: AcpmuxRow,
  drawn: AcpmuxRow[],
  runs: AcpmuxRow[],
  last: AcpmuxRow | undefined,
  named: LineCall | undefined,
  at: number,
  clockOffset: number,
  sessionStatus: boolean,
  trayAgents = 0,
): AcpmuxRow[] {
  let rows = runs;
  // The one live block sits at the turn's bottom, as the ChatGPT and Codex apps draw it: no
  // "Working for" over the turn (with steers it stood above all of them, far from the line; Leo,
  // 2026-10-21). Between steps it reads "Thinking 18s", timed from the prompt.
  const line: AcpmuxRow = { id: LIVE_THINKING, version: 1, at, kind: THINKING, below: true, verbKey: user.id };
  if (!last) return [...rows, line];
  if (named) {
    const call = named.tool;
    // A command reads its short line; one with no line yet reads its title ("Run make"). While
    // Claude still writes its input (a pending "Bash" with no command, often 20s for a long
    // script) it reads "Writing a command", never "Running" a command that has not started.
    const shell =
      call.kind === "execute" && !call.description && (Boolean(call.command) || isBareShellName(call, call.title));
    line.doing = shell ? (call.command ? shortCommand(call.command) : "") : runningLabel(call, "");
    line.doingShell = shell;
    if (shell && !call.command && call.status === "pending") line.doingDraft = true;
    // A started command shows "⌃B to run in background" on the line, never on a transcript row
    // (Thinking.tsx; Leo, 2026-10-22: "this cmd b to run in background ... it should prob go down").
    if (call.kind === "execute" && !line.doingDraft && call.background === undefined) line.doingCommand = true;
    Object.assign(line, sendingTo(call));
    line.doingAt = (call.startedAt ?? named.at) + clockOffset;
  } else if (last.kind === "assistant") {
    line.quietKey = `${last.id}:${last.version}`;
    // When that reply was written, so a chat opened long after it paused reads "Thinking" at once
    // rather than "Writing" for WRITING_MS from the open (Thinking.tsx).
    line.quietAt = last.at + clockOffset;
    // Past the streaming text's pause the line says the agent writes, never "Thinking".
    line.liveState = "writing";
  }
  // Past the turn's first step its clock reads as the turn's whole time ("2s · 4m" after a step's own time, else "4m" beside the label), so a long wait
  // never reads as that long a think, call or step (Leo, 2026-11-03: "i think the "thinking"
  // accounting is also off pretty frequently", on "Thinking 1h 24m 7s" for a turn that waited on
  // its subagents).
  line.turnTotal = true;
  const answering = last.kind === "assistant";
  // The todo list is pinned under the latest message, the live line under it, from its first
  // update to the turn's end (Leo, 2026-11-03, on Claude Code desktop's task list). With
  // agent.sessionStatus the activity line under it is the live line instead (`statusPlan`).
  const plan = latestPlan(rows);
  const statusPlan = sessionStatus ? plan : undefined;
  // No call in flight and no answer streaming, while foreground subagents still run: the agent
  // waits on them ("Waiting on 2 subagents"), whatever its last row was.
  const agents = named || answering ? 0 : foregroundAgents(drawn) + trayAgents;
  if (agents > 0) Object.assign(line, { liveState: "subagents", liveAgents: agents });
  // With a todo list and no answer streaming, the activity line under the list is the live line
  // (below), which names the plan's step, so no call leaves its run for it.
  if (!named && !answering && !statusPlan && agents === 0) {
    // Between calls the line keeps the latest finished step ("Ran grep …") instead of a separate
    // "Thinking" under it, shimmering and timed from the prompt like any step: the line is the
    // turn's current activity and just keeps going (Leo, 2026-11-01: "this should be replacing
    // the thinking area and its shimmer across things", "like the thinking or whatever it should
    // just keep going"). The step leaves its run while the line names it, so it reads once.
    const lifted = liftedStep(rows, last);
    if (lifted) {
      rows = lifted.rows;
      line.doing = lifted.doing;
      line.doingShell = lifted.shell;
      line.doingDone = true;
      // The step's own time, not the turn's ("Opened 1 agent session 3m 27s · 1h 22m").
      if (lifted.ms !== undefined) line.doingForMs = lifted.ms;
    }
  }
  // Still "Thinking" after the first step: the time beside it is only the turn's thinking, the
  // summed spans its thoughts streamed, never the calls, waits and queue time between them (Leo's
  // "Thinking 7m 34s · ↓ 4.5K out", 2026-11-03). The turn's whole time is the total after it.
  if (line.doing === undefined && line.liveState === undefined) line.thoughtMs = thoughtTime(drawn);
  if (!plan) return [...rows, line];
  const work = rows.filter((row) => row !== plan);
  // The answer streams over the list, the line under both.
  if (answering || !statusPlan) return [...work, plan, line];
  // With a todo list the activity line under it is the live line (cx-ncc.102), as without these
  // toggles; it reads the call in flight from the turn's rows, which the runs no longer hold.
  return [
    ...work,
    plan,
    activityLine(
      user,
      drawn.filter((row) => row !== plan),
      plan,
      clockOffset,
      named?.tool,
      true,
    ),
  ];
}

/// The latest run's last finished call, lifted out of the run for the live line to name: a command
/// as its short line ("Ran grep …"), any other call as its row names it. Only a plain step: a failed
/// call keeps its mark in the run, a command sent to the background keeps its state there, and
/// messages, sub-sessions, subagent calls, render cards and edits keep their own rows. Nil when the latest step is anything else.
function liftedStep(
  rows: AcpmuxRow[],
  last: AcpmuxRow,
): { rows: AcpmuxRow[]; doing: string; shell: boolean; ms?: number } | undefined {
  if (last.kind !== "activity") return undefined;
  // A run that a short note joined to an earlier one keeps the earlier one's id (mergeShortNotes).
  const at = rows.findIndex((row) => row.id === last.id || row.joined?.includes(last.id));
  const run = rows[at];
  if (!run?.foldRun) return undefined;
  const items = run.items ?? [];
  // Thoughts after it are the agent thinking about it; the line still names the call.
  let index = items.length - 1;
  while (index >= 0 && !items[index]!.tool) index -= 1;
  const item = items[index];
  const call = item?.tool;
  if (
    !call ||
    isRunning(call) ||
    call.background !== undefined ||
    callFailed(call) ||
    isEditTool(call) ||
    renderCall(call) ||
    subsessionCall(call) ||
    agentCall(call) ||
    agentMessage(call) ||
    acpmuxSendCalls(call) ||
    acpmuxMcpSends(call)
  )
    return undefined;
  const shell =
    call.kind === "execute" && !call.description && (Boolean(call.command) || isBareShellName(call, call.title));
  const doing = shell ? (call.command ? shortCommand(call.command) : "") : runningLabel(call, item!.text);
  const kept = items.filter((_, position) => position !== index);
  const next = rows.slice();
  if (kept.length) next[at] = { ...run, items: kept, version: run.version * LIFTED_STATES + 1 };
  else next.splice(at, 1);
  const ms =
    call.startedAt !== undefined && call.endedAt !== undefined ? Math.max(0, call.endedAt - call.startedAt) : undefined;
  return { rows: next, doing, shell, ms };
}

/// The time a live turn's thoughts streamed, each from its first chunk to its latest, summed;
/// undefined when none is dated.
function thoughtTime(rows: readonly AcpmuxRow[]): number | undefined {
  let total: number | undefined;
  for (const row of rows)
    if (row.kind === "activity")
      for (const item of row.items ?? []) {
        const ms = isThought(item) ? thoughtDuration(item) : undefined;
        if (ms !== undefined) total = (total ?? 0) + ms;
      }
  return total;
}

/// Foreground subagents still running in a live turn's rows (its subagent groups): the ones the
/// agent waits on. One running in the background (`background`) outlives the turn, so it is no wait.
/// The foreground subagents still running in the latest prompt's turn, read from the rows before the
/// running tray takes their groups out (App.tsx passes it to ``turnViewFrom`` as `trayAgents`).
/// Agents in groups before that prompt are an earlier turn's, which a cancel may have left running;
/// a prompt still waiting to send opens no turn yet. A shell call's agent keeps its card in the rows
/// (runningTray.ts), where the line counts it already.
export function trayWaitAgents(rows: readonly AcpmuxRow[]): number {
  let from = rows.length;
  while (from > 0 && !(opensTurn(rows[from - 1]!) && !isUnsent(rows[from - 1]!))) from -= 1;
  return from === 0 ? 0 : foregroundAgents(rows.slice(from).filter((row) => !isRunGroup(row)));
}
function foregroundAgents(rows: readonly AcpmuxRow[]): number {
  let count = 0;
  for (const row of rows)
    if (isSubagentGroup(row))
      for (const agent of row.subagents ?? []) if (agent.state === "running" && !agent.background) count += 1;
  return count;
}
/// A run with its last call on the live line differs from the same run whole. (Not a sixth
/// `RUN_STATES`: the minimap's edit-card versions are pinned to five.)
const LIFTED_STATES = 2;

/// The newest call still running in a live turn's latest row.
function runningCall(
  row: AcpmuxRow,
  matches: (tool: NonNullable<AcpmuxActivity["tool"]>) => boolean = () => true,
): NonNullable<AcpmuxRow["items"]>[number]["tool"] | undefined {
  if (row.kind !== "activity") return undefined;
  const items = row.items ?? [];
  for (let index = items.length - 1; index >= 0; index--) {
    const tool = items[index]?.tool;
    if (tool && isRunning(tool) && matches(tool)) return tool;
  }
  return undefined;
}

/// `earlier`: the command runs in an earlier run, which leaves it out for the line (`codexRuns`).
type LineCall = { tool: NonNullable<ReturnType<typeof runningCall>>; at: number; earlier?: true };

/// The call the Codex-style live line names: the newest one running in the turn's latest step, else
/// the newest command still running anywhere in the turn, so a command never runs under "Thinking"
/// (Leo, 2026-10-22: "the ran thing basiclly replcaes the thinking usually").
function lineCall(drawn: readonly AcpmuxRow[], last: AcpmuxRow): LineCall | undefined {
  const latest = runningCall(last);
  if (latest) return { tool: latest, at: last.at };
  for (let index = drawn.length - 1; index >= 0; index -= 1) {
    const row = drawn[index]!;
    const tool = runningCall(row, (call) => call.kind === "execute" && !call.background && !isDraftCall(call));
    if (tool) return { tool, at: row.at, earlier: true };
  }
  return undefined;
}

/// The latest step row may still stream its last thought (ThoughtRow.tsx). Its version moves off
/// the stored one, so the row draws again, done, once another row follows it. A started chats'
/// card may follow it (`last` is the latest row that is not one).
function withLiveStep(rows: AcpmuxRow[], last: AcpmuxRow | undefined): AcpmuxRow[] {
  if (last?.kind !== "activity") return rows;
  return rows.map((row) => (row === last ? { ...last, live: true, version: last.version * 2 + 1 } : row));
}

/// The activity line of a running turn: its running tool call as its row names it (a command as
/// itself, an edit by its file name), else the todo in progress. What it names is its text and
/// moves its version, so the memoized row redraws when the call's path arrives; it carries no
/// items, so Find never counts the call's output a second time. Its clock ticks from the prompt.
/// With `named` (the Codex-style runs, `lineCall`) it names that call, the one the runs left out, so
/// a command never leaves its run without the line naming it.
function activityLine(
  user: AcpmuxRow,
  work: AcpmuxRow[],
  plan: AcpmuxRow,
  clockOffset: number,
  named?: NonNullable<AcpmuxActivity["tool"]>,
  below = false,
): AcpmuxRow {
  const running = named
    ? { kind: "tool", text: "", tool: named }
    : work
        .flatMap((row) => (row.kind === "activity" ? (row.items ?? []) : []))
        .reverse()
        .find((item) => item.tool?.status === "pending" || item.tool?.status === "in_progress");
  const label = running?.tool
    ? runningLabel(running.tool, running.text)
    : (plan.plan?.find((entry) => entry.status === "in_progress")?.content ?? "");
  // A started command offers ⌃B here, as on the turn's other live lines (ActivityLine.tsx).
  const command =
    running?.tool?.kind === "execute" && !isDraftCall(running.tool) && running.tool.background === undefined;
  let version = 1;
  for (let index = 0; index < label.length; index += 1) version = (version * 31 + label.charCodeAt(index)) % 1_000_003;
  const line: AcpmuxRow = {
    id: `${ACTIVITY_LINE}-${user.id}`,
    version: version * 2 + (command ? 1 : 0),
    at: user.at + clockOffset,
    kind: ACTIVITY_LINE,
    text: label,
    // The line below a plan occupies the footer's slot. Keeping the marker on that row lets the
    // estimator and the DOM swap it for `turnSummary` without changing the rows above it.
    ...(below && { below: true }),
  };
  if (command) line.doingCommand = true;
  if (running?.tool) Object.assign(line, sendingTo(running.tool));
  return line;
}

/// The message a call in flight sends, for the live line: "Sending message to tests", never the
/// raw `acpmux send …` line (Leo 2026-10-24: "sending message or sent message to X or Y").
function sendingTo(tool: NonNullable<AcpmuxActivity["tool"]>): Pick<AcpmuxRow, "doingSendTo" | "doingSendSession"> {
  const sends = acpmuxSendCalls(tool) ?? acpmuxMcpSends(tool);
  // Only a send still going: one that failed in the background is not "Sending" any more. A batch
  // names the first message still going out.
  if (sends) {
    const going = sends.find((send) => send.state === "sending");
    return going ? { doingSendTo: going.target } : {};
  }
  if (tool.kind === "execute" && tool.command) return {};
  const call = subsessionCall(tool);
  const short = (id: string) => (id.length > 12 ? `${id.slice(0, 8)}…` : id);
  if (call?.tool === "send") return { doingSendTo: short(call.sessionId), doingSendSession: call.sessionId };
  // A harness's own message tool (Claude's SendMessage), which a group of messages draws while it
  // runs with the Codex-style runs off: with them on it leaves its run, so the line names it.
  const to = !call && isRunning(tool) ? agentMessage(tool)?.to : undefined;
  return to ? { doingSendTo: short(to) } : {};
}

/// A running call in one short line: a command as itself ("Ran …" would say it has finished), a
/// file call by the file's name ("Edit ProductGrid.module.css").
function runningLabel(tool: Parameters<typeof toolLabel>[0], text: string): string {
  const label = toolLabel(tool, text, (command) => command);
  const path = editedPaths(tool)[0];
  if (!path || tool.kind === "execute") return label;
  return `${label.split(/\s+/, 1)[0]} ${path.split("/").pop() || path}`;
}

/// The newest call still running in a live turn's latest row, by its title, and where the
/// transcript draws its own row (`ownRow`).
function inFlightCall(
  row: AcpmuxRow,
):
  | { title: string; command: boolean; draft: boolean; row: OwnRow; tool: NonNullable<AcpmuxActivity["tool"]> }
  | undefined {
  if (row.kind !== "activity") return undefined;
  const items = row.items ?? [];
  for (let index = items.length - 1; index >= 0; index--) {
    const tool = items[index]?.tool;
    if (!tool || !isRunning(tool)) continue;
    // The row's own label, never the call's raw JSON input; a command reads as itself.
    const title = toolLabel(tool, "", (command) => command).trim();
    const draft = isDraftCall(tool);
    return title
      ? { title, command: tool.kind === "execute", draft, row: ownRow(row, items[index]!), tool }
      : undefined;
  }
  return undefined;
}

/// `true` when the call's own row is always drawn; the disclosure of the group that draws it while
/// open (`open` is its default); nil when no row of its own is drawn.
type OwnRow = true | { key: string; open: boolean } | undefined;

/// Where ToolRows draws a call (TurnRows.tsx groupNode, ToolGroupRow.tsx): a lone call, a message
/// card, a sub-session card and a lone MCP call have their own row; a grouped call shows under its group's line while
/// the group is open (every step shows, ToolGroupRow.tsx); a folded run (`foldRun`, codexRuns) shows none
/// until opened. The key is the one groupNode gives the group's disclosure.
function ownRow(row: AcpmuxRow, item: AcpmuxActivity): OwnRow {
  const groups = toolGroups(row.items ?? []);
  const at = groups.findIndex((group) => ("items" in group ? group.items.includes(item) : group.item === item));
  const group = groups[at];
  if (!group || row.foldRun) return undefined;
  if (
    group.type === "item" ||
    group.type === "message" ||
    group.type === "send" ||
    group.type === "sendGroup" ||
    group.type === "subsession" ||
    group.type === "subsessionGroup" ||
    group.type === "agentCall" ||
    group.type === "dispatch" ||
    (group.type === "mcp" && group.items.length === 1)
  )
    return true;
  const kind = group.type === "mcp" ? "mcp" : group.kind;
  const key = `group:${kind}:${(group.type === "mcp" ? group.items[0]!.tool!.id : groupId(group.items)) || `${row.id}:${at}`}`;
  return { key, open: kind !== "mcp" && kind !== "edits" };
}

/// The drawn states of one Codex-style run, each its own version offset so a memoized row redraws
/// on every change between them (App.tsx compares versions): 1 the live latest run, 2 an earlier
/// run, 3 an ended turn's open fold, 4 an earlier run whose running command the live line holds.
const RUN_STATES = 5;

/// A running turn's runs as the Codex desktop app draws them (cx-ncc.108): each run folds into its
/// summary line between the paragraphs ("Read 6 files, ran 4 commands", or one group's "Ran 3
/// commands"), the latest one too as its calls finish, and opens on a click. The call in flight and
/// a thought still coming are not in the run: the turn's live line names them (WorkingFor.tsx
/// `doing`, "Thinking") and each step replaces it in place. A call still running in an earlier run
/// (a background shell) stays in its run, except the command the live line names (`named`,
/// `lineCall`), which reads once, on the line. Each derived row's version moves with its drawn state.
function codexRuns(rows: AcpmuxRow[], named?: string): AcpmuxRow[] {
  // A started chats' card after the run is not a step: the run before it is still in flight.
  let latest = rows.length - 1;
  while (latest > 0 && rows[latest]!.kind === STARTED_SESSIONS) latest -= 1;
  return rows.flatMap((row, index) => {
    if (row.kind !== "activity") return [row];
    // A run that edited folds too, its edits named on the line ("Edited 2 files, read 3 files, ran a
    // command"), as the Codex app collapses a run (Leo 2026-10-22: "this is pretty good ui: … the
    // collapsing i mean"); the turn's edited-files card lists them when it ends. One with a file
    // change still waiting for its permission stays as it is, so the change it asks about stays in
    // sight (an ended turn's folded run keeps it in sight too: TurnRows.tsx `staysInSight`).
    if ((row.items ?? []).some((item) => awaitsPermission(item.tool)))
      return [{ ...row, foldRun: false, version: row.version * RUN_STATES }];
    // An earlier run draws no call that has nothing to show yet; its row comes with its input.
    if (index !== latest)
      return withoutDrafts(row).flatMap((kept) => {
        const items = kept.items ?? [];
        const shown = named === undefined ? items : items.filter((item) => item.tool?.id !== named);
        if (!shown.length) return [];
        // Its version says whether the line holds its command, which moves without the row's, and
        // differs from every other state of the run (`RUN_STATES`).
        const lined = shown.length !== items.length;
        return [
          { ...kept, items: shown, settled: true, foldRun: true, version: row.version * RUN_STATES + (lined ? 4 : 2) },
        ];
      });
    // The latest run: what is happening now leaves it for the live line, so the run holds only
    // finished steps and never grows a stack of live rows (Leo 2026-10-20: "rows pile up instead
    // of replacing each other").
    const all = row.items ?? [];
    const items = all.filter(
      (item, at) => !(item.tool ? isRunning(item.tool) : at === all.length - 1 && item.kind !== "tool"),
    );
    if (!items.length) return [];
    return [{ ...row, items, settled: true, foldRun: true, version: row.version * RUN_STATES + 1 }];
  });
}

/// Narration short enough to fold into the work around it: a short paragraph, under about three
/// lines at the pane's width.
export const SHORT_NOTE_CHARS = 160;
const TAKEAWAY_LINES = 3;
/// A reply that reads as a takeaway, not narration of the work: over about three lines, or with a
/// question, a list, a link, a code block or a second paragraph (Leo, 2026-10-21). Inline code alone
/// does not make one: narration names files and calls ("Reading `client.ts` next."), and that is
/// the work Lawrence asked to collapse; a short note keeps the fold it had before. Another agent's words
/// always are. Shared by the finished turn's final answer and the running turn's runs
/// (``mergeShortNotes``).
export function isTakeaway(row: AcpmuxRow): boolean {
  if (row.kind !== "assistant") return false;
  const text = (row.text ?? "").trim();
  if (!text) return false;
  return (
    Boolean(row.incoming) ||
    text.length > SHORT_NOTE_CHARS ||
    text.split("\n").length > TAKEAWAY_LINES ||
    /\?|```|~~~|\n\s*\n|^\s*(?:[-*+]|\d+[.)])\s|\]\(|https?:\/\//m.test(text)
  );
}
/// A personal steer closes the reply before it for the reader, even though the harness continues the
/// same turn: that segment ends as a turn does (Leo, 2026-10-31: "the delineation is between
/// end-of-turn-that-had-a-steer-between vs otherwise"). The steer and the last reply before it stay in
/// sight: outside a closed "Worked for", and never folded into a run as a quiet note, in a running
/// turn's Codex-style runs, an opened fold, or a Claude turn's groups. Other interim chatter still folds.
export function steerDialogueIn(rows: readonly AcpmuxRow[]): Set<string> {
  const ids = new Set<string>();
  let precedingReply: AcpmuxRow | undefined;
  for (const row of rows) {
    if (isReply(row)) precedingReply = row;
    if (row.kind !== "user") continue;
    if (!row.incoming && continuesTurn(row)) {
      ids.add(row.id);
      if (precedingReply) ids.add(precedingReply.id);
    }
    precedingReply = undefined;
  }
  return ids;
}
const isShortNote = (row: AcpmuxRow | undefined) => row !== undefined && isReply(row) && !isTakeaway(row);
const isRun = (row: AcpmuxRow | undefined) => row?.kind === "activity" && !isEdit(row);

/// Two runs with only a short interim note between them ("Relay the decisions, then answer.") are
/// one stretch of work (Leo 2026-10-20: "it can consolidate a ton of these tool calls"): they draw
/// as one run, the note folded in among its calls as a quiet line (`note` item, TurnRows.tsx). The
/// merged row keeps the first run's id; its version moves with each part's.
/// `keep`: notes that never join a run (a reply before a steer, `steerDialogueIn`). `edits`: a run
/// that edited takes notes too, as Claude desktop's groups do ("Edited 2 files, ran 3 commands").
export function mergeShortNotes(rows: readonly AcpmuxRow[], keep?: ReadonlySet<string>, edits = false): AcpmuxRow[] {
  const run = (row: AcpmuxRow | undefined) => isRun(row) || (edits && row?.kind === "activity");
  const out: AcpmuxRow[] = [];
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    const previous = out.at(-1);
    if (run(previous) && isShortNote(row) && !keep?.has(row.id) && run(rows[index + 1])) {
      const next = rows[index + 1]!;
      out[out.length - 1] = {
        ...previous!,
        items: [...(previous!.items ?? []), { kind: "note", text: row.text!.trim() }, ...(next.items ?? [])],
        toolCount: (previous!.toolCount ?? 0) + (next.toolCount ?? 0),
        joined: [...(previous!.joined ?? [previous!.id]), row.id, next.id],
        version: mixVersion(mixVersion(previous!.version, row.version), next.version),
      };
      index += 1;
    } else out.push(row);
  }
  return out.length === rows.length ? (rows as AcpmuxRow[]) : out;
}

const mixVersion = (a: number, b: number) => (a * 1_009 + b * 7 + 1) % 2_147_483_647;

/// The turn's one "Worked for" fold, keyed by its original prompt. Steers and received reports
/// already related to that turn walk back to the same anchor. An unrelated incoming prompt still
/// opens its own turn, and a pending or failed prompt opens nothing unless it is the first one.
/// A row of a turn the agent ran on its own is behind that turn's line (backgroundTurns.ts), not
/// the "Worked for" before it: Find and a link open the line.
export function turnFoldFor(rows: readonly AcpmuxRow[], index: number): string | undefined {
  const background = rows[index]?.inBackground;
  if (background !== undefined) return backgroundTurnRowId(background);
  // With no accepted prompt before it, the turn is the first one turnView draws, which starts at
  // the first user row (a prompt not sent or refused, or a landed steer a history page starts at,
  // its temporary prompt until the older one is loaded): the earliest one walking back.
  let first: AcpmuxRow | undefined;
  for (let at = Math.min(index, rows.length - 1); at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind === "user" && isUnsent(row)) {
      first = row;
      continue;
    }
    if (opensTurn(row)) return `${WORKED}-${row.id}`;
    if (row.kind === "user" && continuesTurn(row)) first = row;
  }
  return first && `${WORKED}-${first.id}`;
}

/// The keys a click on fold `id` covers: `id`, and when it is a turn's "Worked for", that turn's
/// original prompt's (`key`) and each of its steers' (openFolds reads them all).
function turnFoldKeys(rows: readonly AcpmuxRow[], id: string): { keys: string[]; key?: string } {
  const keys = [id];
  const index = id.startsWith(`${WORKED}-`) ? rows.findIndex((row) => `${WORKED}-${row.id}` === id) : -1;
  const key = index >= 0 ? turnFoldFor(rows, index) : undefined;
  if (key) {
    const start = rows.findIndex((row) => `${WORKED}-${row.id}` === key);
    for (let at = start; at >= 0 && at < rows.length; at += 1) {
      const row = rows[at]!;
      if (at > start && opensTurn(row) && !isUnsent(row)) break;
      if (at === start || continuesTurn(row)) keys.push(`${WORKED}-${row.id}`);
    }
  }
  return { keys, key };
}

/// Toggle at the person's click, clearing provisional steer keys for the same turn too. This
/// keeps a fold opened at a history page's edge closable after the original prompt arrives.
export function toggleTurnFold(rows: readonly AcpmuxRow[], expanded: ReadonlySet<string>, id: string): Set<string> {
  const next = new Set(expanded);
  const { keys, key } = turnFoldKeys(rows, id);
  const open = keys.some((key) => expanded.has(key));
  for (const key of keys) next.delete(key);
  if (!open) next.add(key ?? id);
  return next;
}

/// The same click in Thinking or Verbose, where a turn's "Worked for" is open unless the reader
/// closed it there (viewFolds.ts `toggled`): closing marks every key of the turn, so a steer's key
/// does not hold the fold open; opening clears them all.
export function toggleViewTurnFold(rows: readonly AcpmuxRow[], toggled: ReadonlySet<string>, id: string): Set<string> {
  const next = new Set(toggled);
  const { keys } = turnFoldKeys(rows, id);
  const closed = keys.some((key) => toggled.has(key));
  for (const key of keys) {
    if (closed) next.delete(key);
    else next.add(key);
  }
  return next;
}

/// Open fold `id` in Thinking or Verbose for Find or a link: forget every close of its turn (the
/// original prompt's key and each steer's, as toggleViewTurnFold marks them). The same set back when
/// none was closed. Before (cmux#28782 review at 7e02fd5c), only `id` was forgotten, so a turn with a
/// steer closed by hand stayed closed when a match in it was revealed.
export function openViewTurnFold(
  rows: readonly AcpmuxRow[],
  toggled: ReadonlySet<string>,
  id: string,
): ReadonlySet<string> {
  const { keys } = turnFoldKeys(rows, id);
  if (!keys.some((key) => toggled.has(key))) return toggled;
  const next = new Set(toggled);
  for (const key of keys) next.delete(key);
  return next;
}

/// The folds to open so `rows[index]`, which `drawn` leaves out, draws: its turn's "Worked for"
/// (``turnFoldFor``) when that hides it, and the message run that holds it (messageRuns.ts), which
/// may sit inside that fold. Find, a link and a running line's count open them all.
export function hiddenRowFolds(rows: readonly AcpmuxRow[], drawn: readonly AcpmuxRow[], index: number): string[] {
  const row = rows[index];
  if (!row) return [];
  const line = messageRunFoldFor(drawn, row.id);
  if (line) return [line];
  // A row in a closed run of background-task notifications, or behind a member line of one: the
  // run's line, then the member's own line.
  const behind = row.inBackground === undefined ? undefined : backgroundTurnRowId(row.inBackground);
  const backgroundRun = backgroundRunFoldFor(drawn, row.id) ?? (behind && backgroundRunFoldFor(drawn, behind));
  if (backgroundRun) {
    // A message run inside the member's rows (a send and a read it folded) opens too.
    const inner = messageRunRevealKey(drawn, row);
    return [backgroundRun, ...(behind ? [behind] : []), ...(inner ? [inner] : [])];
  }
  const turn = turnFoldFor(rows, index);
  const run = messageRunRevealKey(drawn, row);
  return [...(turn ? [turn] : []), ...(run ? [run] : [])];
}

/// Where to bring one message of the chat into view (a link's `message=<id>`, links.ts): the first
/// of the message's rows the transcript already draws, else its first row and the "Worked for" fold
/// that hides it. A tool call ends the reply it interrupts, so one message is several rows and only
/// a turn's last one stays outside the fold: a link to a message that worked lands on a folded row,
/// and the fold has to open before the transcript can scroll to it. Undefined when the chat's rows
/// hold none of `messageRows` (another machine's transcript, or history not loaded yet).
export function messageRevealTarget(
  rows: readonly AcpmuxRow[],
  drawn: readonly AcpmuxRow[],
  messageRows: readonly string[],
): { rowId: string; fold?: string; run?: string; also?: string[] } | undefined {
  const places = messageRows.map((id) => rows.findIndex((row) => row.id === id)).filter((at) => at >= 0);
  if (places.length === 0) return undefined;
  const shown = places.find((at) => findRowIndex(drawn, rows[at]!.id) >= 0);
  if (shown !== undefined) return { rowId: rows[shown]!.id };
  const at = places[0]!;
  // The turn's fold first, then the message run inside it (``hiddenRowFolds``).
  // Behind a run of background-task notifications there can be more: the member's line and a
  // message run inside it (`also`).
  const [fold, run, ...also] = hiddenRowFolds(rows, drawn, at);
  return { rowId: rows[at]!.id, fold, ...(run && { run }), ...(also.length > 0 && { also }) };
}

/// The footer of the drawn turn that `rows[from]` is in (the turn's summary row), looking forward
/// from it to the next turn's prompt; a steer drawn inside the turn does not end it.
export function turnFooterFrom(rows: readonly AcpmuxRow[], from: number): string | undefined {
  for (let index = from; index >= 0 && index < rows.length; index += 1) {
    if (index > from && opensTurn(rows[index]!)) return undefined;
    if (rows[index]!.kind === "turnSummary") return rows[index]!.id;
  }
  return undefined;
}

/// A folded copy of an activity row is drawn as tool rows, never as the edited-files card.
export const isFoldedCopy = (row: AcpmuxRow) => row.id.endsWith(FOLDED);
