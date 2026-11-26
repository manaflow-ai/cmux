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
  isLineRow,
  pathKey,
  SINCE_DIVIDER,
  TURN_RETRY,
  type AcpmuxActivity,
  type AcpmuxFileDiff,
  type AcpmuxRow,
  onlyQuietThoughts,
} from "../model";
import type { Folds } from "./viewFolds";
import { continuesTurn, opensTurn } from "../turnStart";
import { AFTER_SEND, findRowIndex } from "./chatFind";
import { cutLongRuns } from "./runParts";
import { keptPrefix, PrefixFilter, noteKeptPrefix } from "./prefixFlatMap";
import { renderCall } from "./renderCall";
import { compactShortTurnsOn } from "./compactShortTurns";
import { hasTimestamp, showsTimestamp, type TurnTimes } from "./timestamps";
import { isRunGroup, isSubagentGroup, WORKFLOW_CARD, SUBAGENT_DONE, SUBAGENT_STARTED } from "../subagents/subagentRows";
import { STARTED_SESSIONS } from "../started/startedSessions";
import type { LiveWait } from "./liveWait";
import { PLAN_BUILD_KIND } from "../planBuild/planBuild";
import { QUESTION_RECORD } from "../question/record";
import { answerOf, chosenAnswer, nextStepAsk, pickedAnswer, type NextStepAsk } from "./nextStepAsk";
import { lastWrapUp, withoutWrapUp, execWrapUp, isWrapUp, wrapUpAsk } from "./wrapUp";
import { lastWalkthrough } from "./walkthroughModel";
import type { Translate } from "../i18n";
import { editedPaths, isBareShellName, toolLabel } from "../toolPaths";
import { scriptNoun, commandLine, commandSaid } from "./commandActions";
import { awaitsPermission, isDraftCall, isRunning, toolGroups, countsFailed } from "./toolGroups";
import { toolRunPhrases } from "./toolRunSummary";
import { acpmuxMcpSends } from "./acpmuxMcpSends";
import { acpmuxSendCalls } from "./acpmuxSends";
import { subsessionCall } from "./subsessionCalls";
import { experimentArm } from "../../../experiments/experiment";
import { finishedTaskLook } from "./taskLine.experiment";
import { liveTurnWork } from "./liveTurnWork.experiment";
import { turnFoldReplies } from "./turnFoldReplies.experiment";
import { liveTurnClock } from "./liveTurnClock.experiment";
import { turnFoldSteered } from "./turnFoldSteered.experiment";
import { waitingMessagesOrder } from "./waitingMessagesOrder.experiment";
import { workedLine } from "./workedLine.experiment";
import { workedForMessages } from "./workedForMessages.experiment";
import { bareWorkedTurns } from "./bareWorkedTurns.experiment";
import { inboxCounts } from "./inboxNotice";
import { startedTasks, startsTask, TASK_LINE } from "./taskLines";
import { isWaitingMessage } from "./pendingMessages";
import { appendLaneNotice } from "./laneNoticeBatches";
import { agentMessage } from "./agentMessages";
import { turnCopyParts, turnCopySaid, turnCallParts } from "./turnCopy";
import { turnEndActions } from "./turnEndActions.experiment";
import { turnWork } from "./waterfallSpans";
import { isVisiblyEmptyMessage, isVisiblyEmptyText } from "./visibleMessage";
import { agentCall } from "./agentCalls";
import { hidesEveryCall } from "./mcpPresentation";
import { isThought, isQuietThought, thoughtDuration } from "./thoughts";
import { SILENT_MS } from "./thinkingModel";
import {
  BACKGROUND_TURN,
  backgroundTurnRowId,
  foldBackgroundTurns,
  foldedBackgroundIds,
  hiddenInBackground,
  openBackgroundTurns,
  endsDrawingRows,
  foldedWithoutWork,
} from "./backgroundTurns";
import {
  foldMessageRuns,
  messageRunFoldFor,
  messageRunRevealKey,
  messageRunRowId,
  openMessageRuns,
} from "./messageRuns";
import { backgroundRunFoldFor, backgroundRunRowId, foldBackgroundRuns, openBackgroundRuns } from "./backgroundRuns";
import { turnFoldStyle, type TurnFoldStyle, CLAUDE_IN_PLACE } from "./turnFoldStyle";
import { resendsAttachments } from "../inlinePrompt";
import { answerClaim, askKey, CLAIM_SLACK_MS } from "./waitingAskStore";
import { canonicalCall } from "../toolNames";
import { currentLanguage, translatorFor } from "../i18n";
import { writeCall } from "./writeLabelModel";
import { oneRowPerCall } from "./oneRowPerCall.experiment";
import { MEMORY_OFFER } from "./memoryInbox";
import { PROMPT_COACH } from "./promptCoach";
import { PRESET_APPROVAL } from "./presetApproval";
import { githubConnectNeed } from "./githubConnect";

/// A row added by this pass: the "Worked for" disclosure of the turn opened by `turnId`.
export const WORKED = "worked";
/// A stopped turn opens by default; this stored choice records the reader closing it.
export const CLOSED_TURN_FOLD = "closed:";
/// A row added by this pass: the timestamp line over a turn (timestamps.ts).
export const DATE = "date";
/// Rows added for the turn still running: "Thinking" until it has output, then a ticking
/// "Working for 42s" line over its work, where "Worked for" lands when the turn ends.
export const THINKING = "thinking";
/// The last turn's Thinking line has one id from send to the first output: the sent prompt's row
/// changes id when acpmux echoes it, the line keeps its place (cx-ncc.58).
/// The running turn's line, its last row from the send to the turn's end (turnEndFold.ts reads it).
export const LIVE_THINKING = `${THINKING}-live`;
/// The frame a running turn's line draws in (model.ts `rowFrameKey`): one per prompt, so the line
/// keeps its element from the send through the turn (the prompt's acpmux id, the same before and
/// after acpmux's echo renames its row), and the next prompt's turn draws a line of its own. One
/// frame for every turn carried a /compact's "Compacting conversation" line on as the queued
/// prompt's "Thinking" line: that element moved down the room the queue card left, a layout shift
/// of a row on screen (snappy-bench mid_compaction).
export function liveLineFrame(prompt: AcpmuxRow): string {
  const id = prompt.promptId ?? (prompt.id.startsWith("local-") ? prompt.id.slice("local-".length) : prompt.id);
  return `${LIVE_THINKING}:${id}`;
}
/// The older live line at a running turn's bottom (`below`, WorkingFor.tsx). The running turn's header
/// over its work is a WORKED row in its running phase (`turnHeaderId`), never this kind.
export const WORKING = "working";
/// A row added for each render call of an ended turn (renderCall.ts), above its answer: the
/// render card, with the call as its one item.
export const RENDER = "render";
/// A row added for an ended turn whose answer ends on one tagged ask (nextStepAsk.ts): the ask as a
/// card with its answers as buttons (NextStepCard.tsx), right under the answer, which drops the
/// ask's lines. Its `nextStep` carries the ask; `settleNextSteps` adds the answer a later prompt
/// picked, or folds it once a later card takes over.
export const NEXT_STEP = "nextStep";
/// A row added for an ended turn that ran a browser walkthrough (walkthroughModel.ts, `verifyFlow`): its
/// last one as a pass/fail strip of screenshots (Walkthrough.tsx), under the answer, before any
/// next-step card. Its `walkthrough` carries the steps.
export const WALKTHROUGH = "walkthrough";
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

/// A turn's time on its "Worked for" / "Working for" line: as `formatDuration`, but "<1s" under one
/// second, never "0s" (Leo, 2026-11-25, on the line that read 0s: "let's just fix forward and improve
/// it all"). The running line reads "Working for <1s" from its first frame, so its words keep one shape
/// from the prompt to "Worked for": no "Working" that swaps to a time, and no fold that vanishes at
/// the end because the turn was quick.
export function turnSpan(ms: number): string {
  return ms < 1000 ? "<1s" : formatDuration(ms);
}

/// A finished span's own time: "856ms" under a second, else as `formatDuration`; none for a span
/// whose start and end were stamped at one moment, which measured nothing, so no row reads a
/// floored "0s" (Leo, 2026-11-05: "it always only shows 0s?").
export function spanDuration(t: Translate, ms: number): string | undefined {
  if (!(ms > 0)) return undefined;
  return ms < 1000 ? t("duration.ms", { n: Math.round(ms) }) : formatDuration(ms);
}

export const toolCalls = (t: Translate, count = 0) => t("turn.toolCalls", { n: count });

/// How a turn's time reads, by how the turn ended: a turn that died on an API error (a 429, a
/// capacity refusal) says so, never "Worked for" (Leo's coordinator looped on 429s for hours and
/// every dead turn read as work). `turnTimeKey` is the same choice for a label that draws the time
/// itself (TurnRows.tsx WorkedLabel's TimedLabel).
export function turnTimeKey(row: AcpmuxRow): "turn.failedAfter" | "turn.stopped" | "turn.worked" {
  if (row.status === "failed" || row.status === "error") return "turn.failedAfter";
  if (row.status === "cancelled" || row.status === "interrupted") return "turn.stopped";
  return "turn.worked";
}

const turnTimeLabel = (t: Translate, row: AcpmuxRow, time: string) => t(turnTimeKey(row), { time });

/// The disclosure's label: "Worked for 1m 16s", "Failed after 40s", "You stopped after 40s",
/// or "34 previous messages" for a Codex fold that mixes the agent's messages with its work
/// (`foldMixesMessages`). It shows no tool-call count. With no time it counts the calls instead, and
/// with no calls either it says nothing: never "0 tool calls" (cmux#54927, on a finished turn whose
/// only row was a subagent's end: "this 0 tool calls thing is a tad bit weird").
export function workedLabel(t: Translate, row: AcpmuxRow): string {
  if (row.previous !== undefined)
    return row.previous === 1 ? t("turn.previous.one") : t("turn.previous.other", { n: row.previous });
  if (row.durationMs === undefined) {
    const messages = workedMessagesText(t, row);
    if (row.toolCount) return toolCalls(t, row.toolCount) + messages;
    return messages.slice(t("toolRun.separator").length);
  }
  const time = turnSpan(row.durationMs);
  return turnTimeLabel(t, row, time) + workedCallsText(t, row) + workedMessagesText(t, row);
}

/// " · 14 tool calls" after a finished turn's time when its family counts them (`workedCalls`), else "".
export function workedCallsText(t: Translate, row: AcpmuxRow): string {
  return row.workedCalls ? t("turn.workedCalls", { calls: toolCalls(t, row.workedCalls) }) : "";
}

/// The Settings > Advanced > Experiments switch (`experiments.foldSummaryCounts`, off by default)
/// that has a closed "Worked for" say what it hides: "Worked for 36s · ran 4 commands, edited 2 files".
/// Off, the line is the time alone, as before.
export const FOLD_COUNTS_SWITCH = "foldSummaryCounts";

/// What a "Worked for" hides (`foldCalls`), as the tool runs name it (toolRunSummary.ts
/// `toolRunPhrases`: "ran 4 commands", "edited 2 files", lower case, in the order the turn first did
/// each) joined by the runs' separator, and how many of those calls failed (the runs' "1 failed",
/// FailedCount.tsx). Undefined when it hides no call.
export function workedCountsText(t: Translate, row: AcpmuxRow): { text: string; failed: number } | undefined {
  const calls = row.foldCalls;
  if (!calls?.length) return undefined;
  const phrases = toolRunPhrases(t, calls);
  if (!phrases.length) return undefined;
  const failed = calls.filter((item) => countsFailed(item.tool!)).length;
  return { text: phrases.join(t("toolRun.separator")), failed };
}

/// ", sent a message, received 2 messages" after a "Worked for" that names the messages between
/// agents it folds (`workedMessages`, the `messages` arm of workedForMessages.experiment.ts), else "".
export function workedMessagesText(t: Translate, row: AcpmuxRow): string {
  const counts = row.workedMessages;
  if (!counts) return "";
  const phrases = [
    ...(counts.sent
      ? [counts.sent === 1 ? t("messageRun.sent.one") : t("messageRun.sent.other", { n: counts.sent })]
      : []),
    ...(counts.received
      ? [counts.received === 1 ? t("messageRun.received.one") : t("messageRun.received.other", { n: counts.received })]
      : []),
  ];
  return phrases.map((phrase) => t("toolRun.separator") + phrase).join("");
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
  return (footerSays(row) && workedLabel(t, row)) || undefined;
}
const footerSays = (row: AcpmuxRow) =>
  !row.folded &&
  (row.previous !== undefined || row.durationMs === undefined || row.durationMs >= 1000 || row.status === "cancelled");

/// A footer with nothing to show at rest and only hover controls (Pin, Fork, its time): no answer to
/// copy or read aloud and the turn did not fail. A stopped turn resumes from the composer.
/// Its "Worked for" label is the time's tooltip now,
/// never a word in the row (TurnRows.tsx TurnFooter), so it no longer keeps the line. It takes no line in the transcript
/// (conversation.css `.cv-turn-actions--empty`, model.ts fallbackRowHeight); pointed at, its controls
/// show over the turn gap below, so nothing moves.
///
/// A finished turn that spoke and then ended on work, with no reply after its last call, is not
/// empty, whether or not a prompt came after it: its row with Copy (the whole turn, turnCopy.ts)
/// stays, as ChatGPT's does under every finished turn (Leo, 2026-11-02: "the latest copy buttons auto
/// showing when the turn is done like chatgpt"). It used to be kept only while the turn was the
/// chat's last (`retryable`), so the row vanished, and the transcript jumped by its height, the
/// moment the next prompt went; and a turn paged in from history without its prompt drew none until
/// the prompt came (Leo, 2026-11-14: "the copy sometimes disappears entirely? which causes big
/// shifts. it happens often when scrolling up and stuff loads"). A turn that only ran calls is not
/// empty either: its row copies them (turnCopy.ts), as every finished turn ends on its row (G04: such
/// a turn ended on a bare "Worked for", no Copy and no done mark). A footer that is empty never
/// carries Retry: the prompt keeps it (`retryPlacement`).
export const isEmptyFooter = (row: AcpmuxRow) =>
  row.kind === "turnSummary" &&
  row.status !== "failed" &&
  row.status !== "error" &&
  !row.text &&
  !row.githubConnect &&
  !endsOnWork(row);

/// The footer with the person's last prompt to send again (TurnRows.tsx TurnFooter's Retry): the
/// chat's last turn, or the last one a prompt opened when every turn after it came from a notice
/// or a reminder (`retryTarget`). transcriptGrid.ts rowMark and model.ts isBlankFooter repeat it inline.
/// An attachment-only prompt's footer carries an empty `prompt` (its attachments are what goes
/// again, by `retryRowId`), so a defined `prompt` is what offers it.
export const offersRetry = (row: AcpmuxRow) =>
  row.retryTarget === true && row.prompt !== undefined && Boolean(row.retryRowId);

/// A prompt row that drew its own Retry on base, before Retry moved to the reply footer (cmux#34779),
/// taken over unchanged: the row UserBubble draws (the person's own prompt: no `incoming`, not a
/// `received` result; App.tsx's registry draws those as message cards), with its footer (not
/// `failed`), not `pending` and not still sending, with text to send (`resend`, else `text`) or, as
/// PromptRetry's `hasAttachment`, attachments that can all go again (``resendsAttachments``). Whether
/// the chat can send and the reader may act are ``retryPlacement``'s (base: PromptRetry's `retry` and
/// read-only checks). Only which row draws Retry moved; which prompts can be retried did not.
export const isRetryablePrompt = (row: AcpmuxRow) =>
  row.kind === "user" &&
  !row.incoming &&
  row.received === undefined &&
  !row.failed &&
  !row.pending &&
  row.delivery?.state !== "sending" &&
  (Boolean(row.resend ?? row.text) || resendsAttachments(row));

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

/// A turn's footer when the turn said something and ended on work (`isEmptyFooter` above), the chat's
/// last turn or not. transcriptGrid.ts rowMark and model.ts isBlankFooter repeat it inline (those
/// modules cannot import this one).
export const endsOnWork = (row: AcpmuxRow) => (row.turnCopy?.length ?? 0) > 0;

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
/// computer's clock, so its "Working for" counts from the prompt. `turnStartedAtMs` (the snapshot's)
/// is the live turn's own start, which differs from the prompt when a resumed turn still opens with
/// an older prompt.
export function turnView(
  rows: readonly AcpmuxRow[],
  expanded: Folds,
  options: {
    now?: number;
    working?: boolean;
    clockOffset?: number;
    turnStartedAtMs?: number;
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
  turnStartedAtMs?: number;
  agentFamily?: string;
  working: boolean;
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
  /// Each boundary keeps its count and last row before the next prompt extends a fold, and the row
  /// before it (`before`): a joined "Worked for" ends on its last turn's footer, so a join replaces both.
  /// `openRun`: the opened joined "Worked for" (`joinBareWorked`) whose turns go on past this one.
  ends: { count: number; row: AcpmuxRow | undefined; before?: AcpmuxRow; visible?: number; openRun?: string }[];
  /// Where each next-step card is in `rows`, with the row as its turn shaped it
  /// (`settleNextSteps`).
  nextSteps: NextStepAt[];
  /// Where each failed turn's summary is in `rows`, and the last turn summary that completed
  /// (`markRecovered`), -1 for none.
  failures: number[];
  lastCompleted: number;
  rows: AcpmuxRow[];
};

/// ``turnView``, building on `previous`: the turns before the one holding the first row that
/// differs from `previous.source` (by object) keep their drawn rows, so a long chat's snapshot
/// shapes only its last turns.
const NO_MESSAGE_BREAKS: readonly number[] = [];
const NO_PENDING: readonly AcpmuxRow[] = [];

const sameIds = (a: ReadonlySet<string>, b: ReadonlySet<string>) =>
  a.size === b.size && [...a].every((id) => b.has(id));

/// A refresh can publish a tool row before the assistant body that was already on screen. Keep
/// that settled body in the source until a later snapshot carries it again, so shaping cannot turn
/// a visible reply into a tool-only "Worked for" line during the gap. The replies it keeps are the
/// visible assistant rows of `previous` from the first changed row on, read from those rows: no set
/// of every reply id in the chat is copied per update (a god chat's thousands of replies made each
/// streamed token cost more the longer the chat, CMUX-571).
///
/// A reply older than `heldFromAt` (the oldest record the chat holds) is not in a gap: the chat let go of it with its
/// records (direct.ts `shedOlderHeld`), and it stays gone. Kept, a running turn that never ends put back every reply
/// it ever streamed: each snapshot's source held the last one's kept replies, so the turn's drawn rows grew with
/// every record (chat-100k-flat running_x1: 34,000 drawn rows over a chat holding 1,300, and every row's caches).
const retainVisibleReplies = (
  rows: readonly AcpmuxRow[],
  previous: readonly AcpmuxRow[] | undefined,
  supersededReplyIds: ReadonlySet<string> | undefined,
  heldFromAt = Number.NEGATIVE_INFINITY,
): readonly AcpmuxRow[] => {
  if (!previous) return rows;
  const changedAt = Math.max(0, keptPrefix(previous, rows) - 1);
  const changedRows = rows.slice(changedAt);
  if (!changedRows.some((row) => row.kind === "activity")) return rows;
  const currentIds = new Set(changedRows.map((row) => row.id));
  const missingReplyIds = new Set<string>();
  for (let index = changedAt; index < previous.length; index += 1) {
    const row = previous[index]!;
    if (
      row.kind === "assistant" &&
      row.at >= heldFromAt &&
      !supersededReplyIds?.has(row.id) &&
      !isVisiblyEmptyMessage(row)
    )
      missingReplyIds.add(row.id);
  }
  for (const row of changedRows)
    if (row.kind === "assistant" && !isVisiblyEmptyMessage(row)) missingReplyIds.delete(row.id);
  if (missingReplyIds.size === 0) return rows;
  const firstAt = changedRows[0]?.at ?? Number.POSITIVE_INFINITY;
  let start = 0;
  let high = previous.length;
  while (start < high) {
    const middle = (start + high) >> 1;
    if (previous[middle]!.at < firstAt) start = middle + 1;
    else high = middle;
  }
  while (start > 0 && previous[start - 1]!.kind !== "user") start -= 1;
  const relevant = previous.slice(start);
  const previousById = new Map(relevant.map((row) => [row.id, row]));
  const hasEmptyReplacement = changedRows.some(
    (row) =>
      row.kind === "assistant" &&
      isVisiblyEmptyMessage(row) &&
      previousById.get(row.id)?.kind === "assistant" &&
      !isVisiblyEmptyMessage(previousById.get(row.id)!),
  );
  if (missingReplyIds.size === 0 && !hasEmptyReplacement) return rows;
  const retainIds = new Set<string>();
  const retainedOrder = new Map<string, number>();
  let segmentStart = 0;
  let anchored = false;
  const finishSegment = (end: number) => {
    if (anchored)
      for (let index = segmentStart; index < end; index += 1) {
        const row = relevant[index]!;
        if (row.kind === "assistant" && missingReplyIds.has(row.id)) {
          retainIds.add(row.id);
          retainedOrder.set(row.id, index);
        }
      }
  };
  for (let index = 0; index <= relevant.length; index += 1) {
    const row = relevant[index];
    if (index === relevant.length || (row?.kind === "user" && index !== segmentStart)) {
      finishSegment(index);
      segmentStart = index;
      anchored = false;
    }
    if (row && row.kind !== "assistant" && currentIds.has(row.id)) anchored = true;
  }
  let changed = false;
  const replacedIds = new Set<string>();
  const next = rows.map((row) => {
    const prior = previousById.get(row.id);
    if (
      row.kind === "assistant" &&
      prior?.kind === "assistant" &&
      !isVisiblyEmptyMessage(prior) &&
      isVisiblyEmptyMessage(row) &&
      retainIds.has(row.id)
    ) {
      changed = true;
      replacedIds.add(row.id);
      return prior;
    }
    return row;
  });
  for (const row of relevant) {
    if (row.kind === "assistant" && retainIds.has(row.id) && !replacedIds.has(row.id)) {
      next.push(row);
      changed = true;
    }
  }
  if (!changed) return rows;
  return next.sort(
    (a, b) =>
      a.at - b.at ||
      (retainedOrder.get(a.id) ?? Number.POSITIVE_INFINITY) - (retainedOrder.get(b.id) ?? Number.POSITIVE_INFINITY),
  );
};

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
    turnStartedAtMs,
    agentFamily,
    waitingSteers,
    messageBreaks = NO_MESSAGE_BREAKS,
    trayAgents = 0,
    supersededReplyIds,
    heldFromAt,
  }: {
    now?: number;
    working?: boolean;
    clockOffset?: number;
    turnStartedAtMs?: number;
    agentFamily?: string;
    /// The steers the agent has not read yet (snapshot `waitingSteers`), one array while they hold.
    waitingSteers?: readonly string[];
    /// Sorted insertion times of synthetic rows that must separate received message runs.
    messageBreaks?: readonly number[];
    /// The running turn's foreground subagents still running, counted by the caller when the
    /// running tray took their groups out of `rows` (runningTray.ts `withSubagentLines`), so the
    /// live line still reads "Waiting on 2 subagents" (``trayWaitAgents``).
    trayAgents?: number;
    /// Reply row ids explicitly removed by a message_superseded event; refresh retention must not resurrect them.
    supersededReplyIds?: ReadonlySet<string>;
    /// The time of the oldest record the chat holds (snapshot `heldFromAt`): refresh retention keeps no reply older.
    heldFromAt?: number;
  } = {},
  previous?: TurnView,
  /// At most this many of `previous`'s turns are reused (a Retry that moved onto or off one of them).
  reuseAtMost = Number.POSITIVE_INFINITY,
): TurnView {
  if (
    previous &&
    previous.source === rows &&
    previous.expanded === expanded &&
    previous.clockOffset === clockOffset &&
    previous.turnStartedAtMs === turnStartedAtMs &&
    previous.agentFamily === agentFamily &&
    previous.messageBreaks === messageBreaks &&
    previous.working === working &&
    previous.waitingSteers === waitingSteers &&
    previous.trayAgents === trayAgents &&
    firstDateUnchanged(previous, now)
  )
    return previous;
  const retainedRows = retainVisibleReplies(rows, previous?.source, supersededReplyIds, heldFromAt);
  if (retainedRows !== rows)
    return turnViewFrom(
      retainedRows,
      expanded,
      {
        now,
        working,
        clockOffset,
        turnStartedAtMs,
        agentFamily,
        waitingSteers,
        messageBreaks,
        trayAgents,
        supersededReplyIds,
        heldFromAt,
      },
      previous,
    );
  // The turn to shape from: the one holding the first changed row. The turn before it may
  // have ended there, and the last turn draws differently once another follows it.
  const reuseFoldedBackground = previous?.source === rows && previous.expanded === expanded;
  // Read over the background turns alone, from a pass that reads only the rows a snapshot changed
  // (prefixFlatMap.ts): every row of a long chat was read for them on each event.
  const foldedBackground = reuseFoldedBackground
    ? previous!.foldedBackground
    : foldedBackgroundIds(backgroundTurnRows.read(rows).items, expanded);
  let reuse = 0;
  if (
    previous &&
    previous.expanded === expanded &&
    previous.clockOffset === clockOffset &&
    previous.agentFamily === agentFamily &&
    previous.messageBreaks === messageBreaks &&
    previous.starts.length
  ) {
    const shared = previous.source;
    if (rows === shared) reuse = previous.starts.length;
    else {
      const from = keptPrefix(shared, rows);
      // The turns that start before it (`starts` ascends): a long chat holds thousands.
      let high = previous.starts.length;
      while (reuse < high) {
        const middle = (reuse + high) >> 1;
        if (previous.starts[middle]! < from) reuse = middle + 1;
        else high = middle;
      }
    }
    reuse = Math.max(0, reuse - 1);
  }
  reuse = Math.min(reuse, reuseAtMost);
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
  let failures: number[];
  let lastCompleted: number;
  if (reuse > 0) {
    lead = previous!.lead;
    index = previous!.starts[reuse]!;
    const boundary = previous!.ends[reuse - 1];
    reusedRows = Math.max(0, (boundary?.count ?? 0) - 1);
    out = previous!.rows.slice(0, boundary?.count);
    if (boundary?.row && out.length) out[out.length - 1] = boundary.row;
    if (boundary?.before && out.length > 1) out[out.length - 2] = boundary.before;
    starts = previous!.starts.slice(0, reuse);
    times = previous!.times.slice(0, reuse);
    dated = previous!.dated.slice(0, reuse);
    ends = previous!.ends.slice(0, reuse);
    nextSteps = previous!.nextSteps.filter((card) => card.at < out.length);
    failures = previous!.failures.filter((at) => at < out.length);
    lastCompleted = previous!.lastCompleted < out.length ? previous!.lastCompleted : -1;
  } else {
    out = [];
    index = 0;
    // Rows before the first prompt (a greeting, or history paged in mid-turn) draw as they are,
    // a quiet turn the agent ran on its own folded to its line (backgroundTurns.ts).
    while (index < rows.length && rows[index]!.kind !== "user") {
      const row = rows[index++]!;
      if (!isVisiblyEmptyMessage(row)) out.push(row);
    }
    // A turn paged in without its prompt ends on acpmux's bare summary, which carries no answer: its
    // footer gets its reply and its turn to copy here, as `shapeTurn` gives them once the prompt
    // pages in, so its action row is there from the start and paging the prompt in moves nothing
    // (Leo, 2026-11-14: "it happens often when scrolling up and stuff loads").
    out = foldBackgroundRuns(foldBackgroundTurns(withTailAnswers(out, NO_ENDED_BACKGROUND), expanded), expanded);
    lead = index;
    starts = [];
    times = [];
    dated = [];
    ends = [];
    nextSteps = [];
    // A failed turn paged in without its prompt is tracked too, so a later turn recovers it.
    failures = [];
    lastCompleted = -1;
    out.forEach((row, at) => {
      if (isFailed(row)) failures.push(at);
      else if (row.kind === "turnSummary" && row.status === "completed") lastCompleted = at;
    });
  }
  const first = starts.length;
  // The cards before the last reused one keep their state: what follows each, up to the next card,
  // is reused too.
  const keptCards = nextSteps.length;
  let firstVisible =
    previous?.firstVisible !== undefined && previous.firstVisible < first ? previous.firstVisible : undefined;
  let visible = ends.at(-1)?.visible;
  let openRun = ends.at(-1)?.openRun;
  const bareArm = experimentArm(bareWorkedTurns);
  const arms = turnArms(agentFamily);
  const fromStart = lead === 0;
  const pending: AcpmuxRow[] = [];
  // Unread messages from other agents go to the end group only in its arm; in `arrival` they draw at
  // their `seq` like the person's steer.
  const groupWaiting = experimentArm(waitingMessagesOrder) === "group";
  // Each turn is its prompt's index up to the next accepted prompt: its rows, and any prompt not
  // yet accepted (sent while this turn runs, or refused), which sorts among them by its send time
  // and neither ends the turn nor folds into it. A steer goes on with the turn it went into
  // (``continuesTurn``). Indexes, not arrays: a long chat's snapshot only copies the rows of a
  // turn that changed (shapedTurn).
  while (index < rows.length) {
    const start = index++;
    let answerAt: number | undefined;
    while (
      index < rows.length &&
      (rows[index]!.kind !== "user" || isUnsent(rows[index]!) || continuesTurn(rows[index]!))
    ) {
      if (isAnswer(rows[index]!)) answerAt = rows[index]!.at;
      index += 1;
    }
    starts.push(start);
    const turn = { promptAt: rows[start]!.at, answerAt };
    times.push(turn);
  }
  const retryAt = retryTargetAt(rows, starts);
  // Reused turns were drawn with the previous view's folds. A row after them can change which
  // background turns fold (cmux#30535), so a different set draws every turn again. A Retry that
  // moves off or onto a reused turn (`retryTargetAt`) draws that turn again, and the ones after it.
  const retryMoved =
    reuse > 0 && retryAt !== previous!.retryAt && [retryAt, previous!.retryAt].some((at) => at >= 0 && at < first);
  if (reuse > 0 && !sameIds(foldedBackground, previous!.foldedBackground))
    return turnViewFrom(rows, expanded, {
      now,
      working,
      clockOffset,
      turnStartedAtMs,
      agentFamily,
      waitingSteers,
      messageBreaks,
      trayAgents,
      supersededReplyIds,
    });
  // A Retry that moved shapes again from the turn it moved onto or off, not the whole chat: each
  // prompt after another agent's turn (which offers none) moves it off the turn before that one.
  if (retryMoved)
    return turnViewFrom(
      rows,
      expanded,
      {
        now,
        working,
        clockOffset,
        turnStartedAtMs,
        agentFamily,
        waitingSteers,
        messageBreaks,
        trayAgents,
        supersededReplyIds,
      },
      previous,
      Math.min(...[retryAt, previous!.retryAt].filter((at) => at >= 0 && at < first)),
    );
  for (let at = first; at < starts.length; at += 1) {
    const start = starts[at]!;
    const end = at + 1 < starts.length ? starts[at + 1]! : rows.length;
    // Only the last turn can still be running.
    const last = at === starts.length - 1;
    const live = working && last;
    dated[at] = showsTimestamp(times[at]!, visible === undefined ? undefined : times[visible], now, fromStart);
    // A quiet background turn that draws work keeps its answer in sight (`foldedWithoutWork`).
    const turnFolded = foldedWithoutWork(rows, start + 1, end, foldedBackground);
    const shaped = shapedTurn(
      rows,
      start,
      end,
      expanded,
      live,
      last,
      clockOffset,
      dated[at]!,
      agentFamily,
      turnFolded,
      live ? trayAgents : 0,
      at === retryAt,
      live ? turnStartedAtMs : undefined,
      arms,
    );
    // Other sessions' messages the agent read stay each its own line where it read them
    // (IncomingMessageCard.tsx). One it has not read yet (a steer that waits for its step) leaves
    // the running turn for the one group of waiting messages at the end (pendingMessages.ts), unless
    // it keeps its arrival place (waitingMessagesOrder.experiment.ts `arrival`).
    // Reuse batches while tokens change: only a newly arrived notice computes a new descriptor.
    // The boundary is this turn; unrelated rows and report/inbox kind changes end a batch.
    let drawn: AcpmuxRow[] = [];
    for (const row of shaped) {
      // The local turn may contain a late done line whose background owner is in a prior
      // prompt. Its original background line still controls disclosure of that completion.
      if (hiddenInBackground(row, turnFolded)) continue;
      if (last && groupWaiting && isWaitingMessage(row)) pending.push(row);
      else appendLaneNotice(drawn, row);
    }
    // A turn that drew only its closed "Worked for" (a wake or another agent's message that the
    // agent answered with tools alone) joins the bare line of the turn before it: five such turns
    // read as one "Worked for", not a stack of lines with nothing between them (Austin's chat,
    // 2026-11-17; Leo: "we sometimes have weird ui like this").
    // Opened, the joined line's turns each draw their own open line, all closing with any of them.
    // A turn of calls alone ends on its footer (its calls to Copy, G04); the joined line keeps the
    // last such footer under it, so the run still reads as one line and ends on one row.
    const bareTurn = bareArm === "separate" ? undefined : bareWorked(drawn, arms.steeredArm === "header");
    const bare = bareTurn?.worked;
    if (bare && bareArm === "hidden") {
      ends.push({ count: out.length, row: out.at(-1), before: out.at(-2), visible });
      continue;
    }
    const run = openRun;
    openRun = undefined;
    if (bare && run) {
      const own = `${WORKED}-${rows[start]!.id}`;
      const opened: Folds = {
        has: (key) => key === bare.id || key === own || expanded.has(key),
        size: expanded.size + 1,
      };
      drawn = [];
      const shapedOpen = shapedTurn(
        rows,
        start,
        end,
        opened,
        live,
        last,
        clockOffset,
        dated[at]!,
        agentFamily,
        turnFolded,
        0,
        at === retryAt,
        undefined,
        arms,
      );
      for (const row of shapedOpen) {
        if (hiddenInBackground(row, turnFolded)) continue;
        if (last && groupWaiting && isWaitingMessage(row)) pending.push(row);
        else appendLaneNotice(drawn, row.kind === WORKED && row.foldOpen ? inWorkedRun(row, [run], run) : row);
      }
      openRun = run;
    } else if (bare) {
      // The joined line, or the joined line and the footer of its last turn under it.
      const footed = out.at(-1)?.kind === "turnSummary" && out.at(-2)?.workedRun !== undefined ? 1 : 0;
      const tail = out.at(-1 - footed);
      if (tail?.workedRun && !tail.foldOpen && out.length === (ends.at(-1)?.count ?? -1)) {
        const footer = bareTurn.footer ?? (footed ? out.at(-1) : undefined);
        out.splice(out.length - 1 - footed, 1 + footed, joinedBareWorked(tail, bare), ...(footer ? [footer] : []));
        ends.push({ count: out.length, row: out.at(-1), before: out.at(-2), visible: at });
        visible = at;
        firstVisible ??= at;
        continue;
      }
      drawn = [inWorkedRun(bare, [bare.id]), ...(bareTurn.footer ? [bareTurn.footer] : [])];
    } else {
      const head = drawn.findIndex(
        (row) => row.kind === WORKED && row.foldOpen && expanded.has(workedRunOpenKey(row.id)),
      );
      if (head >= 0) {
        openRun = drawn[head]!.id;
        drawn = drawn.map((row, index) => (index === head ? inWorkedRun(row, [row.id]) : row));
      }
    }
    // Invisible turns cannot consume a gap or the first visible turn's age threshold. Store
    // the preceding visible turn at each reusable boundary, avoiding a history scan per token.
    if (drawn.some((row) => row.kind !== DATE && !isVisiblyEmptyMessage(row))) {
      firstVisible ??= at;
      visible = at;
    } else dated[at] = false;
    for (const row of drawn) {
      if (row.kind === NEXT_STEP && row.nextStep) nextSteps.push({ at: out.length, row });
      else if (isFailed(row)) failures.push(out.length);
      else if (row.kind === "turnSummary" && row.status === "completed") lastCompleted = out.length;
      out.push(row);
    }
    ends.push({ count: out.length, row: out.at(-1), before: out.at(-2), visible, ...(openRun && { openRun }) });
  }
  // A reused card a later one now supersedes changed: the unchanged prefix ends before it.
  // From the last kept card, back over the cards still waiting on the person or answered out of
  // order: a click on an older pinned card settles it, so the waiting run is settled again.
  let settleFrom = Math.max(0, keptCards - 1);
  while (settleFrom > 0 && (!nextSteps[settleFrom - 1]!.spoke || nextSteps[settleFrom - 1]!.outOfOrder))
    settleFrom -= 1;
  reusedRows = Math.min(reusedRows, settleNextSteps(out, nextSteps, settleFrom));
  reusedRows = Math.min(reusedRows, markRecovered(out, failures, lastCompleted));
  // The drawn rows start with `previous.rows`' first `reusedRows`, but for the two the reused
  // boundary put back (a later joined "Worked for" can have replaced them since): said so, the
  // passes after this one (the transcript's layout, the rail, Find) read only the rows after them.
  if (reuse > 0 && reusedRows > 0) {
    let kept = reusedRows;
    for (let at = Math.max(0, kept - 2); at < kept; at += 1)
      if (out[at] !== previous!.rows[at]) {
        kept = at;
        break;
      }
    noteKeptPrefix(out, previous!.rows, kept);
  }
  return {
    source: rows,
    expanded,
    clockOffset,
    turnStartedAtMs,
    agentFamily,
    working,
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
    failures,
    lastCompleted,
    rows: out,
  };
}

/// Each failed turn's summary a later completed turn follows, marked `recovered`: the chat went on
/// after it (Continue, a fork of it, a new message), so its error card is history, not a problem to
/// act on, and no longer draws (cmux#48434: "if i somehow continue the chat ... and it works i
/// shouldnt see this dialog again"). Returns the first index whose row it changed, or Infinity.
function markRecovered(out: AcpmuxRow[], failures: readonly number[], lastCompleted: number): number {
  let changed = Number.POSITIVE_INFINITY;
  for (const at of failures) {
    const row = out[at]!;
    const recovered = at < lastCompleted;
    if (recovered === (row.recovered === true)) continue;
    // A reused row marked in an earlier view whose later completed turn is gone draws its card again.
    let next: AcpmuxRow | undefined;
    if (!recovered) {
      const { recovered: _, ...failed } = row;
      next = failedRows.get(row) ?? { ...failed, version: row.version - 2 * VERSION_SPAN };
    } else {
      next = recoveredRows.get(row);
      if (!next) {
        next = { ...row, recovered: true, version: row.version + 2 * VERSION_SPAN };
        recoveredRows.set(row, next);
        failedRows.set(next, row);
      }
    }
    out[at] = next;
    changed = Math.min(changed, at);
  }
  return changed;
}

/// Each failed summary's recovered row and back, kept while the summary holds, so the memo and
/// height cache keep it.
const recoveredRows = new WeakMap<AcpmuxRow, AcpmuxRow>();
const failedRows = new WeakMap<AcpmuxRow, AcpmuxRow>();

/// A next-step card in a turn view: its index in the drawn rows, the row as its turn shaped it,
/// whether the person said anything after it before the next card, and whether the answer clicked
/// on it came after a later card (`settleNextSteps`).
type NextStepAt = { at: number; row: AcpmuxRow; spoke?: boolean; outOfOrder?: boolean };

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
/// (the agent's next wrap-up or tagged ask) supersedes it once the person said something between
/// them, showing what they said. Turns other agents' messages started answer nothing, so a card they
/// follow, a later card's included, stays a question waiting on the person (Leo, 2026-11-06). Until
/// then its buttons still send, whatever came between. Each card's `spoke` records whether the
/// person said anything before the next card. Returns the first index whose row it changed,
/// `out.length` for none.
function settleNextSteps(out: AcpmuxRow[], cards: NextStepAt[], from: number): number {
  let changed = out.length;
  const put = (at: number, row: AcpmuxRow) => {
    if (out[at] !== row) changed = Math.min(changed, at);
    out[at] = row;
  };
  // An answer clicked on a card (waitingAskStore.ts `claimAnswer`) is that card's, wherever it came:
  // with several questions waiting, the person's "Yes" on an older card is not the newest's. The
  // first prompt of the claimed words sent since the click is it, by the drawn row's index.
  const claimed = new Map<number, number>();
  const own = new Map<number, number>();
  for (let index = from; index < cards.length; index += 1) {
    const { at, row } = cards[index]!;
    if (!row.nextStep!.ask.question) continue;
    const claim = answerClaim(askKey(row));
    if (!claim) continue;
    const { question } = row.nextStep!.ask;
    for (let later = at + 1; later < out.length; later += 1) {
      if (claimed.has(later)) continue;
      // The click sent the answer under its quote of the ask (nextStepAsk.ts `answerPrompt`).
      const said = personPrompt(out[later]!);
      if (said === undefined || answerOf(question, said) !== claim.text) continue;
      if (out[later]!.at < claim.at - CLAIM_SLACK_MS) continue;
      claimed.set(later, index);
      own.set(index, later);
      break;
    }
  }
  for (let index = from; index < cards.length; index += 1) {
    const { at, row } = cards[index]!;
    const { ask } = row.nextStep!;
    const next = index + 1 < cards.length ? cards[index + 1]!.at : out.length;
    const mine = own.get(index);
    let answer: string | undefined;
    if (mine !== undefined) {
      const said = personPrompt(out[mine]!)!;
      answer = pickedAnswer(ask, said) ?? answerOf(ask.question, said);
    }
    let first: string | undefined;
    if (ask.question)
      for (let later = at + 1; later < next && (answer === undefined || first === undefined); later += 1) {
        // Another card's clicked answer is not the person speaking to this one.
        const by = claimed.get(later);
        if (by !== undefined && by !== index) continue;
        const said = personPrompt(out[later]!);
        if (said === undefined) continue;
        first ??= said;
        answer ??= pickedAnswer(ask, said);
      }
    cards[index] = {
      at,
      row,
      spoke: first !== undefined,
      ...(mine !== undefined && mine >= next && { outOfOrder: true }),
    };
    const superseded = index + 1 < cards.length && (first !== undefined || !ask.question);
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

/// The card pinned above the composer (PendingAsks.tsx), as a list of at most one: the agent's
/// newest question, while it is neither answered nor spoken after and another turn came after it, so
/// it is no longer the chat's last word (before that the composer hat holds it).
///
/// One pending question at a time (https://github.com/manaflow-ai/cmux/issues/52766): an agent woken
/// again and again by other agents' messages ends each turn on a question, the same one or a reworded
/// one ("Should I retry the dev build once the build fleet is answering again?", then "...answers
/// again?"), and each asking was its own card under its own key, so they stacked. The agent's newest
/// question stands for its older ones: they stay answerable cards in the transcript, never pinned, so
/// answering or dismissing the one card clears the stack. Reads back only to the newest card with a
/// question, so it costs the cards after it, never the chat's length.
export function waitingAsks(view: Pick<TurnView, "nextSteps" | "rows">): readonly AcpmuxRow[] {
  const { nextSteps, rows } = view;
  for (let index = nextSteps.length - 1; index >= 0; index -= 1) {
    const { at, spoke } = nextSteps[index]!;
    const card = rows[at];
    const step = card?.nextStep;
    if (!card || !step) continue;
    // A recap with nothing to decide asks nothing: the newest question is before it. Read before
    // `superseded`, which settleNextSteps sets on every recap a later card follows.
    if (!step.ask.question) continue;
    if (step.superseded) return NO_ASKS;
    // Answered, or the person said something after it: nothing pins, its card stays answerable.
    if (step.answer !== undefined || spoke) return NO_ASKS;
    // The newest card counts only once a turn came after it: before that it is the chat's last row.
    if (index === nextSteps.length - 1 && !rows.slice(at + 1).some((row) => row.kind === "user")) return NO_ASKS;
    return [card];
  }
  return NO_ASKS;
}
const NO_ASKS: readonly AcpmuxRow[] = [];

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
  agentFamily?: string;
  /// The family's fold style as read for this shape (turnFoldStyle.ts): its opt-in can change
  /// without the family changing, and the cached turn must fold anew when it does.
  foldStyle: TurnFoldStyle;
  /// How its closed fold draws the work around the replies it keeps (turnFoldReplies.experiment.ts).
  repliesArm: string;
  /// How a turn the person steered folds (turnFoldSteered.experiment.ts).
  steeredArm: string;
  /// How its "Worked for" counts the messages it folds (workedForMessages.experiment.ts).
  messagesArm: string;
  /// What its closed "Worked for" says besides its time (workedLine.experiment.ts).
  lineArm: string;
  /// Whether it was shaped with the compact short-turn summary on (compactShortTurns.ts).
  compact: boolean;
  /// The person's own prompt opened the next turn (`supersededFooters`).
  endedByPerson: boolean;
  rows: AcpmuxRow[];
};
const shapedTurns = new WeakMap<AcpmuxRow, ShapedTurn>();

/// A completed turn has one disclosure, keyed by its original prompt. Live rows do not read it,
/// so a remembered open state never changes the transcript while the next turn is running. A
/// history page can begin at a landed steer; accept that provisional key until the older prompt
/// arrives, so loading history does not erase an explicit open choice.
/// Split in order (`foldsInOrder`), each of the turn's folds opens on its own: the key is each one's
/// state, in order ("1" for the turn as one fold stays "1"), and shapeTurn reads each fold's own.
function openFolds(rows: readonly AcpmuxRow[], start: number, end: number, expanded: Folds): string {
  if (expanded.size === 0) return "";
  if (foldsInOrder()) {
    // A fold is open under its own key or a provisional one: a received message inside it that a
    // history page started at (it splits nothing, so its key names no fold once the prompt loads).
    const bounds = [start, ...foldStarts(rows, start, end), end];
    let open = "";
    for (let fold = 0; fold + 1 < bounds.length; fold += 1) {
      let shown = false;
      let closed = false;
      for (let at = bounds[fold]!; at < bounds[fold + 1]!; at += 1) {
        const row = rows[at]!;
        if (at !== bounds[fold] && !(row.kind === "user" && continuesTurn(row))) continue;
        const key = `${WORKED}-${row.id}`;
        shown ||= expanded.has(key);
        closed ||= expanded.has(closedTurnFoldKey(key));
      }
      open += shown ? "1" : closed ? "2" : "0";
    }
    return open.includes("1") || open.includes("2") ? open : "";
  }
  if (expanded.has(`${WORKED}-${rows[start]!.id}`)) return "1";
  if (expanded.has(closedTurnFoldKey(`${WORKED}-${rows[start]!.id}`))) return "0";
  for (let index = start + 1; index < end; index += 1) {
    const row = rows[index]!;
    if (row.kind === "user" && continuesTurn(row) && expanded.has(`${WORKED}-${row.id}`)) return "1";
  }
  return "";
}

/// The person's own steers in a turn's drawn rows moved to their top, under the prompt, in the order
/// they came (turnFoldSteered.experiment.ts `stacked`). Only the steers move; every other row keeps its
/// order. The same rows when the turn has none.
function stackSteers(rows: AcpmuxRow[]): AcpmuxRow[] {
  const steer = (row: AcpmuxRow) => row.kind === "user" && continuesTurn(row) && isOwnSteer(row) && !isUnsent(row);
  if (!rows.some(steer)) return rows;
  return [...rows.filter(steer), ...rows.filter((row) => !steer(row))];
}

/// The ids of the footers `supersededFooters` would put over the person's steers in `turn`, which the
/// `stacked` arm drops.
function stackedSteerFooters(turn: readonly AcpmuxRow[]): Set<string> {
  const ids = new Set<string>();
  for (const row of turn)
    if (row.kind === "user" && continuesTurn(row) && isOwnSteer(row)) ids.add(`${SUPERSEDED}-${steerKey(row)}`);
  return ids;
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

/// The fold style and experiment arms a turn is shaped with, part of its cache key. Read once per
/// turn view, not once per turn: each read parses the stored overrides (experiment.ts), and a view
/// shaped without reuse (a fold toggled, a fold held while the reader is scrolled up) asked for them
/// on every turn of a long chat.
type TurnArms = {
  foldStyle: TurnFoldStyle;
  repliesArm: string;
  steeredArm: string;
  messagesArm: string;
  lineArm: string;
  compact: boolean;
};
const turnArms = (agentFamily: string | undefined): TurnArms => ({
  foldStyle: turnFoldStyle(agentFamily),
  repliesArm: experimentArm(turnFoldReplies),
  steeredArm: experimentArm(turnFoldSteered),
  messagesArm: experimentArm(workedForMessages),
  lineArm: experimentArm(workedLine),
  compact: compactShortTurnsOn(),
});

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
  agentFamily?: string,
  foldedBackground: ReadonlySet<string> = new Set(),
  trayAgents = 0,
  retryTarget = false,
  turnStartedAtMs?: number,
  { foldStyle, repliesArm, steeredArm, messagesArm, lineArm, compact }: TurnArms = turnArms(agentFamily),
): AcpmuxRow[] {
  const user = rows[start]!;
  // A running turn changes with every event: it is neither read from nor kept in the cache, so its
  // open-fold key is never needed, and a streamed token does no work over its rows for it.
  const open = live ? "" : openFolds(rows, start, end, expanded);
  const background = openBackgroundTurns(rows, start + 1, end, expanded);
  const messageRuns = live ? "" : openMessageRuns(rows, start + 1, end, expanded);
  const backgroundRuns = live ? "" : openBackgroundRuns(rows, start + 1, end, expanded);
  const source = rows.slice(start + 1, end).filter((row) => !hiddenInBackground(row, foldedBackground));
  // The person's own prompt opened the turn after this one: a turn with no summary ended there
  // (`supersededFooters`). Part of the cache key, since that prompt is not in `source`.
  const opener = rows[end];
  const endedByPerson = !live && !last && opener?.kind === "user" && !opener.incoming && !opener.received;
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
    cached.agentFamily === agentFamily &&
    cached.foldStyle === foldStyle &&
    cached.repliesArm === repliesArm &&
    cached.steeredArm === steeredArm &&
    cached.messagesArm === messagesArm &&
    cached.lineArm === lineArm &&
    cached.compact === compact &&
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
  // The person's steer still on its way (the pane's own row, before acpmux's record) draws where he
  // sent it, as acpmux's record of it will: what came in after the send draws under it, never over it
  // (Leo, 2026-11-22: "WHY DID IT FUCKING DISPLAY NOTHING THEN COPY BUTTONS THEN YOU SENT SHIT THEN MY
  // STEER WENT UNDER IT"). Held after the body, it sat under every row that came in before its record.
  const sentHere = (row: AcpmuxRow) => live && sentSteer(row);
  const kept = source.filter(
    (row, at) =>
      (row.kind !== "user" || sentHere(row) || (continuesTurn(row) && row.incoming?.kind !== "hidden")) &&
      !hidesContinuedSummary(source, at, last),
  );
  // A turn the agent ran on its own after this one ended (no prompt starts it) draws in its tail:
  // a quiet one, or one still running, as its one line (backgroundTurns.ts).
  const answering = foldBackgroundTurns(answeringPerson(user, kept), expanded);
  // Ended (its summary in, even before the session reads ready), a steer the agent was finishing
  // when it came draws over the answer (`lateSteersLast`); running, every row draws as it came.
  const turn = lateSteersLast(answering, live);
  const held = source.filter((row) => row.kind === "user" && !continuesTurn(row) && !sentHere(row));
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
      frame: liveLineFrame(user),
      // The running turn's slot from the send (`LIVE_SLOT`): the turn opening never resizes the line.
      ...LIVE_SLOT,
    };
    // Held behind the agent's start: the line draws the start look (agentStart.experiment.ts), with
    // no time yet. The sent prompt's row is stamped when it goes, so a time here would jump from
    // "Thinking 20s" back to 0s when the turn opens (cmux#30642).
    if (user.queued) Object.assign(line, { queued: user.queued, untimed: true });
    shaped = [...date, ...drawnUser, line];
  } else {
    const unstacked = shapeTurn(
      user,
      turn,
      expanded,
      !foldsInOrder() && open === "1",
      live,
      last,
      last && held.length === 0,
      retryTarget && (!last || held.length === 0),
      clockOffset,
      agentFamily,
      trayAgents,
      endedBackgroundTurns(source),
      turnStartedAtMs,
    );
    // The `stacked` arm draws the person's steers right under the prompt, live and ended
    // (turnFoldSteered.experiment.ts): they never move when the turn folds.
    const shapedBody = steeredArm === "stacked" && foldStyle.conclusion ? stackSteers(unstacked) : unstacked;
    // Where its runs fold, a run of them that carries messages between agents folds under one line
    // (messageRuns.ts; Leo, 2026-11-01: "this should be collapsible").
    const messaged = foldMessageRuns(shapedBody, expanded, live);
    // A run of background-task notifications folds under one line (backgroundRuns.ts; Leo,
    // 2026-11-02: "why do you still do these").
    // A stretch the person came in after ends there, with the end-of-turn footer (`supersededFooters`).
    // While the turn runs it comes with the prompt the person sent, in the frame the prompt is drawn
    // (over a steer still waiting, at the body's end), so the prompt never moves down under it when
    // the agent reads it (Leo, 2026-11-09: "i hate the way when i send off a message it seems to move
    // up and under your current running tool call or whatever").
    const runs = foldBackgroundRuns(messaged, expanded);
    // The person's steer still on its way draws in its place in the body (`sentHere`); its stretch's
    // footer comes in the frame it is drawn, as for one acpmux recorded.
    const footed = supersededFooters(runs, turn, endedByPerson, user.at, live);
    // Stacked, a steer closes no stretch of its own: the footer that would end the stretch before it
    // goes, and the turn's one footer copies the turn.
    const stackedSteers = steeredArm === "stacked" && foldStyle.conclusion ? stackedSteerFooters(turn) : undefined;
    const body = sinceAboveWorked(stackedSteers?.size ? footed.filter((row) => !stackedSteers.has(row.id)) : footed);
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
    const line = sent ? [sentLine(sent)] : liveLine;
    // Other agents' messages that started a finished turn are its "Worked for"'s first entries
    // (``isAgentPrompt``): out of sight while it is closed, right under its line while it is open,
    // in time order before the work. While the turn runs, or when it did nothing to fold (a reply
    // alone), they stay in sight as its prompt.
    const worked = !live && foldStyle.conclusion && isAgentPrompt(user) ? fold(body, user) : -1;
    if (worked >= 0) {
      if (body[worked]!.foldOpen) body.splice(worked + 1, 0, user);
      drawnUser.length = 0;
    }
    // While such a turn runs, its message is drawn where the open fold will hold it: right under the
    // "Working for" that stands in the fold's line (`shapeLiveTurn`). The line keeps one place from
    // the message's arrival to the turn's end, and the message keeps its place until the fold takes it.
    const working = live && foldStyle.conclusion && isAgentPrompt(user) ? body.findIndex(isRunningHeader(user)) : -1;
    if (working >= 0 && drawnUser.length) {
      body.splice(working + 1, 0, user);
      drawnUser.length = 0;
    }
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
    // What was still going when the person sent into the running turn draws after the prompt.
    // A run that keeps many cards in sight (a coordinator's Agent calls) draws as rows of a few
    // each, so the transcript mounts only those near the window (runParts.ts).
    if (live) shaped = cutLongRuns(afterSends(shaped, clockOffset));
    // Legacy/history turns can end without a turn_result. Keep the normal turn rhythm at the
    // composer for the latest completed turn without restoring the permanent runway under every
    // turn. The marker is consumed by the row estimator and CSS only for this terminal row.
    if (last && !live && held.length === 0 && !turn.some((row) => row.kind === "turnSummary")) {
      let final = shaped.length - 1;
      while (final >= 0 && (shaped[final]!.kind === DATE || shaped[final]!.kind === "user")) final -= 1;
      if (final >= 0) shaped[final] = { ...shaped[final]!, lastTurn: true };
    }
  }
  // Shaped anew (a running turn, or a finished one whose cache key moved: the turn after it opened,
  // a row came into it), each row equal to the one it drew last time keeps that object.
  shaped = steadyRows(user, shaped);
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
      agentFamily,
      foldStyle,
      repliesArm,
      steeredArm,
      messagesArm,
      lineArm,
      compact,
      endedByPerson,
      rows: shaped,
    });
  return shaped;
}

/// A turn's drawn rows from its last shaping, by id. The running turn is shaped again on every
/// record (`shapedTurn` keeps no cache for it), and a finished one each time its cache key moves (the
/// turn after it opens, so it is no longer the last); its folds, groups, "Worked for" and footer
/// come back as new objects even where nothing in them changed. Downstream everything keys on row identity: the layout keeps
/// a row only while it is the same object (`layoutConversation`), the height cache is a WeakMap by
/// row, and each mounted row re-renders when its object changes. A coordinator's running turn holds
/// thousands of rows, so every streamed token re-laid, re-measured and re-rendered all of them
/// (Leo's long chat: 110% renderer CPU, frames every 283 ms). A row equal to the one drawn last
/// time keeps that object, so a token costs only the rows it changed.
const drawnTurnRows = new WeakMap<AcpmuxRow, { byId: Map<string, AcpmuxRow>; drawn: readonly AcpmuxRow[] }>();

function steadyRows(user: AcpmuxRow, shaped: AcpmuxRow[]): AcpmuxRow[] {
  const before = drawnTurnRows.get(user);
  // One map for the turn's life, written only where a row changed: a record into a turn of
  // thousands of rows looks up and compares only the rows it handed over as new objects (a row
  // drawn last time in the same place as the same object is passed by), never rebuilding the map.
  // An id that left keeps its last row, which only ever stands in for an equal one, until the ids
  // that left outnumber the rows drawn (below).
  let byId = before?.byId ?? new Map<string, AcpmuxRow>();
  const drawn = before?.drawn;
  let out: AcpmuxRow[] | undefined;
  for (let at = 0; at < shaped.length; at += 1) {
    const row = shaped[at]!;
    if (drawn?.[at] === row) continue;
    const prior = byId.get(row.id);
    if (prior === row) continue;
    const kept = prior !== undefined && sameShape(prior, row, ROW_COMPARE_DEPTH) ? prior : row;
    if (kept !== row) (out ??= shaped.slice())[at] = kept;
    else byId.set(row.id, row);
  }
  const result = out ?? shaped;
  // A turn that never ends (a coordinator's) lets go of its oldest records (direct.ts `shedOlderHeld`), and their
  // rows leave the drawn ones for good. Kept here, every row the turn ever drew stayed alive, and with it each
  // row's entries in the caches keyed by row or tool (messageRuns.ts, acpmuxMcpSends.ts, toolNames.ts ...): a
  // running turn of 100k records held about 40 MB of renderer heap no row on screen used (chat-100k-flat
  // running_x1). Once the map holds twice the rows drawn it is made again from them: O(rows drawn) once per as
  // many rows that left, so O(1) a record, and the map stays within twice the turn's held rows.
  if (byId.size > 2 * result.length + LIVE_ROWS_SLACK) byId = new Map(result.map((row) => [row.id, row]));
  drawnTurnRows.set(user, { byId, drawn: result });
  return result;
}

/// The ids that left the running turn's drawn rows its map keeps before it is made again (`steadyLiveRows`).
const LIVE_ROWS_SLACK = 64;

/// How deep `sameShape` compares: a row, its fields' objects and arrays (a group's rows, a tool
/// call's content), and theirs. Deeper values must be the same object.
const ROW_COMPARE_DEPTH = 4;

/// `a` and `b` hold the same values: the same object, or plain objects and arrays whose entries are
/// the same down to `depth` levels. Equal values draw the same, so the older object can stand in.
export function sameShape(a: unknown, b: unknown, depth: number): boolean {
  if (a === b) return true;
  if (depth <= 0 || typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let at = 0; at < a.length; at += 1) if (!sameShape(a[at], b[at], depth - 1)) return false;
    return true;
  }
  if (
    Array.isArray(b) ||
    Object.getPrototypeOf(a) !== Object.prototype ||
    Object.getPrototypeOf(b) !== Object.prototype
  )
    return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  for (const key of keys) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (!sameShape((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key], depth - 1)) return false;
  }
  return true;
}

/// "New since you looked" draws above the "Worked for" that holds or just precedes it, never under
/// it: the place the person left can fall before the turn's work, inside it or at its end, and the
/// fold draws the last two the same way, under its line. A reply or a steer between them is
/// something the person read, so the divider stays under that.
function sinceAboveWorked(body: AcpmuxRow[]): AcpmuxRow[] {
  const at = body.findIndex((row) => row.kind === SINCE_DIVIDER);
  if (at < 0) return body;
  let worked = at - 1;
  for (; worked >= 0 && body[worked]!.kind !== WORKED; worked -= 1) {
    const row = body[worked]!;
    if ((row.kind === "user" && !isReceivedLine(row)) || (isReply(row) && !row.foldedReply)) return body;
  }
  if (worked < 0) return body;
  return [...body.slice(0, worked), body[at]!, ...body.slice(worked, at), ...body.slice(at + 1)];
}

/// The agent's replies and the person's own steers: what a turn draws as it ran, with no work to fold.
const isDialogue = (row: AcpmuxRow) =>
  (row.kind === "user" && !row.incoming) || (isAnswer(row) && row.assistantPhase === undefined);

/// A turn's rows hold no work to fold, open or closed: the rows a fold leaves in sight, and dialogue.
const repliesOnly = (rows: readonly AcpmuxRow[]) =>
  rows.every((row) => isFinalAnswer(row) || staysOut(row) || isDialogue(row));

/// A turn folds under "Worked for" only when the fold hides something worth hiding: at least
/// `FOLD_MIN_ROWS` work rows (calls, and rows the harness or another agent wrote), or at least
/// `FOLD_MIN_MS` of thinking and tools. Otherwise its rows draw flat, with no line and no chevron,
/// and a turn under `FLOOR_MS` never has a header at all (Leo, 2026-11-24, on a wake's "Report from
/// Subagent" under "Worked for 0s": "honestly in these cases should we just... not do our folding
/// situation? this edge case? cuz otherwise it's so weird"). A turn that failed or was stopped keeps
/// its line: it says how it ended. An unknown time leaves the rows to decide.
export const FOLD_MIN_ROWS = 3;
// motion-allow: how long a turn ran before its work folds, not a motion
export const FOLD_MIN_MS = 5_000;
// motion-allow: the shortest turn that folds, not a motion
export const FLOOR_MS = 1_000;

/// The rows a fold would hide: each tool call, and each row another agent wrote
/// (the turn's own prompt among them). Thinking counts by its time, not as a row.
const foldsAsWork = (row: AcpmuxRow) => isAgentPrompt(row);
export function workRowCount(user: AcpmuxRow, body: readonly AcpmuxRow[]): number {
  let count = foldsAsWork(user) ? 1 : 0;
  for (const row of body) {
    if (row.kind === "activity") count += (row.items ?? []).filter((item) => item.tool).length;
    else if (row.kind === "user" && foldsAsWork(row)) count += 1;
  }
  return count;
}

export function worthFolding(rows: number, durationMs: number | undefined): boolean {
  if (durationMs === undefined) return rows >= FOLD_MIN_ROWS;
  if (durationMs < FLOOR_MS) return false;
  return rows >= FOLD_MIN_ROWS || durationMs >= FOLD_MIN_MS;
}

function foldsTurn(
  user: AcpmuxRow,
  body: readonly AcpmuxRow[],
  summary: AcpmuxRow,
  turnStartedAtMs: number | undefined,
): boolean {
  if (summary.status !== "completed") return true;
  // The harness's own measure of the turn counts too: a wake that came after the answer moves the
  // clock's start to itself, so the clock alone reads 0 over work the turn did before it.
  const clock = turnClock(user, body, turnStartedAtMs, summary).durationMs;
  // A span stamped at one moment measured nothing (`spanDuration`): a synthesized end, such as a
  // background turn's, reads 0, which is no time known, so its rows decide.
  const measured = Math.max(clock ?? 0, summary.durationMs ?? 0);
  return worthFolding(workRowCount(user, body), measured > 0 ? measured : undefined);
}

/// Where `body` draws the "Worked for" of the turn `user` opened, or -1 for none.
const fold = (body: readonly AcpmuxRow[], user: AcpmuxRow) =>
  body.findIndex((row) => row.kind === WORKED && row.id === `${WORKED}-${user.id}`);

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
function sentLine(sent: AcpmuxRow): AcpmuxRow {
  const line: AcpmuxRow = {
    id: LIVE_THINKING,
    version: 1,
    at: sent.at,
    kind: THINKING,
    verbKey: sent.id,
    frame: liveLineFrame(sent),
    ...LIVE_SLOT,
  };
  if (sent.queued) Object.assign(line, { queued: sent.queued, untimed: true });
  return line;
}

/// The slot a sent prompt's Thinking line takes before its turn opens: the running turn's last row,
/// the footer's slot (model.ts `fallbackRowHeight`), as the turn's line is from then on. As a plain status row it was 28 px and became 32 when the turn
/// opened, moving every row above it in the middle of the send (Leo, 2026-11-05: "there's the gap
/// between when you send off a message versus otherwise, like it's like there's a one-two
/// discontinuity. That's not good.").
const LIVE_SLOT: Partial<AcpmuxRow> = { below: true };

const isAnswer = (row: AcpmuxRow) => row.kind === "assistant";

/// A tool call after a turn's last text: the turn ended on work, so that text was its narration.
/// Edits join the turn's card and render calls draw as their own cards, so neither counts; a
/// step that edited and then ran something does.
const isWork = (row: AcpmuxRow) =>
  row.kind === "activity" &&
  (row.items ?? []).some((item) => item.tool && !isEditTool(item.tool) && !renderCall(item.tool));

/// Explicit phases select the final answer and footer; older, unphased turns fall back to their
/// last takeaway or nonempty reply after the final tool call. A closed fold keeps only this answer
/// in sight under the default `answer` arm (turnFoldReplies.experiment.ts).
/// A turn the agent ran on its own can start before the prompt's turn's result is written (acpmux
/// clears the turn, then waits before it writes `turn_result`), so its rows sit among the prompt's
/// turn's. Its reply is never that turn's answer, nor its calls work after the answer: the turn's
/// own reply drew as a folded note under the background turn's words (transcript-oddities.md T3).
function answerAt(rows: readonly AcpmuxRow[]): number {
  const own = rows.some((row) => row.inBackground === undefined && isReply(row));
  const others = (row: AcpmuxRow) => own && row.inBackground !== undefined;
  if (rows.some((row) => row.kind === "assistant" && row.assistantPhase !== undefined)) {
    for (let at = rows.length - 1; at >= 0; at -= 1) if (!others(rows[at]!) && isFinalAnswer(rows[at]!)) return at;
    return -1;
  }
  let stepped = false;
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (others(row)) continue;
    if (isReply(row) && (isTakeaway(row) || !stepped)) return at;
    if (isWork(row)) stepped = true;
  }
  return -1;
}

/// An ended turn's rows with the person's late steers and then its answer at its end: a steer the
/// agent started no new call after (it came while the agent was finishing: its reply, a call already
/// running) draws under all the turn's work and over the answer, which is the turn's last word (Leo,
/// 2026-11-25: "there are situations in which i steer RIGHT before you finish a turn but your
/// completed sent message goes above mine bc your turn started before and there's some folding
/// shit... worked for above my message and then yours and then boom that's it"). The work after it
/// folds up into the Worked for above it at the turn's end, as the one fold takes it all (Leo, ~09:20Z:
/// "the final ultra fold simply... takes it all away"); the steer and the answer never fold. A steer
/// the agent went on working after keeps its place (RFD 0085, in order). While the turn runs rows draw
/// as they came. Only the turn's own rows up to its summary move; `rows` itself when none do.
export function lateSteersLast(rows: AcpmuxRow[], live = false): AcpmuxRow[] {
  let end = rows.findIndex((row) => row.kind === "turnSummary" && row.inBackground === undefined);
  if (end < 0 && live) return rows;
  if (end < 0) end = rows.length;
  // The earliest late steer: from the end back, while no call below a steer started after it (a
  // call already running at the send started before it).
  let late = -1;
  let lastCall = -Infinity;
  for (let at = end - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (isLateSteer(row)) {
      if (lastCall >= row.at) break;
      late = at;
    } else if (row.kind === "activity" && row.inBackground === undefined)
      for (const item of row.items ?? []) if (item.tool) lastCall = Math.max(lastCall, item.tool.startedAt ?? row.at);
  }
  if (late < 0) return rows;
  // The agent's text just over the first late steer moves with the answer: the reply it was writing
  // when the steer came (acpmux cuts it there into two rows, one each side of the steer).
  let from = late;
  while (from > 0 && isOwnText(rows[from - 1]!)) from -= 1;
  const region = rows.slice(from, end);
  const steers = region.filter(isLateSteer);
  const said = region.filter(isOwnText);
  // Nothing to move without an answer among what moves, or where it already reads in this order.
  const answer = rows[answerAt(rows.slice(0, end))];
  if (!answer || !said.includes(answer)) return rows;
  const work = region.filter((row) => !isLateSteer(row) && !isOwnText(row));
  const reordered = [...work, ...steers, ...said];
  if (reordered.every((row, at) => row === region[at])) return rows;
  return [...rows.slice(0, from), ...reordered, ...rows.slice(end)];
}

const isLateSteer = (row: AcpmuxRow) => row.kind === "user" && continuesTurn(row) && sentByPerson(row);
const isOwnText = (row: AcpmuxRow) => row.kind === "assistant" && row.inBackground === undefined;

/// A reply with something to read: an empty segment of the agent's text is never a takeaway.
const isReply = (row: AcpmuxRow) => isAnswer(row) && !isVisiblyEmptyText(row.text);
const isFinalAnswer = (row: AcpmuxRow) => isReply(row) && row.assistantPhase === "final_answer";

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

/// One disclosure of a finished turn, the final one with its answer and the work recorded after it.
/// `until`: when the stretch ended, at the next message that came in; undefined for the last.
export type FoldSegment = {
  anchor: AcpmuxRow;
  rows: AcpmuxRow[];
  takeaway?: AcpmuxRow;
  after?: AcpmuxRow[];
  until?: number;
};

/// A message that came into the running turn and splits its fold (`inOrder`): the person's steer, or
/// another agent's message the turn went on to answer. A hidden one (bookkeeping) or one that draws
/// nothing (a lone ".", which shapeTurn drops from the turn's body) splits nothing, so the fold keys
/// read off the raw rows (`foldStarts`) split where the drawn turn does.
const splitsFold = (row: AcpmuxRow) =>
  row.kind === "user" && continuesTurn(row) && row.incoming?.kind !== "hidden" && !isVisiblyEmptyMessage(row);
/// The person's own steer, which stays in sight; another agent's message folds like work.
const isOwnSteer = (row: AcpmuxRow) => !row.incoming && !row.received;
/// Whether `row` starts a new fold, `replied`: a reply to the person drew since the last one started.
/// The person's steer always does: it and the reply before it stay in sight under every arm. Another
/// agent's message does only after a reply that stays in sight beside the closed fold: with none, the
/// fold above it would close onto the next one with nothing between them, so it folds in place, the
/// nearest fold's entry. The default `answer` arm keeps one work disclosure across received
/// messages, with only the turn's answer beside it; only a personal steer splits that disclosure.
const startsFold = (row: AcpmuxRow, replied: boolean) =>
  splitsFold(row) && (isOwnSteer(row) || (replied && experimentArm(turnFoldReplies) !== "answer"));
/// A reply that lets another agent's message start a fold (`startsFold`), read the same way off the
/// drawn body (foldSegments) and the raw rows (`foldStarts`): one the turn draws (a bare "." only
/// where it answers the person, `answeringPerson`), and not a background turn's.
const repliesInFold = (row: AcpmuxRow) => isReply(row) && row.inBackground === undefined && !isVisiblyEmptyMessage(row);

/// The indexes of the rows in `rows` (from `start`, the turn's prompt, to `end`) that start a fold of
/// their own once the turn is split in order: the same rows foldSegments splits at, read off the
/// unshaped transcript for the fold keys (`openFolds`, `turnFoldFor`).
/// A reply counts only where the turn draws it: a bare "." draws when it answers the person's own
/// prompt (`answeringPerson`), and nowhere else (shapeTurn drops it from the body).
function foldStarts(rows: readonly AcpmuxRow[], start: number, end: number): number[] {
  const starts: number[] = [];
  const body = answeringPerson(rows[start]!, rows.slice(start + 1, end));
  let replied = false;
  for (let at = 0; at < body.length; at += 1) {
    const row = body[at]!;
    if (startsFold(row, replied)) {
      starts.push(start + 1 + at);
      replied = false;
    } else if (repliesInFold(row)) replied = true;
  }
  return starts;
}

/// Once the turn finishes, its intermediate dialogue and received reports fold. The original prompt
/// remains the first disclosure's stable anchor even if the answer or a steer's row changes.
/// `inOrder` (turnFoldSteered.experiment.ts): each message that came in mid-turn ends a disclosure,
/// and the work after it folds under its own, anchored at that message, so no row draws above a
/// message it came after. The person's steer closes the stretch before it, where it stays in sight;
/// another agent's message after a reply opens the stretch after it, as the first entry of that fold (Leo,
/// 2026-11-07, on received messages: "fold ... into the worked for as well? Like the nearest one?").
export function foldSegments(opener: AcpmuxRow, rows: readonly AcpmuxRow[], inOrder = false): FoldSegment[] {
  const drawn = rows.filter((row) => row.kind !== "typing");
  const pieces: { anchor: AcpmuxRow; rows: AcpmuxRow[] }[] = [{ anchor: opener, rows: [] }];
  for (const row of drawn) {
    const piece = pieces.at(-1)!;
    // A compaction that ended under the person's steer (they steered while it ran: direct.ts puts its
    // note where its live line stood) stays with the stretch the steer closed, in sight above the
    // steer's one Worked for, never folded into it (Leo, 2026-11-25: "the worked for collapsing the
    // compaction and then the next worked for + thinking is weird").
    const parent = pieces.at(-2);
    if (inOrder && parent && row.kind === "compaction" && !piece.rows.length && isOwnSteer(piece.anchor)) {
      parent.rows.push(row);
      continue;
    }
    if (!inOrder || !startsFold(row, piece.rows.some(repliesInFold))) piece.rows.push(row);
    else if (isOwnSteer(row)) {
      piece.rows.push(row);
      pieces.push({ anchor: row, rows: [] });
    } else pieces.push({ anchor: row, rows: [row] });
  }
  // The turn's answer is read over the whole turn, as one fold reads it: the fold that holds it ends
  // on it, and work after it in that fold folds with the work before it.
  const answer = drawn[answerAt(drawn)];
  return pieces.map((piece, index) => {
    const next = pieces[index + 1];
    const final = answer ? piece.rows.indexOf(answer) : -1;
    return {
      anchor: piece.anchor,
      rows: final < 0 ? piece.rows : piece.rows.slice(0, final),
      ...(final >= 0 && { takeaway: answer, after: piece.rows.slice(final + 1) }),
      ...(next && { until: next.anchor.at }),
    };
  });
}

/// Work that is a compaction's note and nothing else (the person's steers after it aside): a
/// /compact the person steered into.
export const onlyCompaction = (rows: readonly AcpmuxRow[]) => {
  const own = rows.filter((row) => row.kind !== "user");
  return own.length > 0 && own.every((row) => row.kind === "compaction");
};

/// The calls `rows` made, as a fold's line counts them.
const callsIn = (rows: readonly AcpmuxRow[]) =>
  rows
    .flatMap(withoutDrafts)
    .reduce((n, row) => n + (row.kind === "activity" ? (row.items ?? []).filter((item) => item.tool).length : 0), 0);

/// The names of the subagents `body` draws a row for (its groups, started lines and done lines).
const shownAgentNames = (body: readonly AcpmuxRow[]): ReadonlySet<string> =>
  new Set(
    body.flatMap((row) =>
      isSubagentGroup(row) || row.kind === SUBAGENT_STARTED || row.kind === SUBAGENT_DONE
        ? (row.subagents ?? []).map((agent) => agent.name.trim())
        : [],
    ),
  );

/// An activity row whose every item is an Agent call (agentCalls.ts) for a subagent `shown` draws a
/// row of its own, matched by the name the call gave it: the call says nothing that row does not. An
/// Agent call no subagent row answers (it failed before acpmux named one) is never one.
const onlySpawnsShownAgents = (row: AcpmuxRow, shown: ReadonlySet<string>) =>
  row.kind === "activity" &&
  (row.items?.length ?? 0) > 0 &&
  row.items!.every((item) => {
    const call = item.tool && agentCall(item.tool);
    return call !== undefined && shown.has(call.description.trim());
  });

/// A segment's work that is one or more subagents and nothing else: their rows, and the Agent calls
/// that spawned them (`onlySpawnsShownAgents`). A subagent's started and failed lines stay in sight
/// beside the fold (`staysOut`), so its work may hold only the call.
const subagentsOnly = (work: readonly AcpmuxRow[], shown: ReadonlySet<string>) => {
  const rows = work.flatMap(withoutDrafts);
  return (
    rows.length > 0 &&
    rows.every(
      (row) =>
        isSubagentGroup(row) ||
        row.kind === SUBAGENT_STARTED ||
        row.kind === SUBAGENT_DONE ||
        onlySpawnsShownAgents(row, shown),
    )
  );
};

const isUnsent = (row: AcpmuxRow) => Boolean(row.pending || row.failed);

/// The tagged ask (nextStepAsk.ts) of the reply right before a message that was not the person's
/// (another agent's, a notice) steered into the turn, with the reply that asked it: the newest such,
/// so long as the person said nothing in the turn after it. Each steer's reply is the last words
/// before it (`repliesIn`); a cut-off reply stays in sight under every arm (`keptOut`).
function steeredAsk(body: readonly AcpmuxRow[]): { reply: AcpmuxRow; ask: NextStepAsk } | undefined {
  let steered = false;
  for (let at = body.length - 1; at >= 0; at -= 1) {
    const row = body[at]!;
    if (row.kind === "user") {
      // The person's own steer is their reply to what came before it.
      if (!row.incoming && !row.received) return undefined;
      steered = true;
      continue;
    }
    if (!steered || !isReply(row)) continue;
    const ask = nextStepAsk(row.text);
    if (ask?.question) return { reply: row, ask };
    steered = false;
  }
  return undefined;
}

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
    if (isReply(row) && (isTakeaway(row) || (row.assistantPhase === undefined && !stepped && !answered))) {
      replies.add(row.id);
      answered = true;
    }
    if (isWork(row)) stepped = true;
  }
  return replies;
}

/// The rows a closed "Worked for" draws for `rows`: each row `out` keeps in sight as `outside` draws
/// it, and each stretch of hidden work between them as closed run lines, one for the stretch
/// (`groups`) or one per run (`runs`). A line counts calls only; its short notes go with it as quiet
/// lines; an edit stays on the turn's edits card, and the other calls of its step on the line
/// (`lineWork`); another agent's message beside a run stays as its line (`isReceivedLine`), which
/// that run folds with (messageRuns.ts); anything else hidden stays under "Worked for".
/// A line keeps its first run's id, so opening the fold keeps that line where it is (one row, one
/// open state) rather than fading it out and drawing its run anew.
/// Leo, 2026-11-07, on a closed turn whose received message and the calls beside it had gone, two
/// replies left over an empty gap: "some of the tool calls, like, literally just get swallowed."
function aroundReplies(
  rows: readonly AcpmuxRow[],
  out: (row: AcpmuxRow) => boolean,
  outside: (rows: readonly AcpmuxRow[]) => AcpmuxRow[],
  arm: "groups" | "runs",
  keep: ReadonlySet<string>,
  edits: boolean,
): AcpmuxRow[] {
  const shaped: AcpmuxRow[] = [];
  let stretch: AcpmuxRow[] = [];
  const line = (run: AcpmuxRow): AcpmuxRow => ({
    ...run,
    settled: true,
    foldRun: true,
    version: run.version * RUN_STATES + 3,
  });
  const flush = () => {
    // A call that never got its input draws as nothing, as the open fold draws it (withoutDrafts),
    // which drops it after mergeShortNotes, so a draft-only row still ends a run there.
    const all = stretch.flatMap((row) => (isEdit(row) ? (lineWork(row) ?? []) : [row]));
    stretch = [];
    // Another agent's message keeps its line only beside a run, which it folds with (messageRuns.ts:
    // "Ran a command, received a message"); messages alone fold under Worked for, as work does.
    if (arm === "runs") {
      const drawn = mergeShortNotes(all, keep, edits).flatMap(withoutDrafts);
      if (!drawn.some(isRun)) return;
      shaped.push(
        ...drawn.filter((row) => isRun(row) || isReceivedLine(row)).map((row) => (isRun(row) ? line(row) : row)),
      );
      return;
    }
    const work = all.flatMap(withoutDrafts);
    const runs = work.filter(isRun);
    if (!runs.length) return;
    const from = work.indexOf(runs[0]!);
    const to = work.lastIndexOf(runs.at(-1)!);
    const received = work.filter(isReceivedLine);
    const parts = work.slice(from, to + 1).filter((row) => isRun(row) || isShortNote(row));
    shaped.push(
      ...received.filter((row) => work.indexOf(row) < from),
      line({
        ...runs[0]!,
        items: parts.flatMap((row) => (isRun(row) ? (row.items ?? []) : [{ kind: "note", text: row.text!.trim() }])),
        toolCount: runs.reduce((n, run) => n + (run.toolCount ?? 0), 0),
        joined: parts.map((row) => row.id),
        version: parts.reduce((version, row) => mixVersion(version, row.version), 0),
      }),
      ...received.filter((row) => work.indexOf(row) > from),
    );
  };
  for (const row of rows) {
    if (out(row)) {
      flush();
      shaped.push(...outside([row]));
    } else {
      stretch.push(row);
      // A render card keeps its place among the replies.
      shaped.push(...outside([row]));
    }
  }
  flush();
  return shaped;
}

/// Another agent's message in a finished turn, drawn as its one line (IncomingMessageCard.tsx).
const isReceivedLine = (row: AcpmuxRow) => row.kind === "user" && isLineRow(row) && !isWaitingMessage(row);

/// A turn's prompt that is other agents' messages, not the person's: acpmux's inbox notice that woke
/// the chat, or one agent's message. A finished turn's "Worked for" folds it as its first entries
/// (``shapeTurn``, ``shapedTurn``). A tool's fire stays in sight, as it does in a message run.
export const isAgentPrompt = (row: AcpmuxRow) =>
  isReceivedLine(row) &&
  !row.received &&
  (row.incoming?.kind === "inbox" ||
    (row.incoming?.kind === "message" &&
      !row.incoming.message.fromPerson &&
      row.incoming.message.notice?.severity !== "fire"));

/// How many messages between agents `rows` hold: each send among their calls, and each message
/// received (an inbox notice counts the messages it brought, as messageRuns.ts does).
function foldedAgentMessages(rows: readonly AcpmuxRow[]): { sent: number; received: number } {
  let sent = 0;
  let received = 0;
  for (const row of rows) {
    if (isReceivedLine(row) && row.kind === "user")
      received += row.incoming?.kind === "inbox" ? Math.max(1, inboxCounts(row.incoming.notice).messages) : 1;
    else if (row.kind === "activity" && row.items?.length) sent += sentMessages(row.items);
  }
  return { sent, received };
}

/// The messages one step's calls sent, by its immutable items array: a running turn's "Worked for"
/// is shaped again on every record the pane draws, and grouping each earlier step's calls again
/// (toolGroups.ts) was most of that (bench/replay-under-load.bench.ts --profile).
const sentCounts = new WeakMap<readonly AcpmuxActivity[], number>();
function sentMessages(items: readonly AcpmuxActivity[]): number {
  const kept = sentCounts.get(items);
  if (kept !== undefined) return kept;
  let sent = 0;
  for (const group of toolGroups(items))
    sent +=
      group.type === "sendGroup"
        ? group.entries.length
        : group.type === "message" ||
            group.type === "send" ||
            (group.type === "subsession" && group.call.tool === "send")
          ? 1
          : 0;
  sentCounts.set(items, sent);
  return sent;
}

/// The calls of a step that edited, other than its edits, which the turn's edits card draws: they stay
/// on the closed fold's line, under the id the step's copy has in the open fold (`FOLDED`), so the
/// card keeps the step's own id. It is `partial`: a Find match in the step, which may be in an edit's
/// diff, opens the fold to the step's whole copy (chatFind.ts isFindRow). Undefined when the step
/// only edited.
function lineWork(row: AcpmuxRow): AcpmuxRow | undefined {
  const items = (row.items ?? []).filter((item) => !isEditTool(item.tool));
  const calls = items.filter((item) => item.tool).length;
  return calls ? { ...row, id: `${row.id}${FOLDED}`, items, toolCount: calls, partial: true } : undefined;
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
  agentFamily?: string,
  trayAgents = 0,
  endedBackground: ReadonlySet<string> = new Set(),
  turnStartedAtMs?: number,
): AcpmuxRow[] {
  const end = turn.findIndex((row) => row.kind === "turnSummary");
  if (end < 0) {
    const final = turn.find(isFinalAnswer);
    if (final) {
      // The final answer starts the folded presentation before turn_result. Reuse the settled
      // projection, remove its internal footer, and retain the real live status below the answer.
      const provisional: AcpmuxRow = {
        id: `concluding-${user.id}`,
        version: 1,
        at: final.at,
        kind: "turnSummary",
        status: "completed",
        // The running header's start, as it read it (`turnClock`): the turn's own, else its rows'.
        ...(turnStartedAtMs !== undefined && { turnStartedAtMs }),
        durationMs: Math.max(0, final.at - (turnStartedAtMs ?? user.at)),
      };
      const body = shapeTurn(
        user,
        [...turn, provisional],
        expanded,
        foldOpen,
        true,
        last,
        false,
        false,
        clockOffset,
        agentFamily,
        trayAgents,
        endedBackground,
        turnStartedAtMs,
      ).filter((row) => row.id !== provisional.id);
      if (!live) return body;
      const line = liveTurn(user, turn, clockOffset, trayAgents, turnStartedAtMs).at(-1);
      return line ? [...body, line] : body;
    }
  }
  // A turn still running shows its work as it happens, under its live status; one without a
  // summary that is no longer running draws as it came.
  if (end < 0)
    return live
      ? liveTurn(
          user,
          turn,
          clockOffset,
          trayAgents,
          turnStartedAtMs,
          turnFoldStyle(agentFamily).conclusion && isAgentPrompt(user),
          expanded.has(`${WORKED}-${user.id}`),
        )
      : last
        ? turn.flatMap(withoutDrafts)
        : settledWithoutSummary(turn);
  const summary = turn[end]!;
  // The agent's own wrap-up call (wrapUp.ts) is the card, not a row of its work.
  const worked = turn.slice(0, end);
  const wrapUp = summary.status === "completed" ? lastWrapUp(worked) : undefined;
  // A run of nothing but hidden discovery (ToolSearch) is no work: it opens no "Worked for". Nor is a
  // step that draws no row once the turn ends (`drawsNoWork`): a turn that died on an API error after
  // only an omitted thought folded it under a "Worked for" that opened to nothing (c-763204aef8).
  const body = withoutWrapUp(worked).filter(
    (row) => !isVisiblyEmptyMessage(row) && !hidesEveryCall(row) && !drawsNoWork(row),
  );
  // Each harness family ends a turn as its own app does (Leo, 2026-11-01: "separate it per
  // harness/model family. claude gets claude behaviour, codex gets codex"). Codex and ChatGPT fold
  // the whole turn's work under one "Worked for". Claude, as Claude desktop: no "Worked for"; each
  // run of calls, the short notes inside it with it, folds into its own summary line, and a longer
  // message between runs stays in place (Leo, 2026-11-04: "you can't do it for Claude ... it's just
  // too lossy if you do it for Claude"); its whole-turn "Worked for" is an opt-in only.
  // The family's row of the one table (turnFoldStyle.ts) says how: Codex and ChatGPT under one
  // "Worked for", Claude, Gemini and Muse with no turn fold.
  // A turn with little to hide draws flat, as the in-place family does (`foldsTurn`).
  const family = turnFoldStyle(agentFamily);
  // Flat: the family folds turns, but this one has too little to hide. Its replies stay plain replies
  // (no `settled`, no `foldedReply`): no fold holds them, so every answer reads as drawn
  // (replyAlwaysVisible.test.ts), unlike the `runs` arm, whose earlier replies draw as folded notes.
  const flat =
    family.conclusion && compactShortTurnsOn() && !foldsTurn(user, body, summary, live ? turnStartedAtMs : undefined);
  const style = flat ? CLAUDE_IN_PLACE : family;
  // Other agents' messages that started the turn fold into its "Worked for" once it ends, as its
  // first entries (Leo, 2026-11-07: "fold the receiving and sending messages into the worked for as
  // well? Like the nearest one?"); shapedTurn draws them there.
  const foldsPrompt = !live && style.conclusion && isAgentPrompt(user);
  // Notification turns can contain an empty assistant segment and a summary solely for
  // bookkeeping. With no visible prompt or work, omit the whole turn, including its footer.
  if (isVisiblyEmptyMessage(user) && body.length === 0 && summary.status === "completed") return [];
  // Each message that came in mid-turn ends a fold of its own (`inOrder`, foldSegments), so the work
  // after it folds below it and nothing draws above a message it came after.
  const inOrder = style.conclusion && experimentArm(turnFoldSteered) === "in-order";
  const segments = foldSegments(user, body, inOrder);
  const answer = segments.find((segment) => segment.takeaway)?.takeaway;
  const firstFinal = body.find(isFinalAnswer);
  // The turn's one clock (`turnClock`): the "Worked for" reads what its "Working for" read, from the
  // same start to the same end.
  const workedDurationMs = turnClock(user, body, live ? turnStartedAtMs : undefined, summary).durationMs;
  // A tagged ask the answer ends on (nextStepAsk.ts) draws as a card under it, answerable until a
  // later prompt picks one of its answers or the person moves on past a later card
  // (`settleNextSteps`), whatever turns come between. Read once per ended turn, never while the turn
  // runs. A turn that stopped or failed keeps the ask in its prose.
  // The agent's wrap-up call goes before a tagged ask in its prose, and stays as the turn's recap
  // once a prompt follows. A recap alone needs no reply to wait for.
  // Another agent's message that opens the next turn answers nothing: the question was the person's
  // to answer, and it stays theirs (Leo, 2026-11-06, on a question the next agent's message took
  // back: "we want to keep these things rendered, and perhaps persistent at the bottom").
  const tagged = !live && !wrapUp && summary.status === "completed" ? nextStepAsk(answer?.text) : undefined;
  // A tagged ask another message cut off: the agent asked, another agent's message steered into the
  // turn before it ended, and the agent went on to answer that message, so the ask is no longer the
  // turn's last word. It is still the person's question (Leo, 2026-11-06: "It was about you asking a
  // question to me that had a question-answer response and then another message from another agent
  // interrupted you and then there's nothing now"): its card draws under the reply that asked it.
  const cutOff = !live && !wrapUp && !tagged && summary.status === "completed" ? steeredAsk(body) : undefined;
  const nextStep = live ? undefined : (wrapUp ?? tagged ?? cutOff?.ask);
  // The turn's last browser walkthrough, read once the turn has ended; drawn once, under the answer.
  const walked = live ? undefined : lastWalkthrough(worked);
  let walkedDrawn = false;
  // The next-step card draws once per turn: under the answer, in its fold, or after the turn's last.
  let cardDrawn = false;
  const shaped: AcpmuxRow[] = [];
  // A derived row's version must change whenever what it draws does: the memoized rows and the
  // height cache compare versions only. Answer versions stay far below VERSION_SPAN.
  const version = summary.version * VERSION_SPAN + (answer?.version ?? 0);
  const edits: AcpmuxRow[] = [];
  const replies = repliesIn(body);
  // How the closed fold treats the earlier replies (turnFoldReplies.experiment.ts). The `answer` arm,
  // the default, keeps only the final answer beside the closed fold: every earlier message folds
  // with the work, however long, and reads in order once the fold opens, where `replies` still marks
  // each so it keeps its action row (Lawrence, 2026-11-19: "in collapsed, literally everything but
  // final assistant message should be collapsed"). A reply whose question another agent's message
  // cut off stays out: its card waits on the person, under it (`cutOff`). A turn with no answer (a
  // Codex turn that failed before its `final_answer`) keeps its last reply out instead, so the closed
  // fold never hides everything the agent said.
  const repliesArm = experimentArm(turnFoldReplies);
  const lastWords = answer
    ? undefined
    : [...body].reverse().find((row) => replies.has(row.id) && row.inBackground === undefined);
  const keptByArm: ReadonlySet<string> =
    repliesArm === "answer"
      ? new Set([...(cutOff ? [cutOff.reply.id] : []), ...(lastWords ? [lastWords.id] : [])])
      : replies;
  const allSteerDialogue = steerDialogueIn(body);
  // The `stacked` and `inline` arms (turnFoldSteered.experiment.ts) fold the whole turn under its one
  // Worked for, the reply before each steer with it: `stacked` keeps the person's steers in sight,
  // drawn under the prompt (`stackSteers`), `inline` folds them too, each where it arrived.
  const steerLayout = style.conclusion && allSteerDialogue.size ? experimentArm(turnFoldSteered) : undefined;
  const foldsSteerReplies = steerLayout === "stacked" || steerLayout === "inline";
  const steerReplies = foldsSteerReplies
    ? new Set([...allSteerDialogue].filter((id) => body.some((row) => row.id === id && row.kind !== "user")))
    : undefined;
  const keptOut: ReadonlySet<string> = steerReplies
    ? new Set([...keptByArm].filter((id) => !steerReplies.has(id) || id === cutOff?.reply.id))
    : keptByArm;
  const steerDialogue: ReadonlySet<string> =
    steerLayout === "inline"
      ? new Set()
      : steerReplies
        ? new Set([...allSteerDialogue].filter((id) => !steerReplies.has(id)))
        : allSteerDialogue;
  // A turn the person steered still has one fold (Leo, 2026-11-07, on a closed "Worked for 5m 15s"
  // with "Finished 2 background tasks and ran 8 commands" beside it: "this could have been, like,
  // tucked inside the worked for"). The reply before the steer and the steer stay in sight
  // (`steerDialogue`), but the work around them stays under Worked for rather than drawing as run lines
  // beside it; opened, those run lines draw open, "as if you just expanded the whole worked for
  // entirely" (turnFoldSteered.experiment.ts).
  const steeredArm = !inOrder && style.conclusion && allSteerDialogue.size ? experimentArm(turnFoldSteered) : undefined;
  const nested = steeredArm !== undefined && steeredArm !== "split";
  const runsOpen = nested && steeredArm !== "nested";
  let folded = false;
  // Where the sub-sessions a folded turn started stay in sight (taskLine.experiment.ts).
  const taskLook = style.conclusion ? experimentArm(finishedTaskLook) : undefined;
  // A completed turn gets one fold for its work; personal steers keep their dialogue visible. The
  // row boundary above is still opensTurn/continuesTurn: an unrelated incoming prompt starts a
  // separate turn and is never gathered by adjacency alone.
  for (const segment of segments) {
    const said = segment.takeaway;
    const first = segment.anchor === user;
    // The turn's last disclosure ends with it: its status is the turn's.
    const final = segment.until === undefined;
    const before = segment.rows;
    const after = segment.after ?? [];
    // Work after the last answer folds with the work before it, so the answer stays last.
    // Edits after it join the card too, so its Undo covers the whole turn.
    const id = `${WORKED}-${segment.anchor.id}`;
    // A turn another agent's message started that only replied still ends on its "Worked for": its
    // "Working for" stood over the message from the turn's first frame (shapeLiveTurn `foldsPrompt`),
    // and a header gone at the end would pull the message up into its place. It holds the message
    // alone, open until a click closes it (`repliesOnly`); the replies draw as they ran.
    const promptOnly = foldsPrompt && first && segments.length === 1 && repliesOnly([...before, ...after]);
    // A family with no turn fold draws as an open "Worked for" without the line.
    // Split in order, a received message inside the fold that a history page started at keeps its
    // provisional key (openFolds); a steer that closes it is the next fold's anchor, not its own.
    const open =
      !style.conclusion ||
      foldOpen ||
      expanded.has(id) ||
      ((isStopped(summary) || promptOnly) && !expanded.has(closedTurnFoldKey(id))) ||
      (inOrder &&
        [...before, ...after].some(
          (row) =>
            row.kind === "user" &&
            continuesTurn(row) &&
            expanded.has(`${WORKED}-${row.id}`) &&
            !segments.some((other) => other.anchor === row),
        ));
    // A call still waiting for its permission stays in sight: beside the closed fold, and in its
    // folded run once the fold opens (TurnRows.tsx `staysInSight`).
    // The final answer always draws beside the closed line. Under the default `answer` arm every
    // earlier reply folds with the work (`keptOut`, Lawrence, 2026-11-19); the other arms keep each
    // reply in its place among the lines of the work around it (`aroundReplies`; Leo, 2026-11-06:
    // "your intermediate message got lost. that can never happen").
    // A `final_answer` before another agent's message is an earlier message too: under the `answer`
    // arm only the turn's answer (`said`, drawn below) stays beside the closed fold. A turn that only
    // replied to another agent's message (`promptOnly`) draws its replies as they ran, each final one too.
    const out = (row: AcpmuxRow) =>
      ((repliesArm !== "answer" || promptOnly) && isFinalAnswer(row)) ||
      staysOut(row) ||
      (!open && taskLook === "card" && startsTask(row)) ||
      (!open &&
        (steerDialogue.has(row.id) ||
          keptOut.has(row.id) ||
          (row.kind === "activity" && (row.items ?? []).some((item) => awaitsPermission(item.tool)))));
    const work = [...before, ...after].filter((row) => !out(row));
    // A row drawn beside the closed fold is not in the card too: the card takes its first row's id.
    // A file change that never got its input changed nothing (toolGroups.ts `isDraftCall`).
    edits.push(...work.flatMap(withoutDrafts).filter(isEdit));
    // A turn of nothing but the agent's replies and the person's own steers did no work to fold:
    // it stays drawn as it ran, the steer between the replies (agent-pane-steer-split.test.ts).
    // Reports received from other agents fold like work.
    const dialogue = work.every(isDialogue);
    // Opened, the person's steer after the answer draws in the fold, in its place: the answer draws
    // in its own place too, above the steer it came before, never moved under it (Leo, 2026-11-12:
    // "in this case you didnt respond to me at all..."). A card or strip under it keeps it last.
    // Only where the fold draws its work: a turn of dialogue alone draws as it ran.
    const inPlace =
      open &&
      work.length > 0 &&
      !dialogue &&
      said !== undefined &&
      !(nextStep && !cutOff && said === answer) &&
      !(walked && said === answer && !walkedDrawn) &&
      after.some((row) => row.kind === "user" && steerDialogue.has(row.id));
    // The tasks this fold hides, as one line each beside it (TaskLine.tsx).
    const tasks = !open && taskLook && taskLook !== "card" && work.length && !dialogue ? startedTasks(work) : [];
    const taskLine: AcpmuxRow | undefined = tasks.length
      ? { id: `${TASK_LINE}-${segment.anchor.id}`, version, at: segment.anchor.at, kind: TASK_LINE, tasks }
      : undefined;
    // Its label counts the fold's messages (`previous`), which can change while the summary's and
    // the answer's versions do not: the count is part of the version, so the memoized row redraws.
    // A reply kept beside the fold (`keptOut`) is never one of the fold's messages, open or closed.
    // Other agents' messages that started the turn fold in too, as its first entries (`foldsPrompt`).
    const hidden = promptOnly
      ? [user]
      : [...(foldsPrompt && first ? [user] : []), ...work.filter((row) => !keptOut.has(row.id))];
    const previous = style.countsMessages && foldMixesMessages(hidden) ? foldedMessages(hidden) : undefined;
    // The messages between agents it folds count as calls by default (workedForMessages.experiment.ts).
    const messages = foldedAgentMessages(hidden);
    const messagesArm = experimentArm(workedForMessages);
    // A turn split in order counts each fold's own calls; one fold counts the turn's.
    const calls = segments.length > 1 ? callsIn(work) : summary.toolCount;
    const toolCount = messagesArm === "calls" && calls !== undefined ? calls + messages.received : calls;
    const named = messagesArm === "messages" && messages.sent + messages.received > 0;
    // Unknown stays unknown (the label counts calls instead): a turn whose prompt is in an older
    // page starts at a row inside it, and the time since that row is too short.
    const durationMs =
      segments.length === 1
        ? workedDurationMs
        : first && user.kind !== "user"
          ? undefined
          : Math.max(0, (segment.until ?? firstFinal?.at ?? summary.at) - segment.anchor.at);
    // A fold with no time and nothing counted would read "0 tool calls" over, say, a subagent's end
    // alone: it draws no fold, its rows in place (`outside`), nor does a turn of subagents alone with
    // no recorded time. A quick one keeps its fold, "Worked for <1s" (`turnSpan`): the "Working for"
    // that stood over it while it ran stays, so the end swaps no line for loose rows (Leo, 2026-11-25:
    // "i think it was replacing the "worked for" as it went", after cmux#55191 dropped its fold).
    const shown = shownAgentNames(body);
    // Only with no reply of its own: a reply's turn folds a subagent's end under its Worked for, as a
    // call (Leo, 2026-11-24: "we can indeed treat them as tool calls").
    const lone = said === undefined && subagentsOnly(work, shown);
    // A stretch before a steer whose only work was compacting the conversation draws no "Worked
    // for" of its own: its note stays in place, and the turn's one fold is the work after the steer
    // (Leo, 2026-11-25: "the worked for for collapsing the compaction and then the next worked for
    // + thinking is weird. layout shifts and awkward looking animations"). A /compact alone ends the
    // same way: its note ("Compacted · 152k → 18k") stays in the place its live "Compacting" line
    // held, never shut inside a "Worked for 1s" that hides what it did. A turn stopped mid-compaction
    // keeps its "You stopped after" line: the stop is news, and a stopped turn's fold opens, so the
    // note stays in sight under it (agent-pane-steer.test.ts, a forced Stop reads as a plain stop).
    const compactOnly = said === undefined && onlyCompaction(work) && !(final && isStopped(summary));
    const unlabeled =
      compactOnly ||
      (previous === undefined &&
        messages.sent + messages.received === 0 &&
        ((durationMs === undefined && !toolCount && callsIn(work) === 0) || (durationMs === undefined && lone)));
    if ((work.length && !dialogue && !unlabeled) || promptOnly) {
      if (!promptOnly) folded = style.conclusion;
    } else if (lone) {
      // Its footer says no count or time under the subagent's row either (`footerSays`).
      folded = style.conclusion;
    }
    if ((work.length && !dialogue && !unlabeled) || promptOnly) {
      const from = segment.anchor.at;
      // The `header` arm names the work on the line itself ("Worked for 5m 15s · Finished 2 background
      // tasks and ran 8 commands"), as every arm of workedLine but `time` does for any turn.
      // workedLine's arms count edits too, so they read every call the fold holds, edit rows included.
      const lineArm = experimentArm(workedLine);
      const workedRuns =
        steeredArm === "header" || lineArm !== "time"
          ? hidden
              .flatMap(withoutDrafts)
              .flatMap((row) =>
                isRun(row) || (lineArm !== "time" && row.kind === "activity")
                  ? (row.items ?? []).filter((item) => item.tool)
                  : [],
              )
          : [];
      // The calls the fold hides, for the line's counts once Settings > Advanced > Experiments >
      // Fold Summary Counts is on (`workedCountsText`): the switch is read where the line draws, so
      // flipping it redraws the line without shaping the turn again.
      const foldCalls = hidden
        .flatMap(withoutDrafts)
        .flatMap((row) => (row.kind === "activity" ? (row.items ?? []).filter((item) => item.tool) : []));
      const labelVersion = mixVersion(
        (version * 2 + (open ? 1 : 0)) * PREVIOUS_SPAN + Math.min(PREVIOUS_SPAN - 1, previous ?? 0),
        named ? messages.sent * 1_000 + messages.received + 1 : 0,
      );
      const runsVersion = workedRuns.length ? mixVersion(labelVersion, workKey(workedRuns)) : labelVersion;
      const worked: AcpmuxRow = {
        id,
        // What its label names (`named`, the `header` arm's work and the calls its counts name, each
        // by `workKey`) is part of the version too.
        version: foldCalls.length ? mixVersion(runsVersion, workKey(foldCalls)) : runsVersion,
        at: from,
        kind: WORKED,
        foldOpen: open,
        status: final ? summary.status : "completed",
        toolCount,
        ...(named && { workedMessages: messages }),
        // The turn's one outer count, over the runs that each count their own (Leo, 2026-11-07: "do you
        // think we should distinguish the absolute top level one versus the inner ones").
        ...(style.countsCalls && (calls ?? 0) > 0 ? { workedCalls: calls } : {}),
        // It stands for the prompt it folds as the turn's start, open or closed, so the minimap keeps
        // the turn's tick where the closed fold draws no prompt (threadMinimap/model.ts minimapTurns).
        ...(foldsPrompt && first && { foldedPrompt: user }),
        // The turn's tokens stay on its first fold, keyed by its prompt, as one fold carries them.
        ...(first && { tokens: summary.tokens }),
        durationMs,
        // Codex's header (Leo, 2026-11-02: "i assume the x previous messages are when there's a mix
        // and the worked for is if it's one contiguous thing ... let's follow those"): work with the
        // agent's own messages between it reads "N previous messages", one stretch of work alone
        // "Worked for".
        ...(previous !== undefined && { previous }),
        ...(workedRuns.length && { workedRuns }),
        ...(foldCalls.length && { foldCalls }),
      };
      if (style.conclusion) shaped.push(worked);
      if (taskLine && taskLook === "after-fold") shaped.push(taskLine);
      // Open, each run of its work folds into its summary line between the commentary, as in a
      // running turn (codexRuns). A run that edited folds too: its edits stay in sight between the
      // summary lines of the work around them (TurnRows.tsx `runStretches`).
      // A steer's reply never joins a run: it stays in sight beside the steer.
      const merge = (rows: readonly AcpmuxRow[]) =>
        mergeShortNotes(
          rows.filter((row) => !out(row)),
          steerDialogue,
          style.runs,
          !style.conclusion,
        );
      if (open && !promptOnly)
        shaped.push(
          // The answer between `before` and `after` is a seam: the runs on either side of it stay apart.
          ...[...merge(before), ...(inPlace ? [said] : []), ...merge(after)].flatMap(withoutDrafts).map((row) => ({
            ...row,
            id: isEdit(row) ? `${row.id}${FOLDED}` : row.id,
            ...(!(flat && replies.has(row.id)) && { settled: true }),
            // A finished turn's earlier replies fold here too; each keeps its action row, while a
            // short note stays quiet (Leo, 2026-10-29: replies keep their action row).
            ...(replies.has(row.id) && row !== said && !flat && { foldedReply: true }),
            // A folded run draws otherwise, so its version moves (memos compare versions).
            ...(row.kind === "activity" && { foldRun: true, version: row.version * RUN_STATES + 3 }),
            // A steered turn's run lines open with its Worked for (`runsOpen`): the open fold's state,
            // doubled, so the run redraws without a sixth `RUN_STATES` (`OPEN_RUN_STATES`).
            ...(runsOpen &&
              row.kind === "activity" && {
                runOpen: true as const,
                version: (row.version * RUN_STATES + 3) * OPEN_RUN_STATES + 1,
              }),
          })),
        );
    }
    // Context and actionable rows stay available beside the fold. Render cards keep their
    // source order among them, before or after the answer exactly where the call happened.
    const outside = (rows: readonly AcpmuxRow[]) =>
      rows.flatMap((row) =>
        out(row)
          ? [row]
          : dialogue
            ? [row]
            : // An unfolded segment's rows draw as they ran; its edits draw in the card (`editsCard`),
              // and an Agent call whose subagent's row is in sight draws as that row alone.
              unlabeled
              ? withoutDrafts(row).filter((part) => !isEdit(part) && !onlySpawnsShownAgents(part, shown))
              : renderRows([row], version),
      );
    // Closed over a turn that said something before its answer, the default `answer` arm folds those
    // replies with the work; the `replies` arm keeps them in order with the work under Worked for, as
    // chatgpt.com draws it: no tool call shows beside a closed fold. The other arms fold that work
    // into lines before and after each reply (turnFoldReplies.experiment.ts).
    // A steered turn's one fold keeps every run under Worked for (`nested`): its replies alone draw.
    const around = open || repliesArm === "answer" ? undefined : nested ? "replies" : repliesArm;
    const between =
      around !== undefined && around !== "replies" && before.some((row) => replies.has(row.id) && out(row))
        ? (rows: readonly AcpmuxRow[]) => aroundReplies(rows, out, outside, around, steerDialogue, style.runs)
        : outside;
    shaped.push(...between(before));
    // Waiting as shaped: whether a later prompt answered it is `settleNextSteps`'s to say.
    const card = (at: number): AcpmuxRow => ({
      id: `${NEXT_STEP}-${segment.anchor.id}`,
      version: version * SETTLED_STATES,
      at,
      kind: NEXT_STEP,
      nextStep: { ask: nextStep! },
    });
    const strip = (at: number): AcpmuxRow => {
      walkedDrawn = true;
      return { id: `${WALKTHROUGH}-${user.id}`, version, at, kind: WALKTHROUGH, walkthrough: walked };
    };
    const underAnswer = Boolean(said && nextStep && !cutOff && said === answer);
    const stripUnder = Boolean(walked && said && said === answer && !walkedDrawn);
    if (underAnswer) {
      // A wrap-up's answer stays whole. A tagged ask's answer drops the ask's lines, which the
      // card draws; a new version, so its memo redraws.
      if (wrapUp) shaped.push(said!);
      else if (nextStep!.rest) shaped.push({ ...said!, text: nextStep!.rest, version: said!.version * 2 + 1 });
      if (stripUnder) shaped.push(strip(said!.at));
      shaped.push(card(said!.at));
      cardDrawn = true;
    } else if (said && !inPlace) {
      shaped.push(said);
      if (stripUnder) shaped.push(strip(said.at));
    }
    shaped.push(...between(after));
    // A wrap-up in a turn with no answer to hang under goes after the turn's last row, under its
    // walkthrough: the strip always draws before the card.
    if (nextStep && wrapUp && !cardDrawn && final) {
      if (walked && !walkedDrawn) shaped.push(strip(summary.at));
      shaped.push(card(summary.at));
    }
    // A cut-off ask goes right under the reply that asked it, which drops the ask's lines; where
    // that reply is out of sight (in a closed fold), after the turn's last row, the reply whole.
    // Once, after the turn's last fold, which sees every row drawn before it.
    if (cutOff && final) {
      const asked = shaped.findIndex((row) => row.id === cutOff.reply.id);
      if (asked < 0) shaped.push(card(summary.at));
      else {
        const reply = shaped[asked]!;
        const rest = cutOff.ask.rest ? [{ ...reply, text: cutOff.ask.rest, version: reply.version * 2 + 1 }] : [];
        shaped.splice(asked, 1, ...rest, card(reply.at));
      }
    }
    if (taskLine && taskLook === "after-reply" && !unlabeled) shaped.push(taskLine);
  }
  // A walkthrough in a turn with no answer to hang under goes after the turn's last row.
  if (walked && !walkedDrawn)
    shaped.push({ id: `${WALKTHROUGH}-${user.id}`, version, at: summary.at, kind: WALKTHROUGH, walkthrough: walked });
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
  // acpmux's next attempt of a failed prompt is `P~resume-n` (hub/auto_resume.rs SUFFIX): one that
  // failed too says so on its card (cmux#34369).
  const failedAgain = isFailed(summary) && /~resume-\d+$/.test(user.promptId ?? "");
  const continuable =
    offers && lastSummary < 0 && isFailed(summary) && (noticeStarted || body.some((row) => row.kind !== "user"));
  // The hint is only rendered for a settled retry target. Avoid scanning the turn body on each
  // live snapshot/token while the turn is still running.
  const changedFiles = (retryable || retryTarget) && !live ? turnChangedFiles(body) : false;
  // The summary is in, so the body's work is settled. A turn still `live` here is the last one with a
  // prompt just sent behind it (not accepted yet, so it sorts into this turn) or a background run in
  // its tail: its footer keeps its Timeline then. Dropping it for that window and putting it back when
  // the prompt was accepted moved the footer's Read aloud by one button on every send. One pass over
  // the body, as turnCopyParts below.
  const work = turnWork(body);
  const copyParts = turnCopyParts(body);
  const stoppedQuietly = isStopped(summary) && !turnCopySaid(copyParts);
  // The chat's last turn, ended, whose GitHub call found no connection for this chat: its footer
  // draws one Connect GitHub card (githubConnect.ts), gone once a prompt follows the turn.
  const githubConnect = offers ? githubConnectNeed(body) : undefined;
  shaped.push({
    ...summary,
    folded,
    text: answer?.text ?? summary.text,
    // The footer's Copy copies the whole turn (turnCopy.ts): its replies and tool lines in order. A
    // stopped turn that only ran calls keeps no band: it resumes from the composer (ContinueAfterStop).
    turnCopy: stoppedQuietly ? undefined : copyParts,
    // Its timed calls, for the footer's Timeline (waterfallSpans.ts).
    ...(work && { turnWork: work }),
    ...(resumable && { resumable }),
    ...(retryable && { retryable }),
    ...(retryTarget && { retryTarget }),
    ...(continuable && { continuable }),
    ...(failedAgain && { failedAgain: true as const }),
    ...(changedFiles && { changedFiles: true as const }),
    ...(githubConnect && { githubConnect }),
    ...(answer && { answerId: answer.id }),
    // Retry sends the prompt as the agent got it: an incoming message with its sender. A
    // notification, or acpmux's inbox notice, is not a prompt to send again (incomingMessage.ts).
    // The retry target's prompt (``isRetryablePrompt``, which implies the rest), or, as on base, the
    // chat's last turn's for a failed turn's Retry (TurnFooter `failedRetry`, unchanged). An
    // attachment-only retry target carries an empty `prompt`: Retry sends its attachments again by
    // `retryRowId`. Failed turns keep the same metadata for attachment-aware recovery when the
    // daemon cannot retry the original turn.
    ...((retryable || retryTarget) &&
      user.incoming?.kind !== "notice" &&
      user.incoming?.kind !== "inbox" &&
      ((user.resend ?? user.text) || (retryTarget && resendsAttachments(user))) && {
        prompt: (user.resend ?? user.text) || "",
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
  // A turn the agent started on its own while still working: once it runs tools
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
  // Each turn the agent ran on its own that has ended folds as a prompt's turn does: its work under
  // one closed "Worked for", its reply and footer in sight (cmux#49592: "sometimes we are still
  // showing too much tool calls and stuff, it's not fully collapsed"). While a later one runs, only
  // the rows after the last ended one are the running turn's.
  let settledEnd = answered.length;
  if (live) {
    settledEnd = 0;
    for (let at = answered.length - 1; at >= 0; at -= 1)
      if (answered[at]!.kind === "turnSummary") {
        settledEnd = at + 1;
        break;
      }
  }
  const settled = foldTailTurns(answered.slice(0, settledEnd), expanded, endedBackground, clockOffset, agentFamily);
  // While the chat still works after the last one ended, the live line takes its footer's slot and the
  // footer comes back in it at the end (liveLineTakesFooterSlot.test.ts); a failed or stopped one keeps
  // its summary.
  const footer = settled.at(-1);
  if (live && settledEnd === answered.length && footer?.kind === "turnSummary" && footer.status === "completed")
    settled.pop();
  shaped.push(...settled);
  const rest = settledEnd === 0 ? answered : answered.slice(settledEnd);
  if (live && (tail.some((row) => row.kind === "activity") || tail.slice(lastSummary + 1).some(isReply)))
    shaped.push(...liveTurn({ ...summary, at: since }, rest, clockOffset, trayAgents, turnStartedAtMs));
  else shaped.push(...(live ? rest : endedTail(rest)));
  return shaped;
}

/// The fold key of the "Worked for" over an ended turn the agent ran on its own (`foldTailTurns`): its
/// background line's id, under the turn fold's prefix.
const tailWorkedId = (background: string) => `${WORKED}-${backgroundTurnRowId(background)}`;

/// The background turn whose "Worked for" fold `id` is (`tailWorkedId`), or undefined for another fold.
const tailWorkedBackground = (id: string) => {
  const prefix = `${WORKED}-${backgroundTurnRowId("")}`;
  return id.startsWith(prefix) ? id.slice(prefix.length) : undefined;
};

/// The ended turns the agent ran on its own in a turn's tail (each up to and with its summary), each
/// shaped as `shapeTurn` shapes a prompt's turn, anchored at its background line: the line, one
/// "Worked for" over its work (closed until the reader or Find opens it), its reply and its footer.
/// Before, each run of calls drew as its own line beside the reply, so a coordinator woken by
/// background tasks all day read every call it made (cmux#49592). A stretch that names no ended
/// background turn of this turn (`endedBackground`) draws as before (`endedTail`).
function foldTailTurns(
  rows: readonly AcpmuxRow[],
  expanded: Folds,
  endedBackground: ReadonlySet<string>,
  clockOffset: number,
  agentFamily: string | undefined,
): AcpmuxRow[] {
  if (rows.length === 0) return [];
  const out: AcpmuxRow[] = [];
  let from = 0;
  const flush = (to: number) => {
    out.push(...foldTailTurn(rows.slice(from, to), expanded, endedBackground, clockOffset, agentFamily));
    from = to;
  };
  // The background turn the stretch from `from` belongs to, once a row names it.
  let owner: string | undefined;
  for (let at = 0; at < rows.length; at += 1) {
    const row = rows[at]!;
    const id = row.kind === BACKGROUND_TURN ? row.background?.id : row.inBackground;
    // A turn that ended on no row of its own (turnEndActions.experiment.ts) ends where the next starts.
    if (id !== undefined && owner !== undefined && id !== owner) flush(at);
    if (id !== undefined && from === at) owner = id;
    else owner ??= id;
    if (row.kind === "turnSummary") {
      flush(at + 1);
      owner = undefined;
    }
  }
  // Only ended turns reach here (a running one's rows follow the last summary), so the rest folds too.
  if (from < rows.length) flush(rows.length);
  return out;
}

function foldTailTurn(
  stretch: AcpmuxRow[],
  expanded: Folds,
  endedBackground: ReadonlySet<string>,
  clockOffset: number,
  agentFamily: string | undefined,
): AcpmuxRow[] {
  const lineAt = stretch.findIndex((row) => row.kind === BACKGROUND_TURN && row.background !== undefined);
  const line = lineAt >= 0 ? stretch[lineAt] : undefined;
  const background = line?.background?.id ?? stretch.find((row) => row.inBackground !== undefined)?.inBackground;
  if (background === undefined || !endedBackground.has(background)) return endedTail(stretch);
  // What came before its line (a late update of an earlier call) draws as it came.
  const before = line ? stretch.slice(0, lineAt) : [];
  const drawn = line ? stretch.slice(lineAt + 1) : stretch;
  if (drawn.length === 0) return endedTail(stretch);
  // One that ended on no row of its own still folds, under a summary that draws nothing.
  const provisional: AcpmuxRow | undefined =
    drawn.at(-1)!.kind === "turnSummary"
      ? undefined
      : {
          id: `${BACKGROUND_END}-${background}${FOLDED}`,
          version: 1,
          at: drawn.at(-1)!.at,
          kind: "turnSummary",
          status: "completed",
          durationMs: Math.max(0, drawn.at(-1)!.at - drawn[0]!.at),
        };
  const body = provisional ? [...drawn, provisional] : drawn;
  // A background line drawn nowhere still keys the fold (`tailWorkedId`), which Find opens for a row
  // inside it (`turnFoldFor`).
  const anchor: AcpmuxRow = line ?? {
    id: backgroundTurnRowId(background),
    version: 1,
    at: body[0]!.at,
    kind: BACKGROUND_TURN,
  };
  const shaped = shapeTurn(
    anchor,
    body,
    expanded,
    false,
    false,
    false,
    false,
    false,
    clockOffset,
    agentFamily,
    0,
    endedBackground,
  );
  // Its footer keeps what `backgroundFooters` gave it to copy: a turn of calls alone copies its
  // calls (`turnCallParts`), which shapeTurn, reading replies, would drop.
  const footer = body.at(-1)!;
  // A quiet turn has nothing to tell (acpmux's word): its wrap-up folds with its work, no card.
  const quiet = line?.background?.quiet === true;
  return [
    ...endedTail(before),
    ...(line ? [line] : []),
    ...shaped.flatMap((row) =>
      (quiet && row.kind === NEXT_STEP) || row.id === provisional?.id
        ? []
        : row.kind === "turnSummary" && row.id === footer.id && !row.turnCopy && footer.turnCopy
          ? [
              {
                ...row,
                turnCopy: footer.turnCopy,
                ...(footer.turnWork && !row.turnWork && { turnWork: footer.turnWork }),
              },
            ]
          : [row],
    ),
  ];
}

/// An ended tail (the turns the agent ran on its own after the prompt's turn, with no turn running now)
/// as the running turn's shape draws its ended part (`codexRuns`): each run folded into its summary
/// line. While any later turn ran, `liveTurn` folded these runs; once the chat stopped they drew
/// unfolded, every group of calls on its own line, and folded again when the next background turn
/// started. A coordinator woken by background tasks every few seconds read its earlier turns
/// collapse and expand, the rows under them jumping and the turn's end fold drawing its copies over
/// them (cmux#45943: "content loads/unloads and blinks while the agent writes or thinks"; the
/// doubled, overlapping paragraphs of the same report). A run whose own row stays (a change awaiting
/// its permission, a call that keeps its own row while it runs) stays as `codexRuns` keeps it.
function endedTail(rows: readonly AcpmuxRow[]): AcpmuxRow[] {
  const out: AcpmuxRow[] = [];
  for (const row of rows) {
    const items = row.items ?? [];
    // A row with no calls (a background turn's bare activity) has no run to fold and draws as it came.
    const folds =
      row.kind === "activity" &&
      items.length > 0 &&
      !items.some((item) => awaitsPermission(item.tool) || (keepsOwnRow(item.tool) && isRunning(item.tool!)));
    for (const drawn of folds ? earlierRun(row, undefined) : withoutDrafts(row)) out.push(drawn);
  }
  return out;
}

/// `tail` with each of its summaries carrying the reply of the turn it ends and the turn to copy, as
/// `shapeTurn` gives the prompt's own summary: the footer under a turn that said anything is a 32 row
/// of its own, never an empty one laid over the gap (transcriptGrid.ts MARK_FOOTER_ROW). A summary
/// after a turn that said nothing stays as it came.
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
    const parts = turnCopyParts(body);
    if (!answer && !parts) continue;
    out ??= [...tail];
    // The memoized footer redraws when its turn's rows do.
    const key = body.reduce((sum, each) => (sum * 31 + each.version) % VERSION_SPAN, body.length);
    out[at] = {
      ...row,
      ...(answer && { text: answer.text, answerId: answer.id }),
      turnCopy: parts,
      ...withWork(body),
      version: row.version * VERSION_SPAN + key,
    };
  }
  return backgroundFooters(out ?? tail, endedBackground, seq);
}
const NO_ENDED_BACKGROUND: ReadonlySet<string> = new Set();

/// A finished stretch's timed work, for its footer's Timeline (waterfallSpans.ts), when it has any.
function withWork(rows: readonly AcpmuxRow[]): Pick<AcpmuxRow, "turnWork"> {
  const work = turnWork(rows);
  return work ? { turnWork: work } : {};
}

/// The id prefix of the footer `backgroundFooters` adds under a turn the agent ran on its own.
export const BACKGROUND_END = "backgroundEnd";

/// The ids of the turns the agent ran on its own in `rows` that ended and draw their rows: one that
/// ended with something to say (backgroundTurns.ts `foldsBackground`), and inline one acpmux called
/// quiet, whose calls draw where they ran (`hiddenInBackground`) though its reply does not. A running
/// one, and a quiet one folded to its line, draw none of their own.
function endedBackgroundTurns(rows: readonly AcpmuxRow[]): ReadonlySet<string> {
  const ended = new Set<string>();
  for (const row of rows) if (endsDrawingRows(row)) ended.add(row.background!.id);
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
///
/// A turn that ran calls and said nothing after them (acpmux calls it quiet: no reply to tell, its
/// calls draw where they ran) ends on its row too, with its calls to copy (`turnCallParts`): it drew
/// its calls and then nothing, so the chat's last rows had no buttons under them while every reply
/// above did (Leo, 2026-11-21: "there's no buttons at the bottom even thuogh you have visibly stopped
/// doing things"). Its row has no text, so Read aloud reads nothing it did not draw.
/// turnEndActions.experiment.ts holds the arms: every such turn (default), only the chat's last, none.
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
  const callsArm = experimentArm(turnEndActions);
  // The turn ending on calls alone that may end on its row in the `last` arm: the tail's last one.
  let lastBody: { rows: AcpmuxRow[]; last: number } | undefined;
  for (const body of bodies.values()) if (!lastBody || body.last > lastBody.last) lastBody = body;
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
    if (answer?.streaming) return;
    const callsAlone = !answer && (callsArm === "every" || (callsArm === "last" && body === lastBody));
    const parts = answer ? turnCopyParts(body.rows) : callsAlone ? turnCallParts(body.rows) : undefined;
    if (!parts) return;
    out.push({
      id: `${BACKGROUND_END}-${id}`,
      kind: "turnSummary",
      // The memoized footer redraws when its turn's rows do.
      version: body.rows.reduce((sum, each) => (sum * 31 + each.version) % 2_147_483_647, body.rows.length),
      at: row.at,
      status: "completed",
      durationMs: Math.max(0, row.at - body.rows[0]!.at),
      ...(answer && { text: answer.text, answerId: answer.id }),
      turnCopy: parts,
      ...withWork(body.rows),
      ...(through !== undefined && { seq: through }),
    });
  });
  return out;
}

const VERSION_SPAN = 1_000_000;
/// Room in a Worked for row's version for its fold's message count (`previous`).
const PREVIOUS_SPAN = 4096;
/// The range of the key a Worked for row's version mixes in for the work its `header` arm names (`workKey`).
const WORK_SPAN = 256;

/// What the `header` arm's line says of the work it holds (toolRunSummary.ts reads each call's kind,
/// title, state, background state and files), as one number in 1..WORK_SPAN-1, 0 for no work: a
/// late background end or a call's path or category changes the line's text, so it changes the
/// version too and the memoized row (WorkedRow.tsx) draws again (review of cmux#37710).
function workKey(runs: readonly AcpmuxActivity[]): number {
  if (!runs.length) return 0;
  // FNV-1a over the fields the summary reads.
  let hash = 0x811c9dc5;
  const mix = (text: string) => {
    for (let at = 0; at < text.length; at += 1) hash = Math.imul(hash ^ text.charCodeAt(at), 0x01000193);
    hash = Math.imul(hash ^ 0x1f, 0x01000193);
  };
  for (const { tool } of runs) {
    if (!tool) continue;
    mix(tool.id ?? "");
    mix(tool.kind ?? "");
    mix(tool.title ?? "");
    mix(tool.status ?? "");
    mix(String(tool.exitCode ?? ""));
    mix(tool.background?.state ?? "");
    for (const location of tool.locations ?? []) mix(pathKey(location));
    for (const diff of tool.diffs ?? []) mix(pathKey(diff));
  }
  return 1 + ((hash >>> 0) % (WORK_SPAN - 1));
}

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
/// below. Subagent starts stay readable; their calls and compactions remain folded work.
/// A subagent's end is not here: it is a harness event the agent did not write, work of the turn it
/// came in like a tool call's end, so a burst of them after a steer folds under that stretch's
/// "Worked for" and groups as "12 subagents stopped" (backgroundRuns.ts; Leo, 2026-11-24: "we can
/// indeed treat them as tool calls, even though they're bursted at the end/start of turns").
/// One that failed stays in sight, as a failed shell does: it waits on a Retry.
const staysOut = (row: AcpmuxRow) =>
  isSubagentGroup(row) ||
  row.kind === SUBAGENT_STARTED ||
  (row.kind === SUBAGENT_DONE && row.subagents?.[0]?.state === "failed") ||
  // A background command that finished or was stopped is the turn's work, and folds with it as its
  // call does (Leo, 2026-11-11: "Background command completed. Do those not count as the f-ing
  // works for?"). One that failed stays in sight, as it does in a run of them (backgroundRuns.ts).
  (row.kind === "backgroundTask" && row.backgroundTask?.state === "failed") ||
  // An error or a refusal the pane noted, and an ask still waiting on the person.
  row.kind === "notice" ||
  row.kind === "permission" ||
  // A move to the fallback harness changes who answers the rest of the turn; folded, nobody would
  // see it happened.
  row.kind === "failover" ||
  // A recap is about the whole chat, not the turn above it.
  row.kind === "recap" ||
  // So is where the person left off (SinceDivider.tsx): folded, nobody would find it.
  row.kind === SINCE_DIVIDER ||
  // A memory offer waits for the person's Accept or Dismiss (MemoryOfferCard.tsx).
  row.kind === MEMORY_OFFER ||
  // A prompt coach card is about the whole chat's first prompt (PromptCoachCard.tsx).
  row.kind === PROMPT_COACH ||
  // A preset approval waits for the person's Approve or Not now (PresetApprovalCard.tsx).
  row.kind === PRESET_APPROVAL ||
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
  // So do the builds a plan approval started (planBuild/PlanBuildCard.tsx).
  row.kind === PLAN_BUILD_KIND ||
  // So does a Claude workflow it started (Labs, summary/WorkflowCard.tsx).
  row.kind === WORKFLOW_CARD ||
  // What the person answered an agent's question, which shaped the rest of the turn.
  row.kind === QUESTION_RECORD;

/// The background turns' lines of a transcript (turnViewFrom's `foldedBackground`).
const backgroundTurnRows = new PrefixFilter<AcpmuxRow>((row) => row.kind === BACKGROUND_TURN);

/// A turn that ended without a summary: a later prompt came before it (another agent's message
/// that arrived while it ran splits it here) or it is history from before acpmux kept summaries.
/// It draws as it came: the agent's messages stay in place, each on its own, and nothing folds
/// that the person did not fold (Leo, 2026-10-20: never auto-collapse messages into "N previous
/// messages").
/// Its edits still close it as one card, which offers Undo.
function settledWithoutSummary(turn: AcpmuxRow[]): AcpmuxRow[] {
  const rows = turn.filter((row) => row.kind !== "typing");
  return [...rows.filter((row) => !isEdit(row)).flatMap(withoutDrafts), ...editsCard(rows.filter(isEdit))];
}

/// The person's own message into a running turn that the agent took (a steer that landed, or one sent
/// now): the stretch before it ends there, on its own footer (``supersededFooters``). Another agent's
/// message, and a steer still waiting to be read, end nothing.
const personCameIn = (row: AcpmuxRow) =>
  row.kind === "user" && !row.incoming && !row.received && continuesTurn(row) && row.steer !== "waiting";

/// `drawn` with an end-of-turn footer (copy, pin, read aloud, its time) under each stretch of the
/// turn the person came in on: the agent's replies and work before a steer that landed (a message sent
/// into the running turn, or one sent now), and the end of a turn with no summary that a new prompt
/// of his opened over (`endedByPerson`). Those stretches count as ended once he comes in, though the
/// turn goes on or never got a clean end, as Claude Code desktop draws them (Leo, 2026-11-03: "i also
/// think a lot of these should've been counted as "ended"-ish turns that allow me to copy/paste your
/// stuff / cuz look claude code lets that happen if the user comes in"). Its Copy copies the stretch
/// (turnCopy.ts). A stretch that said nothing (but the end of a turn with no summary that ran calls
/// alone, G04), or whose reply still streams, gets none; nor does one
/// that already ends on a footer. `turn` is the turn's rows before shaping, in order; `startedAt`, when
/// its prompt was sent. Each footer's time tooltip says how long its stretch worked, from the prompt
/// (or the steer before it) to where he came in, as a turn's own footer does: without it, the time
/// under a stretch had no tooltip at all (Leo, 2026-11-08: "I wasn't able to hover over your timestamp
/// to see, like, this was in and out or whatever. Was it because it's, like, technically inside of a
/// turn and, like, I steered it?").
function supersededFooters(
  drawn: AcpmuxRow[],
  turn: readonly AcpmuxRow[],
  endedByPerson: boolean,
  startedAt: number,
  live = false,
): AcpmuxRow[] {
  let out: AcpmuxRow[] | undefined;
  let from = 0;
  // A running turn's live line drawn below stays its last row: a footer over a waiting steer goes
  // above it, where the steer is drawn.
  const bodyEnd = () => {
    const list = out ?? drawn;
    return list.at(-1)?.below ? list.length - 1 : list.length;
  };
  // Settles whether a footer went in over the stretch that ends at `to`.
  // `ended`: the turn itself ended there (no summary, his next prompt opened over it), so a stretch of
  // calls alone gets its footer too, with their Copy (G04): every finished turn ends on its row.
  const close = (to: number, at: number | undefined, key: string, ended = false): boolean => {
    const stretch = turn.slice(from, to).filter((row) => row.kind !== "turnSummary");
    const began = from > 0 ? turn[from - 1]!.at : startedAt;
    from = to + 1;
    // Its last reply, also one with work after it: the stretch ended where the person came in.
    let answer: AcpmuxRow | undefined;
    for (let back = stretch.length - 1; back >= 0 && !answer; back -= 1)
      if (isReply(stretch[back]!)) answer = stretch[back];
    const list = out ?? drawn;
    const place = at ?? list.length;
    if ((answer ? answer.streaming : !ended) || list[place - 1]?.kind === "turnSummary") return false;
    const parts = turnCopyParts(stretch);
    if (!parts) return false;
    out ??= [...drawn];
    out.splice(place, 0, {
      id: `${SUPERSEDED}-${key}`,
      kind: "turnSummary",
      // The memoized footer redraws when its stretch does.
      version: stretch.reduce((sum, row) => (sum * 31 + row.version) % 2_147_483_647, stretch.length),
      at: stretch.at(-1)!.at,
      status: "completed",
      superseded: true,
      ...workedSpan(began, turn[to]?.at ?? stretch.at(-1)!.at),
      ...(answer && { text: answer.text, answerId: answer.id }),
      turnCopy: parts,
      ...withWork(stretch),
    });
    return true;
  };
  // The person's last message into the turn whose stretch ended on its footer. A message right after
  // it (nothing said between) keeps it: the check below reads everything said since.
  let lastSteer = -1;
  for (let index = 0; index < turn.length; index += 1) {
    const row = turn[index]!;
    // A steer still waiting is the person's too: while the turn runs its footer comes with it (below).
    // A steer the agent has not read yet: acpmux's record of it (`waiting`), or the pane's own row
    // still on its way (`sentSteer`).
    const unread = row.steer === "waiting" ? personCameIn({ ...row, steer: "landed" }) : live && sentSteer(row);
    if (!personCameIn(row) && !unread) continue;
    const at = (out ?? drawn).findIndex((each) => each.id === row.id);
    if (unread) {
      // While the turn runs its footer comes with it, right above where it is drawn (or where the
      // held rows after the body start).
      if (live && sentByPerson(row) && !row.failed) close(index, at < 0 ? bodyEnd() : at, steerKey(row));
      continue;
    }
    if (at < 0) from = index + 1;
    else if (close(index, at, steerKey(row))) lastSteer = index;
  }
  if (endedByPerson && !turn.some((row) => row.kind === "turnSummary"))
    close(turn.length, undefined, turn.at(-1)?.id ?? "end", true);
  // The turn's own footer under that message, when the agent said and ran nothing after it: everything it
  // would copy or read aloud is the footer's over his message, so it draws no row at rest
  // (``isEmptyFooter``). Leo, 2026-11-12: "COPY SHOULDN'T DO ANYTHING IF ALL THAT CHANGED WAS I SENT
  // A MESSAGE THERE'S NO POINT HAVING THE SECOND BUTTON ROW AFTER MY MESSAGE". acpmux ends a Claude
  // turn the person's message came into and carries the message to the next turn, so that footer
  // came right under his bubble. A turn that answered him after it keeps its row, and what it copies.
  if (lastSteer >= 0) {
    const end = turn.findIndex((row, index) => index > lastSteer && row.kind === "turnSummary");
    if (end > lastSteer && !turnCopyParts(turn.slice(lastSteer + 1, end))) {
      const list = out ?? drawn;
      const at = list.findIndex((row) => row.id === turn[end]!.id);
      const footer = list[at];
      if (footer && (footer.text || footer.turnCopy)) {
        out ??= [...drawn];
        const { text: _text, turnCopy: _turnCopy, answerId: _answerId, ...rest } = footer;
        // A new version, so the memoized footer and its measured height draw again.
        out[at] = { ...rest, version: footer.version * 2 + 1 };
      }
    }
  }
  return out ?? drawn;
}

/// A stretch's worked time, from `began` to `ended`; none when either clock is missing or they run
/// backwards (another computer's clock), so its tooltip never says a wrong time.
/// It carries where it ended, so its Timeline's axis starts where the stretch did, not that much
/// before its last reply (waterfallSpans.ts `waterfall`).
function workedSpan(began: number, ended: number): Pick<AcpmuxRow, "durationMs" | "workEndedAt"> {
  if (!hasTimestamp(began) || !hasTimestamp(ended) || ended <= began) return {};
  return { durationMs: ended - began, workEndedAt: ended };
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

/// The live status: the turn's last row from send to end, as Claude desktop draws it, what the agent
/// is doing now ("Thinking" before any output, the call in flight) and the turn's time, which ticks
/// until the turn ends, so the bottom of a running chat always moves. It keeps one id from the
/// Thinking line the prompt opened (LIVE_THINKING), so its row never leaves and comes back. Each
/// finished call stays in sight on its own line until the turn ends (``codexRuns``, live-turn-work `open`).
/// The client's empty "typing" placeholder gives way to it.
function liveTurn(
  user: AcpmuxRow,
  turn: AcpmuxRow[],
  clockOffset: number,
  trayAgents = 0,
  turnStartedAtMs?: number,
  foldsPrompt = false,
  workOpen = false,
): AcpmuxRow[] {
  return withRetry(turn, shapeLiveTurn(user, turn, clockOffset, trayAgents, turnStartedAtMs, foldsPrompt, workOpen));
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

/// The running turn without what of its work the open read (`readAtOpen`, direct.ts `noteReadWork`)
/// that its fold will hold: the calls and thoughts that were there, and the short narration among
/// them, as the turn's end folds them under "Worked for" (`shapeTurn`, the closed fold's `out`). A
/// chat reloaded mid-turn draws that work folded from the first frame, as the row store sends an open
/// turn's (acpmux-book `open_fold`), never drawn and then folded away at the end (Leo: "i see this
/// rush and barrage of tool calls and message on a sort of "renewed-load" of chats. but they get
/// folded/hidden anyways"). What came after the read draws as a watched turn draws it
/// (liveTurnWork). A call still running or waiting for its permission stays, as the fold keeps it.
export function withoutReadWork(rows: AcpmuxRow[]): AcpmuxRow[] {
  if (!rows.some((row) => row.readAtOpen !== undefined)) return rows;
  const replies = repliesIn(rows);
  const out: AcpmuxRow[] = [];
  for (const row of rows) {
    const read = row.readAtOpen;
    if (read === undefined || row.kind === "user" || staysOut(row) || isFinalAnswer(row) || replies.has(row.id)) {
      out.push(row);
    } else if (row.kind === "activity") {
      const items = row.items ?? [];
      const shown = items.filter(
        (item, at) => at >= read || (item.tool !== undefined && (isRunning(item.tool) || awaitsPermission(item.tool))),
      );
      if (shown.length === items.length) out.push(row);
      // Its own version: the memoized row and its measured height follow what it draws.
      else if (shown.length) out.push({ ...row, items: shown, version: row.version * 2 + 1 });
    } else if (!isReply(row)) out.push(row);
  }
  return out;
}

function shapeLiveTurn(
  user: AcpmuxRow,
  turn: AcpmuxRow[],
  clockOffset: number,
  trayAgents = 0,
  turnStartedAtMs?: number,
  foldsPrompt = false,
  workOpen = false,
): AcpmuxRow[] {
  const all = turn.filter((row) => row.kind !== "typing" && !isVisiblyEmptyMessage(row) && !hidesEveryCall(row));
  // Opened mid-turn, the work already there draws as its fold will hold it: folded.
  const kept = withoutReadWork(all);
  // The "Working for" line stands over work the open read folded, as over work it watched.
  const worked = all.some((row) => row.kind === "activity" && row.inBackground === undefined);
  // The agent's wrap-up call draws as its card the moment the call returns, not once the turn ends:
  // the turn ends only after one more model request (6 s and more), and the card waited that long
  // (Leo, 2026-11-19, on the Needs your input cards: "plus it's not instant yet"). Same id as the
  // ended turn's card (`card` in shapedTurn), so the row stays when the turn ends.
  // Find the wrap-up in the complete turn before hiding the work read at open. The completed
  // call still owns the question card even when that call belongs to the hidden prefix.
  const wrapUp = liveWrapUp(all);
  const drawn = wrapUp ? withoutLiveWrapUp(kept, wrapUp) : kept;
  const shaped = shapeLiveRows(user, drawn, clockOffset, trayAgents, turnStartedAtMs, foldsPrompt, worked, workOpen);
  if (!wrapUp) return shaped;
  const card: AcpmuxRow = {
    id: `${NEXT_STEP}-${user.id}`,
    // Another wrap-up, or the same call updated, is another version: the row's memo compares id
    // and version, and would keep the first card's question.
    version: wrapUp.version * SETTLED_STATES,
    at: wrapUp.at,
    kind: NEXT_STEP,
    nextStep: { ask: wrapUp.ask },
  };
  // The person steered in after the turn's last reply: the card goes under that reply, above the steers,
  // where the ended turn draws it (`underAnswer` in shapedTurn), so the turn's end does not carry it up
  // past them (Leo, 2026-11-22: "you need to simulate tons of situations exemplified by various situations
  // and steers coming in at various times").
  // ES2022 has no findLastIndex (tsconfig `lib`).
  let reply = shaped.length - 1;
  while (reply >= 0 && !isReply(shaped[reply]!)) reply -= 1;
  if (reply >= 0 && shaped.slice(reply + 1).some(personCameIn))
    return [...shaped.slice(0, reply + 1), card, ...shaped.slice(reply + 1)];
  // Over the live line, which stays the turn's last row.
  const line = shaped.at(-1);
  return line && line.kind === THINKING ? [...shaped.slice(0, -1), card, line] : [...shaped, card];
}

/// The wrap-up call the turn's newest call is, once it returned, read as its card, with the time it
/// returned. The wrap-up is the turn's last step, so only the newest call is read: a record into a long
/// running turn reads none of its earlier calls again. A call after it takes the card back to the
/// turn's end, where the ended turn reads every call (`lastWrapUp`).
function liveWrapUp(rows: readonly AcpmuxRow[]): LiveWrapUp | undefined {
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind !== "activity") continue;
    // The newest call: a thought after it is no call.
    const items = row.items ?? [];
    let index = items.length - 1;
    while (index >= 0 && !items[index]!.tool) index -= 1;
    if (index < 0) continue;
    const tool = items[index]!.tool;
    if (tool?.status !== "completed") return undefined;
    const exec = isWrapUp(tool) ? undefined : execWrapUp(tool);
    if (!exec && !isWrapUp(tool)) return undefined;
    const ask = wrapUpAsk(tool);
    if (!ask) return undefined;
    // A script that did more than the wrap-up keeps its row, as `withoutWrapUp` keeps it.
    const drop = exec?.only === false ? undefined : { id: tool.id };
    return { ask, at: row.at, version: callVersion(tool.id, row.version), drop };
  }
  return undefined;
}

type LiveWrapUp = { ask: NextStepAsk; at: number; version: number; drop?: { id: string } };

/// The live turn's rows without the one call its card draws: that call's row loses the item, and
/// goes when it held nothing else. No other call is read again, so a record into a long turn parses
/// one call however long the turn; an earlier wrap-up in the same turn keeps its row until the turn
/// ends (`withoutWrapUp`).
function withoutLiveWrapUp(rows: AcpmuxRow[], wrapUp: LiveWrapUp): AcpmuxRow[] {
  if (!wrapUp.drop) return rows;
  const id = wrapUp.drop.id;
  const out: AcpmuxRow[] = [];
  for (const row of rows) {
    if (row.kind !== "activity") {
      out.push(row);
      continue;
    }
    const items = row.items ?? [];
    const kept = items.filter((item) => item.tool?.id !== id);
    if (kept.length === items.length) out.push(row);
    else if (kept.length) out.push({ ...row, items: kept });
  }
  return out;
}

/// A version for the live card of call `id` in a row at `rowVersion`: FNV-1a of the id (32 bits)
/// plus the row's version, so another call or an update to this one changes it.
function callVersion(id: string, rowVersion: number): number {
  let hash = 0x811c9dc5;
  for (let index = 0; index < id.length; index++) hash = Math.imul(hash ^ id.charCodeAt(index), 0x01000193);
  return (hash >>> 0) + rowVersion;
}

function shapeLiveRows(
  user: AcpmuxRow,
  drawn: AcpmuxRow[],
  clockOffset: number,
  trayAgents: number,
  turnStartedAtMs: number | undefined,
  foldsPrompt: boolean,
  worked = drawn.some((row) => row.kind === "activity" && row.inBackground === undefined),
  workOpen = false,
): AcpmuxRow[] {
  // A started chat's card that no row follows yet is not the turn's latest step. The latest step is
  // read before the Codex-style runs fold it: the call it runs is what the live line names.
  let last: AcpmuxRow | undefined;
  for (let index = drawn.length - 1; index >= 0 && !last; index -= 1)
    if (drawn[index]!.kind !== STARTED_SESSIONS) last = drawn[index];
  // The Codex-style live line names the call in flight; a command still running in an earlier run
  // (a parallel `cp` while the agent messages others) leaves its run for the line too.
  const named = last ? lineCall(drawn, last) : undefined;
  // Consecutive calls form a run; every commentary paragraph ends it, regardless of length.
  // The default `folded` draws the work as `line` does, the one live line, under a closed "Working
  // for" that opens it (#50987); `open` keeps each finished call on its own line until the turn ends,
  // `runs` folds each finished run into its closed line, and `line` hides finished runs
  // (liveTurnWork.experiment.ts). The reader who opened the turn's "Working for" (`workOpen`, the
  // fold key its "Worked for" will have) sees every call as it runs.
  // Only `folded` has the toggle; another arm draws as it always has, whatever the key holds.
  const picked = experimentArm(liveTurnWork);
  const folds = picked === "folded";
  const chosen = folds ? (workOpen ? "open" : "line") : picked;
  // The status ticks on this computer's clock, from the live turn's start moved onto it. A resumed
  // turn can still open with an older prompt, so the prompt's time (`user.at`) is only the fallback.
  // A notice that set the agent going again after it had replied (a background task's end, another
  // agent's message) starts a new stretch: the turn's clock counts from it, never from the person's
  // prompt it already answered (Leo, 2026-11-12, on "turn 19m 44s" for a coordinator whose turn
  // stayed open while notices kept arriving: "I feel like this is way too long for a turn").
  // A notice that opens the rows drawn here starts its stretch too, when the harness's turn began
  // before it.
  // One start and one formula with the ended turn's "Worked for" (`turnClock`).
  const clock = turnClock(user, drawn, turnStartedAtMs);
  const start = clock.start;
  const at = start + clockOffset;
  const shapeAs = (arm: string): AcpmuxRow[] => {
    const lineOnly = arm === "line";
    // A call still running before the latest run keeps its own row.
    const carried = lineOnly ? undefined : runningBeforeLastRun(drawn);
    const rows = codexRuns(drawn, named?.tool.id, lineOnly, carried, arm === "open");
    return codexLiveTurn(user, drawn, rows, last, named, at, clockOffset, trayAgents, start);
  };
  let shaped = shapeAs(chosen);
  // `folded` hides the work only under a "Working for" that opens it: a turn drawn with no such line
  // (`livesUnderHeader`) keeps every call in sight, as `open` draws it.
  const headed = livesUnderHeader(drawn, shaped, foldsPrompt, worked);
  if (!headed && folds && chosen === "line") shaped = shapeAs("open");
  // The line is the turn's last row, made fresh here.
  if (named?.earlier) shaped.at(-1)!.linedCall = named.tool.id;
  if (!headed) return shaped;
  // As the Codex app and T3 Code draw a running turn: "Working for 32s" over its work, under the
  // prompt, where "Worked for" lands when the turn ends (liveTurnClock.experiment.ts); the line at
  // the bottom says only what the agent does now, "Thinking", with no clock.
  const line = shaped.at(-1);
  if (line?.kind === THINKING) line.untimed = true;
  // The turn's header, in its running phase: the row its end draws "Worked for" in (one id, kind and
  // element from the turn's start to its end; only its phase and words change). Once the answer
  // came, its clock holds where the ended line reads, so it never runs backwards at the end.
  // Under `folded` it toggles the work under its own id, the key its "Worked for" opens with, so the
  // reader's open or closed state carries through the end and the line only changes its words (#50987).
  const header: AcpmuxRow = {
    id: turnHeaderId(user.id),
    version: 1,
    at,
    kind: WORKED,
    turnPhase: "running",
    ...(clock.durationMs !== undefined && clock.answered && { durationMs: clock.durationMs }),
  };
  if (folds) header.foldOpen = workOpen;
  // A /compact the person steered into: the stretch before the steer is the compaction alone, which
  // the ended turn draws with no fold (`compactOnly`, shapedTurn), so the line stands under the
  // steer, where that turn's one "Worked for" lands, one row from the start: it never stands over
  // the compaction's note and then moves below the steer at the end (Leo, 2026-11-25: "the worked
  // for for collapsing the compaction and then the next worked for + thinking is weird").
  const steer = compactedSteer(drawn);
  if (steer) {
    let below = shaped.findIndex((row) => row.id === steer.id);
    // The note of a compaction that ended under the steer stays over the header, as the ended turn draws it.
    while (below >= 0 && shaped[below + 1]?.kind === "compaction") below += 1;
    if (below >= 0) {
      header.id = `${WORKED}-${steer.id}`;
      header.at = steer.at + clockOffset;
      delete header.durationMs;
      return [...shaped.slice(0, below + 1), header, ...shaped.slice(below + 1)];
    }
  }
  return [header, ...shaped];
}

/// The person's last steer into the running turn when everything before it is a compaction's note
/// and the person's steers: its "Working for" goes under it (``shapeLiveRows``).
function compactedSteer(drawn: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  let steer: AcpmuxRow | undefined;
  let compacted = false;
  for (const row of drawn) {
    if (row.kind === "compaction") compacted = true;
    else if (personCameIn(row)) steer = row;
    else if (row.kind === STARTED_SESSIONS) continue;
    else return compacted ? steer : undefined;
  }
  return compacted ? steer : undefined;
}

/// Whether the running turn draws its "Working for" over its work (`shapeLiveRows`). Only once the
/// person's turn has work, which its end folds under "Worked for" in this place: a turn of only a
/// reply ends with no fold line, and a line drawn over it would leave and move the reply up. Work the
/// agent started on its own after an ended stretch (its summary in the turn) or in the background
/// has no prompt of its own to stand under.
function livesUnderHeader(
  drawn: readonly AcpmuxRow[],
  shaped: readonly AcpmuxRow[],
  foldsPrompt: boolean,
  worked: boolean,
): boolean {
  if (experimentArm(liveTurnClock) !== "top") return false;
  if (drawn.some((row) => row.kind === "turnSummary" || row.kind === BACKGROUND_TURN)) return false;
  // Another agent's message that started the turn folds under its "Worked for" when it ends
  // (`foldsPrompt`, shapedTurn), so its "Working for" stands from the start, in that place: the line
  // never comes in over the message at the first call, and the turn's end only swaps its words (Leo,
  // 2026-11-17: "the jostles and shifts and spacing are still bad here").
  // Work the open read folded counts too (`worked`, shapeLiveTurn): the line stands over it as over work it watched.
  return foldsPrompt || worked;
}

/// A turn's header (`shapeLiveTurn`, `shapeTurn`), keyed by the turn's prompt: its "Working for"
/// while it runs and its "Worked for" once it ended, one row.
export const turnHeaderId = (promptId: string) => `${WORKED}-${promptId}`;
const isRunningHeader = (user: AcpmuxRow) => (row: AcpmuxRow) =>
  row.id === turnHeaderId(user.id) && row.turnPhase === "running";

/// A turn's clock, one start and one formula for its running "Working for" and its ended "Worked
/// for": from the turn's start (the harness's record of it: the ended turn's `summary`, the running
/// turn's `liveStart`, else the turn's latest row that carries it; else its end less its duration,
/// else the prompt; another agent's message that
/// came after it, or the latest notice that set the agent going again, `continuationStart`) to its
/// first final answer from then on, else to its end (`summary`). Running, `durationMs` is set once
/// the answer came (`answered`); the clock ticks until then.
export function turnClock(
  user: AcpmuxRow,
  rows: readonly AcpmuxRow[],
  liveStart?: number,
  summary?: AcpmuxRow,
): { start: number; durationMs?: number; answered: boolean } {
  let recorded = summary?.turnStartedAtMs ?? liveStart;
  for (let index = rows.length - 1; recorded === undefined && index >= 0; index -= 1)
    recorded = rows[index]!.turnStartedAtMs;
  const opened = recorded ?? (summary?.durationMs !== undefined ? summary.at - summary.durationMs : user.at);
  const start = continuationStart(
    rows,
    !sentByPerson(user) && hasTimestamp(user.at) && user.at > opened ? user.at : opened,
  );
  const answer = rows.find((row) => isFinalAnswer(row) && row.at >= start);
  if (answer) return { start, durationMs: Math.max(0, answer.at - start), answered: true };
  if (!summary) return { start, answered: false };
  // The harness's own measure of the turn, when nothing moved its start.
  if (start === opened && summary.durationMs !== undefined)
    return { start, durationMs: summary.durationMs, answered: false };
  if (user.kind !== "user" && recorded === undefined) return { start, answered: false };
  return { start, durationMs: Math.max(0, summary.at - start), answered: false };
}

/// When the live turn's current stretch began: `start`, or the latest notice (a prompt the person did
/// not send) that came after the agent had replied since then, which set it going again.
export function continuationStart(rows: readonly AcpmuxRow[], start: number): number {
  let from = start;
  let replied = false;
  for (const row of rows) {
    if (row.kind === "assistant" && !isVisiblyEmptyMessage(row)) replied = true;
    else if (row.kind === "user" && !sentByPerson(row) && replied && hasTimestamp(row.at) && row.at > from) {
      from = row.at;
      replied = false;
    }
  }
  return from;
}

/// A turn's footer that holds only its buttons (copy, fork, pin, read aloud, its time): no failure,
/// no stop, nothing to resume or continue.
const isButtonFooter = (row: AcpmuxRow | undefined): row is AcpmuxRow =>
  row?.kind === "turnSummary" && !isFailed(row) && !isStopped(row) && !row.resumable && !row.continuable;

/// A running turn as the Codex app draws it: each finished run folded into its summary line between the paragraphs
/// (codexRuns), and at the bottom the turn's one live block, a line that each step replaces in place
/// (Leo 2026-10-20: "Thinking (shimmer) -> Running <short label> -> Thinking"): "Thinking 18s"
/// (the turn's time) while the agent thinks, "Running <what the call does> 13s" while a call runs.
/// Nothing draws over the turn's work (Leo 2026-10-21: a "Working for" there sat far above the
/// line, past his steers). The line keeps the Thinking line's id from send to the turn's end, so it never leaves and
/// comes back. While text streams it stays and reads "Writing" (`quietKey`, Thinking.tsx).
function codexLiveTurn(
  user: AcpmuxRow,
  drawn: AcpmuxRow[],
  runs: AcpmuxRow[],
  last: AcpmuxRow | undefined,
  named: LineCall | undefined,
  at: number,
  clockOffset: number,
  trayAgents = 0,
  start = user.at,
): AcpmuxRow[] {
  // A stretch that already ended with its footer (a turn the agent ran on its own, its reply's
  // buttons drawn) while the chat still works: the line takes that footer's slot, and the footer
  // comes back in it when the work ends, so neither stacks under the other and nothing moves (Leo,
  // 2026-11-08: "the bottom buttons appear and then there's thinking then thinking disappears then
  // there's a jolt. but the thinking should essentially take the same spot as the bottom buttons").
  // Only a footer of buttons: a failed or stopped stretch's summary carries its error, its recovery
  // or its Continue, which stay in sight under the line.
  let rows = isButtonFooter(runs.at(-1)) ? runs.slice(0, -1) : runs;
  // The one live block sits at the turn's bottom, as the ChatGPT and Codex apps draw it: no
  // "Working for" over the turn (with steers it stood above all of them, far from the line; Leo,
  // 2026-10-21). Between steps it reads "Thinking 18s", timed from the prompt.
  const line: AcpmuxRow = {
    id: LIVE_THINKING,
    frame: liveLineFrame(user),
    version: 1,
    at,
    kind: THINKING,
    below: true,
    verbKey: user.id,
  };
  // A /compact (typed, a Compact button's, the cache timer's) compacts from its send: the line reads
  // "Compacting conversation" from the first frame, never "Thinking" until the harness's own
  // compaction row comes (Leo, 2026-11-25: "the compaction starting from idle should not go from
  // thinking to idle potentially. just the compacting conversation to start with so it skips the
  // unnecesssary animation").
  if (!last) {
    if (compactPrompt(user)) {
      line.liveState = "compacting";
      line.doingAt = sentTime(user, clockOffset) + clockOffset;
    }
    return [...rows, line];
  }
  const compactingRow = named ? undefined : liveCompaction(drawn);
  if (named) {
    const call = named.tool;
    // A command reads its working step, whole: the line's CSS ellipsis cuts it at its edge, not a fixed
    // count (Leo, 2026-11-07: "stretch across the line"). One with no line yet reads its title ("Run make"). While
    // Claude still writes its input (a pending "Bash" with no command, often 20s for a long
    // script) it reads "Writing a command", never "Running" a command that has not started.
    const summary = liveShellLabel(call);
    const shell = call.kind === "execute" && !summary && (Boolean(call.command) || isBareShellName(call, call.title));
    line.doing = summary ?? (shell ? (call.command ? liveCommand(call.command) : "") : runningLabel(call, ""));
    line.doingShell = shell;
    if (call.kind) line.doingKind = call.kind;
    if (shell && !call.command && call.status === "pending") line.doingDraft = true;
    // A started command shows "⌃B to run in background" on the line, never on a transcript row
    // (Thinking.tsx; Leo, 2026-10-22: "this cmd b to run in background ... it should prob go down").
    if (call.kind === "execute" && !line.doingDraft && call.background === undefined) line.doingCommand = true;
    Object.assign(line, sendingTo(call));
    line.doingAt = (call.startedAt ?? named.at) + clockOffset;
    // The call the line names: its own words change in place from pending to done (Thinking.tsx).
    line.doingCall = call.id;
  } else if (compactingRow) {
    // A compaction running is the line's state, timed from its own start: no model thinks or
    // writes then, so the line never reads "Thinking" or counts tokens, and the compaction's own
    // row folds into it, one status line (Leo, 2026-11-07: "when you're compacting the
    // conversation, just show it as you're compacting ... You're not thinking during this time ...
    // That should replace the thinking area"). Once it ends its note lands in the transcript and
    // the line reads "Thinking" again.
    rows = rows.filter((row) => row.id !== compactingRow.id);
    line.liveState = "compacting";
    line.liveCompaction = compactingRow.compaction;
    line.doingAt = compactingRow.at + clockOffset;
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
  // No call in flight and no answer streaming, while foreground subagents still run: the agent
  // waits on them ("Waiting on 2 subagents"), whatever its last row was.
  const compacting = line.liveState === "compacting";
  const agents = named || answering || compacting ? 0 : foregroundAgents(drawn) + trayAgents;
  // The wait began when the turn's own rows last did anything (a call, a thought, the subagent's
  // start): the time beside "Waiting on 1 subagent" is that wait's, never the turn's whole time
  // (Leo, 2026-11-20: "why are you also, like, waiting on, allegedly waiting on one sub-agent for
  // seven minutes and 39 seconds?").
  if (agents > 0)
    Object.assign(line, {
      liveState: "subagents",
      liveAgents: agents,
      liveAgentNames: foregroundAgentNames(drawn),
      waitAt: liveClock(drawn, start, clockOffset).heardAt,
    });
  // Between calls the line reads "Thinking" the moment a call completes, in one in-place roll: it
  // never holds the finished step with its frozen time (Leo, 2026-11-07: "if we can genuinely
  // determine that there's no more seconds ticking, then why are we still showing it? Why don't
  // we just immediately switch to the thinking? I feel like this hangs on for a bit too much").
  // Takes back the held step of 2026-11-01 ("this should be replacing the thinking area and its
  // shimmer across things"); the finished call stays in its run.
  // Still "Thinking" after the first step: the time beside it is this stretch of thinking, ticking
  // from when it began (`phaseAt`), never a frozen sum of the thoughts' spans (Leo, 2026-11-12, on
  // "Thinking 683ms · turn 15m 15s": "the whatever ms gets stuck and becomes false really
  // quickly"). When the turn last heard anything (`heardAt`, `heardKey`) lets the line say
  // "Waiting" once SILENT_MS pass with nothing, never a stale "Thinking" (Thinking.tsx). The calls,
  // waits and queue time before it are not thinking (Leo's "Thinking 7m 34s · ↓ 4.5K out",
  // 2026-11-03); the turn's whole time is the total after it.
  // A reply that paused ("writing") gets the silence clock too: past WRITING_MS it reads "Thinking",
  // and past SILENT_MS with nothing more it reads "Waiting", never a "Thinking" that stays forever.
  if (line.doing === undefined && (line.liveState === undefined || line.liveState === "writing"))
    Object.assign(line, liveClock(drawn, start, clockOffset), {
      heardKey: `${drawn.length}:${last.id}:${last.version}`,
      // Past SILENT_MS of nothing the line names what it waits on, never a bare "Waiting".
      liveWait: liveWait(drawn, last),
    });
  return [...rows, line];
}

/// The turn's compaction still running, with nothing from the agent since: no reply or call after
/// it. A note after it (a failover, a background task's end) leaves it running, and so does a prompt
/// the person sent while it runs: the compaction stays the live line, under that prompt, never a
/// row above it (Leo, 2026-11-09: "im still seeing compacting not be at the bottom"). Once it ends,
/// its note is a row and the line reads "Thinking" at once, as after any finished step.
function liveCompaction(drawn: readonly AcpmuxRow[]): AcpmuxRow | undefined {
  for (let index = drawn.length - 1; index >= 0; index -= 1) {
    const row = drawn[index]!;
    if (row.kind === "compaction") return row.compaction?.state === "running" ? row : undefined;
    if (row.kind === "assistant" || row.kind === "activity" || (row.kind === "user" && !sentByPerson(row)))
      return undefined;
  }
  return undefined;
}

/// A prompt that is the harness's /compact, with or without its instructions ("/compact keep the
/// plan"): its turn compacts first. ``isCacheCompaction``'s timer sends the same text.
export const compactPrompt = (row: AcpmuxRow) =>
  row.kind === "user" && !row.incoming && !row.received && /^\/compact(?:\s|$)/.test((row.text ?? "").trimStart());

/// The person's own prompt (typed here or on another of their devices), not another agent's
/// message, a task's result or harness bookkeeping.
const sentByPerson = (row: AcpmuxRow) =>
  row.kind === "user" && !row.incoming && !row.received && !row.untyped && row.from === undefined;

/// The pane's own row for a steer the person sent into the running turn, before acpmux's record of it.
const sentSteer = (row: AcpmuxRow) =>
  row.kind === "user" && row.pending === true && row.delivery?.queued === true && sentByPerson(row) && !row.failed;

/// What a steer's stretch footer is keyed by: its prompt, which the pane's row and acpmux's record of
/// it share, so the footer stays the same row from the send on (`superseded-<key>`).
const steerKey = (row: AcpmuxRow) => row.promptId ?? row.delivery?.promptId ?? row.id;

/// When the person sent `row`, on the events' clock (a call's `endedAt`): the pane's send time while
/// it has one, moved off this computer's clock by `clockOffset` (the snapshot's `clockOffsetMs`,
/// events' time + offset = this computer's), else its record's.
const sentTime = (row: AcpmuxRow, clockOffset: number) =>
  row.delivery?.sentAt !== undefined ? row.delivery.sentAt - clockOffset : row.at;

/// Whether `item` was still going at `sentAt`: a call running now or one that ended after it, a
/// thought that streamed on past it.
function goingAt(item: NonNullable<AcpmuxRow["items"]>[number], sentAt: number): boolean {
  if (item.tool) return isRunning(item.tool) || (item.tool.endedAt !== undefined && item.tool.endedAt > sentAt);
  return item.kind === "thought" && item.endedAt !== undefined && item.endedAt > sentAt;
}

/// The id suffix of the part of a run that ended after a prompt the person sent (`afterSends`;
/// chatFind.ts holds it, as Find reads the split).
export { AFTER_SEND };

/// A running turn's drawn rows with what was still going when the person sent a prompt drawn after
/// that prompt: the transcript only appends, and nothing above the prompt moves once it is drawn
/// (Leo, 2026-11-09: "i hate the way when i send off a message it seems to move up and under your
/// current running tool call or whatever"; "these animations all slosh around ... i previously sent
/// the claude code one, just look at how they do it"). A call that ran at the send leaves its run
/// for a run of its own right under the prompt (`AFTER_SEND`), so it lands below the prompt when it
/// ends instead of in its run above it. One pass over the turn's rows per prompt the person sent
/// into it (a few); a turn with none is returned as it is.
export function afterSends(rows: AcpmuxRow[], clockOffset = 0): AcpmuxRow[] {
  let out: AcpmuxRow[] | undefined;
  const emptied = new Set<AcpmuxRow>();
  for (let at = 1; at < (out ?? rows).length; at += 1) {
    const list = out ?? rows;
    const sent = list[at]!;
    if (!sentByPerson(sent) || sent.failed) continue;
    const sentAt = sentTime(sent, clockOffset);
    const moved: NonNullable<AcpmuxRow["items"]> = [];
    let source: AcpmuxRow | undefined;
    // Every row an item came from: Find and a count's reveal still name them (`joined`, chatFind.ts
    // findRowIndex), and a change in any one of them (a background call ending) changes the run.
    const members: string[] = [];
    let version = 0;
    for (let before = 0; before < at; before += 1) {
      const row = list[before]!;
      if (row.kind !== "activity" || !row.items?.some((item) => goingAt(item, sentAt))) continue;
      out ??= [...rows];
      const stays = row.items.filter((item) => !goingAt(item, sentAt));
      moved.push(...row.items.filter((item) => goingAt(item, sentAt)));
      source ??= row;
      for (const id of row.joined ?? [row.id]) if (!members.includes(id)) members.push(id);
      version = mixVersion(version, row.version);
      const kept = { ...row, items: stays, version: mixVersion(row.version, stays.length) };
      if (!stays.some((item) => item.tool || item.kind === "thought")) emptied.add(kept);
      out[before] = kept;
    }
    if (!source) continue;
    out!.splice(at + 1, 0, {
      ...source,
      id: `${source.id.split(AFTER_SEND)[0]}${AFTER_SEND}${sent.id}`,
      joined: members,
      items: moved,
      version: mixVersion(version, moved.length),
      ...(source.toolCount !== undefined && { toolCount: moved.filter((item) => item.tool).length }),
    });
  }
  return out ? (emptied.size ? out.filter((row) => !emptied.has(row)) : out) : rows;
}

/// When a live turn's current stretch of thinking began and when the turn last heard anything, on
/// this computer's clock. Every dated moment of the turn's rows is a sign of life: a row's start, a
/// thought's first and latest chunk, a call's start and end. The stretch begins at the latest sign
/// that is no thought (a call that ended, a reply, the prompt), or later at the first thought after
/// a silence of SILENT_MS, which the line drew as "Waiting" (Thinking.tsx), so the time beside
/// "Thinking" never counts a wait as thought.
export function liveClock(
  rows: readonly AcpmuxRow[],
  start: number,
  clockOffset = 0,
): { phaseAt: number; heardAt: number } {
  let step = start;
  let heard = start;
  // Each thought is one span, its first chunk to its latest: a thought that streams on is never
  // silent inside, however long it runs, so only a gap between spans can start a new stretch.
  const thoughts: { from: number; to: number }[] = [];
  const dated = (at: number | undefined): at is number => at !== undefined && hasTimestamp(at);
  const note = (at: number | undefined) => {
    if (!dated(at)) return;
    if (at > heard) heard = at;
    if (at > step) step = at;
  };
  const think = (from: number | undefined, to: number | undefined) => {
    const first = dated(from) ? from : dated(to) ? to : undefined;
    if (first === undefined) return;
    const last = dated(to) && to > first ? to : first;
    if (last > heard) heard = last;
    thoughts.push({ from: first, to: last });
  };
  for (const row of rows) {
    const items = row.kind === "activity" ? (row.items ?? []) : [];
    // An activity row's start is its first item's; one of only thoughts is no step.
    if (items.length > 0 && items.every(isThought)) think(row.at, row.at);
    else note(row.at);
    for (const item of items) {
      if (isThought(item)) think(item.startedAt, item.endedAt);
      else {
        note(item.startedAt);
        note(item.endedAt);
      }
      note(item.tool?.startedAt);
      note(item.tool?.endedAt);
    }
  }
  let phase = step;
  let last = step;
  for (const span of thoughts.filter((span) => span.to > step).sort((a, b) => a.from - b.from)) {
    const from = Math.max(span.from, step);
    if (from - last >= SILENT_MS) phase = from;
    if (span.to > last) last = span.to;
  }
  return { phaseAt: phase + clockOffset, heardAt: heard + clockOffset };
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
/// The running foreground subagents' names, in the order they started: the subagent wait's words.
function foregroundAgentNames(rows: readonly AcpmuxRow[]): string[] {
  const names: string[] = [];
  for (const row of rows)
    if (isSubagentGroup(row))
      for (const agent of row.subagents ?? [])
        if (agent.state === "running" && !agent.background && agent.name.trim()) names.push(agent.name.trim());
  return names;
}

/// What a silent live line waits on (liveWait.ts), from the turn's latest row: the model reading
/// the call that just returned, its first reply to the prompt or another agent's message, the
/// person's message still queued in the turn, or the model's next step after a thought or reply.
export function liveWait(drawn: readonly AcpmuxRow[], last: AcpmuxRow): LiveWait {
  if (drawn.some((row) => row.kind === "user" && row.steer === "waiting")) return { kind: "queued" };
  if (last.kind === "user") {
    const from = last.incoming?.kind === "message" ? last.incoming.message.name.trim() : "";
    return from ? { kind: "message", from } : { kind: "prompt" };
  }
  if (last.kind !== "activity") return { kind: "next" };
  const item = last.items?.at(-1);
  const tool = item?.tool;
  if (!item || !tool || isThought(item)) return { kind: "next" };
  const summary = liveShellLabel(tool);
  const shell = tool.kind === "execute" && !summary && (Boolean(tool.command) || isBareShellName(tool, tool.title));
  const t = translatorFor(currentLanguage());
  const step = shell
    ? tool.command
      ? t("tools.ranCommand", { command: liveCommand(tool.command) })
      : t("tools.ranUnnamed")
    : (summary ?? runningLabel(tool, item.text ?? ""));
  const words = step.trim();
  // The step as the step row says it ("Ran bun test", "Read App.tsx"); the label sets it after a
  // colon in every language, so its verb keeps the row's own capital.
  return words ? { kind: "step", step: words } : { kind: "next" };
}

/// The `row` arm of `oneRowPerCall`: a file change keeps its own row in its run from pending to done.
const keepsOwnRow = (call: AcpmuxActivity["tool"]) => isEditTool(call) && experimentArm(oneRowPerCall) === "row";

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
  // A call whose own row stays in its run (one waiting on its permission, or the `row` arm's file
  // changes) is drawn there, never on the line as well.
  const lineable = (call: NonNullable<AcpmuxActivity["tool"]>) => !awaitsPermission(call) && !keepsOwnRow(call);
  const latest = runningCall(last, lineable);
  if (latest) return { tool: latest, at: last.at };
  // The person sent into the turn while a call ran: the call stays on the line under the prompt,
  // never jumping into its run's row above it (Leo, 2026-11-09: "i hate the way when i send off a
  // message it seems to move up and under your current running tool call"). Its row comes after
  // the prompt once it ends (`afterSends`).
  if (sentByPerson(last))
    for (let index = drawn.length - 1; index >= 0; index -= 1) {
      const row = drawn[index]!;
      if (row.kind === "user") continue;
      const tool = runningCall(row, lineable);
      if (tool) return { tool, at: row.at, earlier: true };
      break;
    }
  for (let index = drawn.length - 1; index >= 0; index -= 1) {
    const row = drawn[index]!;
    const tool = runningCall(row, (call) => call.kind === "execute" && !call.background && !isDraftCall(call));
    if (tool) return { tool, at: row.at, earlier: true };
  }
  return undefined;
}

/// The message a call in flight sends, for the live line: "Sending message to tests", never the
/// raw `acpmux send …` line (Leo 2026-10-24: "sending message or sent message to X or Y").
function sendingTo(tool: NonNullable<AcpmuxActivity["tool"]>): Pick<AcpmuxRow, "doingSendTo" | "doingSendSession"> {
  if (tool.description?.trim()) return {};
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
  // A harness's own message tool (Claude's SendMessage) leaves its run while it runs, so the line
  // names it.
  const to = !call && isRunning(tool) ? agentMessage(tool)?.to : undefined;
  return to ? { doingSendTo: short(to) } : {};
}

function liveShellLabel(tool: NonNullable<AcpmuxActivity["tool"]>): string | undefined {
  return tool.kind === "execute" ? commandSaid(translatorFor(currentLanguage()), tool) : undefined;
}

/// A command on the live line: its working step whole (the line's CSS ellipsis cuts it), or a
/// script its interpreter reads from a heredoc as "a Python script on als.json", never its
/// `<<'EOF'` marker (Leo, 2026-11-07: "it's just weird, um, that it just says EOF").
function liveCommand(command: string): string {
  return scriptNoun(translatorFor(currentLanguage()), command) ?? commandLine(command, "command", false);
}

/// A running call in one short line: a command as itself ("Ran …" would say it has finished), a
/// file call by the file's name ("Edit ProductGrid.module.css").
function runningLabel(tool: Parameters<typeof toolLabel>[0], text: string): string {
  const description = tool.description?.trim();
  if (description) return description;
  // A file write reads as its row does (WriteLabel.tsx): "Writing a file" before its input,
  // "Writing gen.py", then "Wrote gen.py", never the bare tool name "Write".
  const write = writeCall(tool);
  if (write) {
    const t = translatorFor(currentLanguage());
    const done = tool.status === "completed";
    const file = write.path && (write.path.split("/").pop() || write.path);
    if (!file) return t(done ? "tools.wrote.unnamed" : "tools.writing.unnamed");
    return t(done ? "tools.wrote.file" : "tools.writing.file", { file });
  }
  const label = toolLabel(tool, text, (command) => command);
  const path = editedPaths(tool)[0];
  if (!path || tool.kind === "execute") return label;
  if (isEditTool(tool) && tool.status === "completed" && editedPaths(tool).length === 1)
    return translatorFor(currentLanguage())("tools.edited.file", { file: path.split("/").pop() || path });
  // A search names its pattern, not the folder it searches in (toolNames.ts).
  const canonical = canonicalCall(tool)?.tool;
  if (canonical === "search" || canonical === "glob" || canonical === "fetch" || canonical === "websearch")
    return label;
  return `${label.split(/\s+/, 1)[0]} ${path.split("/").pop() || path}`;
}

/// The drawn states of one Codex-style run, each its own version offset so a memoized row redraws
/// on every change between them (App.tsx compares versions): 0 a run kept on its own row, 1 the live
/// latest run, 2 an earlier run, 3 an ended turn's open fold, 4 an earlier run whose running command
/// the live line holds. Under live-turn-work `open` states 1, 2 and 4 draw unfolded (`foldRun`
/// false): the arm is read once per page (experiments/experiment.ts), so a row never moves between
/// the folded and the unfolded copy of one state.
const RUN_STATES = 5;
/// How long a running turn's thought that opens its run streams before it draws (`codexRuns`): a
/// few chunks, so its row never lands in the frame its run and the turn's Working line do.
const FIRST_THOUGHT_MS = 100;
/// A steered turn's open fold, whose run lines start open (`runOpen`), differs from the same fold
/// closed. (Not a sixth `RUN_STATES`: the minimap's edit-card versions are pinned to five.)
const OPEN_RUN_STATES = 2;

/// A running turn's runs as the Codex desktop app draws them (cx-ncc.108; Lucas, 2026-11-11): each
/// run folds into its summary line between the paragraphs ("Read 6 files, ran 4 commands", or one
/// group's "Ran 3 commands"), the latest one too as its calls finish, and opens on a click. The call in flight is
/// not in the run: the turn's live line names it (WorkingFor.tsx `doing`) and each step replaces it
/// in place. A thought still coming is, once it is not quiet (below). A call still running in an earlier run
/// (a background shell) stays in its run, except the command the live line names (`named`,
/// `lineCall`), which reads once, on the line. Each derived row's version moves with its drawn state.
/// With `lineOnly` a finished run of the stretch still running draws no row: the live line is its
/// work (liveTurnWork). A stretch that already ended with its summary keeps its runs, as it draws
/// once the chat stops working, so that end moves nothing (liveLineTakesFooterSlot.test.ts).
/// With `open` (liveTurnWork `open`) no run of the stretch still running folds: each keeps its calls
/// on their own lines (`foldRun` false), so a steer or a reply that ends a run changes nothing drawn
/// above it, and the work folds once, when the turn ends (`shapeTurn`). An ended stretch folds as above.
/// The calls still running in every run but the last one (`shapeLiveTurn`): a merge that joins such
/// a run to the latest must not hand them to the live line, which names only one call.
function runningBeforeLastRun(rows: readonly AcpmuxRow[]): Set<string> | undefined {
  let last = -1;
  for (let at = rows.length - 1; at >= 0 && last < 0; at -= 1) if (rows[at]!.kind === "activity") last = at;
  let running: Set<string> | undefined;
  for (let at = 0; at < last; at += 1)
    for (const item of rows[at]!.items ?? [])
      if (item.tool && isRunning(item.tool)) (running ??= new Set()).add(item.tool.id);
  return running;
}

/// What `codexRuns` made of an activity row that is not the latest run, by that row: the running turn
/// is shaped again on every record, and each earlier run came back as a new object, so everything
/// after it that reads a run by its object (messageRuns.ts `member`, which groups the run's calls and
/// parses each command line again; the layout; the row memos) did its work again for every run of
/// the turn on every record (bench/live-turn-rows.bench.ts: 28 ms a record at 10,000 records). An
/// earlier run is a function of its row and of whether the live line names one of its calls, so the
/// rows made for it are kept while both hold. `named`: the named call, when it is one of the row's.
/// `fold`: whether its rows fold (`foldRun`), false for a run of the stretch still running under
/// live-turn-work `open`.
type EarlierRun = { named: string | undefined; fold: boolean; out: AcpmuxRow[] };
const earlierRuns = new WeakMap<AcpmuxRow, EarlierRun>();
/// The rows `codexRuns` makes of a run that keeps its own row (a change waiting for its permission,
/// a call that keeps its row while it runs), by that row.
const keptRuns = new WeakMap<AcpmuxRow, AcpmuxRow>();

/// `named` when the live line names one of `row`'s calls, else undefined: all an earlier run's rows
/// read of the line.
function namedIn(row: AcpmuxRow, named: string | undefined): string | undefined {
  if (named === undefined) return undefined;
  for (const item of row.items ?? []) if (item.tool?.id === named) return named;
  return undefined;
}

/// An earlier run's rows (`codexRuns`): what it draws of `row`'s calls, without the ones that have
/// nothing to show yet and the one the live line names.
function earlierRun(row: AcpmuxRow, named: string | undefined, fold = true): AcpmuxRow[] {
  const own = namedIn(row, named);
  const kept = earlierRuns.get(row);
  if (kept && kept.named === own && kept.fold === fold) return kept.out;
  const out = withoutDrafts(row).flatMap((drawn) => {
    const items = drawn.items ?? [];
    const shown = own === undefined ? items : items.filter((item) => item.tool?.id !== own);
    if (!shown.length) return [];
    // Its version says whether the line holds its command, which moves without the row's, and
    // differs from every other state of the run (`RUN_STATES`).
    const lined = shown.length !== items.length;
    return [
      { ...drawn, items: shown, settled: true, foldRun: fold, version: row.version * RUN_STATES + (lined ? 4 : 2) },
    ];
  });
  earlierRuns.set(row, { named: own, fold, out });
  return out;
}

function codexRuns(
  rows: AcpmuxRow[],
  named?: string,
  lineOnly = false,
  carried?: ReadonlySet<string>,
  open = false,
): AcpmuxRow[] {
  // A started chats' card after the run is not a step: the run before it is still in flight.
  let latest = rows.length - 1;
  while (latest > 0 && rows[latest]!.kind === STARTED_SESSIONS) latest -= 1;
  let ended = -1;
  if (lineOnly || open)
    for (let at = rows.length - 1; at >= 0 && ended < 0; at -= 1) if (rows[at]!.kind === "turnSummary") ended = at;
  // One pass that pushes, not a `flatMap`: a running turn of thousands of rows is shaped on every
  // record, and a one-row array for each of them was most of what the pass made.
  const shape = (row: AcpmuxRow, index: number): AcpmuxRow[] => {
    if (row.kind !== "activity") return [row];
    // A run that edited is shaped as the others; the turn's edited-files card lists its edits when
    // it ends. One with a file change still waiting for its permission stays as it is, so the change
    // it asks about stays in sight (an ended turn's folded run keeps it in sight too: TurnRows.tsx
    // `staysInSight`).
    if (
      (row.items ?? []).some((item) => awaitsPermission(item.tool) || (keepsOwnRow(item.tool) && isRunning(item.tool!)))
    ) {
      let own = keptRuns.get(row);
      if (!own) keptRuns.set(row, (own = { ...row, foldRun: false, version: row.version * RUN_STATES }));
      return [own];
    }
    if (lineOnly && index > ended) return [];
    // Under `open` a run of the stretch still running keeps every call on its own line.
    const fold = !open || index <= ended;
    // An earlier run draws no call that has nothing to show yet; its row comes with its input.
    if (index !== latest) return earlierRun(row, named, fold);
    // The latest run: what is happening now leaves it for the live line, so the run holds only
    // finished steps and never grows a stack of live rows (Leo 2026-10-20: "rows pile up instead
    // of replacing each other").
    const all = row.items ?? [];
    // A thought still coming stays in the run from its first words, not only once the next step
    // ends it (Leo, 2026-11-09: "we can be a bit more optimistic with, like, the displaying of the
    // thinking ... I only started seeing your thinking bit, like, seven seconds in"). It draws as it
    // will once done, its folded line (ThoughtRow, not `streaming`: the row is not `live`), so the
    // row neither grows under the reader as it streams nor shrinks when it ends (Leo, 2026-11-07:
    // "the jumps are jarring. We want to minimize the jumps"); the live line under it says
    // Thinking. Not while it is still quiet by
    // the rule a finished thought draws by (thoughts.ts `isQuietThought`): its text and its time only
    // grow, so one shown here never leaves when it ends, and a short thought that has run a second
    // shows now, as it does once the turn ends or the chat reloads (Leo, 2026-11-09: "oh i guess the
    // service or something must have crashed in between cuz now i see it").
    const tail = all.at(-1);
    const steps = (shows: boolean) =>
      all.filter((item, at) =>
        item.tool
          ? !isRunning(item.tool) || (carried?.has(item.tool.id) === true && item.tool.id !== named)
          : !(at === all.length - 1 && item.kind !== "tool" && !shows),
      );
    const thinking =
      tail !== undefined &&
      isThought(tail) &&
      !isQuietThought(tail) &&
      // A thought that is the run's first step waits out its first chunks (FIRST_THOUGHT_MS of them,
      // by their own times): its run arrives with the turn's Working line (`shapeLiveTurn`) and the
      // reply's last text, and the two rows landing in one frame moved the rows above by 29 px
      // (test/turn-transition-jumps.test.ts burst-thought). One later step in, it arrives alone.
      (steps(false).length > 0 || (thoughtDuration(tail) ?? FIRST_THOUGHT_MS) >= FIRST_THOUGHT_MS);
    const items = steps(thinking);
    if (!items.length) return [];
    // Whether it shows its thought is the row's own (its text and its chunks' times, not the
    // clock), so the version it has says it: state 1 either way, never an ended fold's 3.
    return [{ ...row, items, settled: true, foldRun: fold, version: row.version * RUN_STATES + 1 }];
  };
  const out: AcpmuxRow[] = [];
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    if (row.kind !== "activity") out.push(row);
    else for (const shaped of shape(row, index)) out.push(shaped);
  }
  return out;
}

/// Narration short enough to fold into the work around it: a short paragraph, under about three
/// lines at the pane's width.
export const SHORT_NOTE_CHARS = 160;
const TAKEAWAY_LINES = 3;
/// A reply that reads as a takeaway, not narration of the work: over about three lines, more than
/// about two sentences, or with a question, a list, a link, a code block or a second paragraph (Leo,
/// 2026-10-21). Inline code alone
/// does not make one: narration names files and calls ("Reading `client.ts` next."), and that is
/// the work Lawrence asked to collapse; a short note keeps the fold it had before. Another agent's words
/// always are. Shared by the finished turn's final answer and the running turn's runs
/// (``mergeShortNotes``).
export function isTakeaway(row: AcpmuxRow): boolean {
  if (row.kind !== "assistant") return false;
  const text = (row.text ?? "").trim();
  if (!text) return false;
  return (
    isFinalAnswer(row) ||
    Boolean(row.incoming) ||
    text.length > SHORT_NOTE_CHARS ||
    text.split("\n").length > TAKEAWAY_LINES ||
    /\?|```|~~~|\n\s*\n|^\s*(?:[-*+]|\d+[.)])\s|\]\(|https?:\/\//m.test(text) ||
    !isWorkNarration(text)
  );
}

/// Only recognizable short progress narration belongs to the work. Unknown prose can be a brief
/// answer: a later tool and "I sent it" do not replace it (Leo, 2026-11-13). Check every sentence
/// so "Let me check. The cache is stale." keeps its finding; structural takeaways win above.
function isWorkNarration(text: string): boolean {
  const sentences = text
    .replace(/\.{3,}|…/g, ".")
    .split(/[.!?](?:\s+|$)/)
    .filter((part) => part.trim());
  return (
    sentences.length > 0 &&
    sentences.length <= 2 &&
    sentences.every((part) => {
      const note = part.trim();
      if (/^(?:both|the|all) [^,;:|]+\b(?:still running|still pending|are running|are pending)$/i.test(note))
        return true;
      const action =
        /^(?:(?:let me|i['’]ll|i will) (?:check|read|look|inspect|search|run|test|review|verify|wait)|(?:i['’]m |i am )?(?:checking|reading|looking|inspecting|searching|running|testing|reviewing|verifying|waiting))\b/i.exec(
          note,
        );
      if (!action) return false;
      // An action prefix alone does not make a progress note: "Running two tasks is faster"
      // and "Let me check; the cache is stale" contain answers. Ambiguous clauses stay visible.
      const rest = note.slice(action[0].length);
      return (
        !/[,;:|]|\b(?:am|is|are|was|were|has|have|had|can|could|should|would|will|because|but|however|therefore|means?|shows?|reveals?|than)\b/i.test(
          rest,
        ) && !hasFiniteVerb(rest)
      );
    })
  );
}

/// Words before which an "-ed" word is an adjective ("the failed jobs"), not a verb.
const ED_ADJECTIVE_AFTER =
  /^(?:the|a|an|its|this|that|these|those|each|every|all|any|my|your|our|their|some|both|for|of|in|on|from|with|to|at|by|and|or|newly|recently)$/i;
/// Verbs a gerund subject takes: "Checking the cache found no errors." and "Running both takes 2 s."
/// report a result, so the sentence is a finding, not narration (#42279 follow-up F1).
const FINDING_VERBS =
  /^(?:found|took|made|gave|got|came|went|ran|saw|left|broke|said|told|kept|held|brought|knew|lost|won|beat|fell|grew|stood|meant|cost|finds|takes|makes|gives|gets|works|fails|passes|helps|saves|costs|beats|wins|needs|breaks|returns|stays|matches|fixes|causes|leads|keeps|hides|drops|skips|hangs|crashes|seems|looks|turns|proves|confirms)$/i;
/// Whether the words after a narration's action hold a finite verb: the action was a gerund
/// subject and the sentence says what it found. The first word is the action's object, never a verb.
function hasFiniteVerb(rest: string): boolean {
  const words = rest
    .trim()
    .split(/\s+/)
    .map((word) => word.replace(/[^\p{L}'’-]/gu, ""));
  return words.some(
    (word, at) =>
      at > 0 &&
      (FINDING_VERBS.test(word) ||
        (/^[\p{L}]{2,}ed$/u.test(word) &&
          !/(?:eed|need)$/i.test(word) &&
          !ED_ADJECTIVE_AFTER.test(words[at - 1] ?? ""))),
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
/// A seam the reader never sees never splits a run either (Leo, 2026-11-12, ask-bc2af01f6e: "how come
/// these aren't folded? they were missed in the logic?"): two runs with nothing between them (a todo
/// update that ended the first run and moved to the turn's end, `staysOut`) and two runs with only an
/// agent message of no visible text between them are one run, with no note line.
export function mergeShortNotes(
  rows: readonly AcpmuxRow[],
  keep?: ReadonlySet<string>,
  edits = false,
  joinNotes = true,
): AcpmuxRow[] {
  const run = (row: AcpmuxRow | undefined) => isRun(row) || (edits && row?.kind === "activity");
  const out: AcpmuxRow[] = [];
  // The stretch being joined at `out`'s end: its calls and member ids grow in place and go on its
  // row once it ends, so a live turn of many notes and runs copies each call once, not once per note.
  let items: AcpmuxActivity[] | undefined;
  let joined: string[] | undefined;
  const close = () => {
    if (items) out[out.length - 1] = { ...out.at(-1)!, items, joined };
    items = joined = undefined;
  };
  for (let index = 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    const previous = out.at(-1);
    let to = index;
    while (drawsNothing(rows[to])) to += 1;
    const note = joinNotes && to === index && isShortNote(row) && !keep?.has(row.id);
    if (note) to += 1;
    // A stretch being joined is a run already (`items`): its first run is not read again per note.
    // A run of a turn the agent ran on its own never joins another turn's run (backgroundTurns.ts).
    if (
      (items !== undefined || run(previous)) &&
      (note || to > index || run(row)) &&
      run(rows[to]) &&
      rows[to]!.inBackground === previous!.inBackground
    ) {
      const next = rows[to]!;
      items ??= [...(previous!.items ?? [])];
      joined ??= [...(previous!.joined ?? [previous!.id])];
      if (note) items.push({ kind: "note", text: row.text!.trim() });
      for (const item of next.items ?? []) items.push(item);
      let version = previous!.version;
      for (let at = index; at <= to; at += 1) {
        joined.push(rows[at]!.id);
        version = mixVersion(version, rows[at]!.version);
      }
      out[out.length - 1] = {
        ...previous!,
        toolCount: (previous!.toolCount ?? 0) + (next.toolCount ?? 0),
        version,
      };
      index = to;
    } else {
      close();
      out.push(row);
    }
  }
  close();
  return out.length === rows.length ? (rows as AcpmuxRow[]) : out;
}

/// A finished step with nothing in it to draw: no items, or only thoughts that draw no row once done
/// (model.ts `onlyQuietThoughts`: Claude's omitted or redacted thinking reaches the pane empty). A
/// fold over such steps alone opens to nothing (c-763204aef8, "API-error turn shows an empty 'Worked
/// for Ns'"), whether the turn failed, was stopped, was steered or completed: it is no work. A step
/// that counts calls (`toolCount`) stands for them even when its items were not kept, so it stays.
const drawsNoWork = (row: AcpmuxRow) =>
  row.kind === "activity" && !row.live && (row.items?.length ? onlyQuietThoughts(row) : !row.toolCount);

/// An agent message with no visible text: it draws no row (visibleMessage.ts), so it splits nothing.
const drawsNothing = (row: AcpmuxRow | undefined) =>
  row?.kind === "assistant" && !row.incoming && isVisiblyEmptyMessage(row);

const mixVersion = (a: number, b: number) => (a * 1_009 + b * 7 + 1) % 2_147_483_647;

/// The turn's one "Worked for" fold, keyed by its original prompt. Steers and received reports
/// already related to that turn walk back to the same anchor. An unrelated incoming prompt still
/// opens its own turn, and a pending or failed prompt opens nothing unless it is the first one.
/// A row of a turn the agent ran on its own is behind that turn's line (backgroundTurns.ts), not
/// the "Worked for" before it: Find and a link open the line.
export function turnFoldFor(rows: readonly AcpmuxRow[], index: number): string | undefined {
  const background = rows[index]?.inBackground;
  if (background !== undefined) {
    // An ended turn the agent ran on its own folds its work under its own "Worked for" (`foldTailTurns`).
    const line = backgroundTurnRowId(background);
    for (let at = Math.min(index, rows.length - 1); at >= 0; at -= 1)
      if (rows[at]!.id === line) return endsDrawingRows(rows[at]!) ? tailWorkedId(background) : line;
    return line;
  }
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
    if (opensTurn(row)) {
      // Split in order, the fold that holds the row starts at the last message above it that splits.
      const split = foldsInOrder() ? foldStarts(rows, at, Math.min(index, rows.length - 1) + 1).at(-1) : undefined;
      return `${WORKED}-${foldKeyId(split === undefined ? row : rows[split]!)}`;
    }
    if (row.kind === "user" && continuesTurn(row)) first = row;
  }
  return first && `${WORKED}-${foldKeyId(first)}`;
}

/// Whether a finished turn's folds split at each message that came in mid-turn
/// (turnFoldSteered.experiment.ts `in-order`, foldSegments). A family with no turn fold draws every
/// fold open, so its keys never matter.
const foldsInOrder = () => experimentArm(turnFoldSteered) === "in-order";

/// The rows a turn's fold anchored at `start` holds: from `from` up to `end` (exclusive), the next
/// prompt that opens a turn, or, split in order, the next fold's start (`foldStarts`). Another agent's
/// message that starts a fold is its first entry; the prompt and the person's steer are not.
function foldSpan(rows: readonly AcpmuxRow[], start: number): { from: number; end: number } {
  let end = rows.length;
  for (let at = start + 1; at < rows.length; at += 1)
    if (opensTurn(rows[at]!) && !isUnsent(rows[at]!)) {
      end = at;
      break;
    }
  const anchor = rows[start];
  // A turn the agent ran on its own folds its rows up to the next one (`foldTailTurns`).
  if (anchor?.kind === BACKGROUND_TURN) {
    let next = start + 1;
    while (next < end && rows[next]!.kind !== BACKGROUND_TURN) next += 1;
    return { from: start + 1, end: next };
  }
  if (!anchor || !foldsInOrder()) return { from: start + 1, end };
  let prompt = start;
  while (prompt > 0 && !(opensTurn(rows[prompt]!) && !isUnsent(rows[prompt]!))) prompt -= 1;
  const next = foldStarts(rows, prompt, end).find((index) => index > start);
  return { from: prompt !== start && !isOwnSteer(anchor) ? start : start + 1, end: next ?? end };
}

/// The prompt id a turn's fold is keyed by: a delivery Find expanded from an inbox notice
/// (pendingMessages.ts `searchablePendingRows`) keys by the notice that opened the turn, as
/// turnView does, so Find opens the fold that draws it.
const foldKeyId = (row: AcpmuxRow) => row.inboxSource ?? row.id;

/// The keys a click on fold `id` covers: `id`, and when it is a turn's "Worked for", that turn's
/// original prompt's (`key`) and each of its steers' (openFolds reads them all).
/// Split in order (`foldsInOrder`), each fold is its own disclosure: a click covers its key (`key`) and
/// the provisional keys of the received messages inside it (openFolds), never another fold's.
function turnFoldKeys(rows: readonly AcpmuxRow[], id: string): { keys: string[]; key?: string } {
  // The "Worked for" over an ended turn the agent ran on its own (`foldTailTurns`) is its own
  // disclosure, never its prompt's turn's.
  const background = tailWorkedBackground(id);
  if (background !== undefined) return { keys: [id], key: id };
  const keys = [id];
  const index = id.startsWith(`${WORKED}-`) ? rows.findIndex((row) => `${WORKED}-${row.id}` === id) : -1;
  const key = index >= 0 ? turnFoldFor(rows, index) : undefined;
  if (foldsInOrder()) {
    const start = key ? rows.findIndex((row) => `${WORKED}-${row.id}` === key) : -1;
    if (start < 0) return { keys };
    if (key !== id) keys.push(key!);
    const { end } = foldSpan(rows, start);
    for (let at = start + 1; at < end; at += 1) {
      const row = rows[at]!;
      if (row.kind === "user" && continuesTurn(row)) keys.push(`${WORKED}-${row.id}`);
    }
    return { keys, key };
  }
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

/// The other keys a click on the drawn line `line` covers: a background-task or message run's line is
/// open under any member's key (backgroundRuns.ts, messageRuns.ts), so two runs the reader opened that
/// a reply drawing nothing joins hold two keys, and closing the joined line clears them all. Read from
/// the line's own member list, no scan of the transcript.
export function foldCovers(line: AcpmuxRow | undefined): string[] {
  if (line?.backgroundRun) return line.backgroundRun.rows.map(backgroundRunRowId);
  if (line?.messageRun) return line.messageRun.rows.map(messageRunRowId);
  if (line?.workedRun) {
    const head = line.workedRun.head ?? line.id;
    if (line.workedRun.head) return [head, workedRunOpenKey(head)];
    if (line.workedRun.ids.length > 1 || line.foldOpen) return [workedRunOpenKey(head)];
  }
  return [];
}

/// The key that keeps a joined "Worked for" open as one (`joinBareWorked`): set with its first
/// turn's own key, it opens each bare turn after that one too.
export const workedRunOpenKey = (id: string) => `worked-run-open:${id}`;

/// The closed "Worked for" a finished turn drew and nothing else but its footer (an empty footer
/// draws nothing; a turn of calls alone ends on its footer with their Copy, `footer`), or undefined.
/// One that names its messages or (`namesWork`, turnFoldSteered's `header` arm) its work, a failed or
/// stopped turn's, or a dated turn's keeps its own line. workedLine's outcome arms read the calls too
/// (`workedRuns`), but their line sums them: joined, it says what all its turns did (`joinBareWorked`).
function bareWorked(
  drawn: readonly AcpmuxRow[],
  namesWork: boolean,
): { worked: AcpmuxRow; footer?: AcpmuxRow } | undefined {
  let worked: AcpmuxRow | undefined;
  let footer: AcpmuxRow | undefined;
  for (const row of drawn) {
    if (isEmptyFooter(row)) continue;
    if (worked && !footer && row.kind === "turnSummary" && row.status === "completed" && !row.text) {
      footer = row;
      continue;
    }
    if (worked || row.kind !== WORKED) return undefined;
    worked = row;
  }
  if (!worked || worked.foldOpen || worked.status !== "completed") return undefined;
  if (worked.previous !== undefined || worked.workedMessages || (namesWork && worked.workedRuns)) return undefined;
  return { worked, ...(footer && { footer }) };
}

/// `row` as the line of a run of "Worked for"s (`workedRun`), the same object for the same row and run:
/// a turn shaped again (the next one opened, a record came into it) leaves the line it drew as it was,
/// so the layout and height caches keep it.
const workedRunRows = new WeakMap<AcpmuxRow, { key: string; row: AcpmuxRow }>();
function inWorkedRun(row: AcpmuxRow, ids: string[], head?: string): AcpmuxRow {
  const key = `${head ?? ""}\n${ids.join("\n")}`;
  const kept = workedRunRows.get(row);
  if (kept?.key === key) return kept.row;
  const shaped: AcpmuxRow = { ...row, workedRun: head === undefined ? { ids } : { ids, head } };
  workedRunRows.set(row, { key, row: shaped });
  return shaped;
}

/// `joinBareWorked`, the same object for the same two lines: each reshape of the bare turn (it is the
/// last, or the turn after it opened) joins them again.
const joinedLines = new WeakMap<AcpmuxRow, WeakMap<AcpmuxRow, AcpmuxRow>>();
function joinedBareWorked(run: AcpmuxRow, bare: AcpmuxRow): AcpmuxRow {
  let byBare = joinedLines.get(run);
  if (!byBare) joinedLines.set(run, (byBare = new WeakMap()));
  let joined = byBare.get(bare);
  if (!joined) byBare.set(bare, (joined = joinBareWorked(run, bare)));
  return joined;
}

/// `bare` joined into the line `run` already draws: one "Worked for" over their summed time and calls,
/// keyed by its first member so the line keeps its place, its version moving with each member.
function joinBareWorked(run: AcpmuxRow, bare: AcpmuxRow): AcpmuxRow {
  const sum = (a: number | undefined, b: number | undefined) =>
    a === undefined || b === undefined ? undefined : a + b;
  const calls = (run.workedCalls ?? 0) + (bare.workedCalls ?? 0);
  const workedRuns = [...(run.workedRuns ?? []), ...(bare.workedRuns ?? [])];
  return {
    ...run,
    version: mixVersion(run.version, bare.version),
    durationMs: sum(run.durationMs, bare.durationMs),
    toolCount: sum(run.toolCount, bare.toolCount),
    ...(calls > 0 && { workedCalls: calls }),
    ...(workedRuns.length && { workedRuns }),
    workedRun: { ids: [...run.workedRun!.ids, bare.id] },
  };
}

/// Toggle at the person's click, clearing provisional steer keys for the same turn too. This
/// keeps a fold opened at a history page's edge closable after the original prompt arrives.
/// `covers`: the clicked line's other keys (`foldCovers`), cleared with it.
export function toggleTurnFold(
  rows: readonly AcpmuxRow[],
  expanded: ReadonlySet<string>,
  id: string,
  covers: readonly string[] = [],
): Set<string> {
  const next = new Set(expanded);
  const { keys: own, key } = turnFoldKeys(rows, id);
  const keys = covers.length ? [...own, ...covers] : own;
  const cancelled = turnFoldOpensOpen(rows, key ?? id);
  const open =
    keys.some((key) => expanded.has(key)) || (cancelled && !keys.some((key) => expanded.has(closedTurnFoldKey(key))));
  for (const key of keys) {
    next.delete(key);
    next.delete(closedTurnFoldKey(key));
  }
  if (!open) {
    next.add(key ?? id);
    // A joined "Worked for" opens every turn it stands for, each then drawing its own open line.
    for (const cover of covers) if (cover === workedRunOpenKey(key ?? id)) next.add(cover);
  } else if (id.startsWith(`${WORKED}-`)) next.add(closedTurnFoldKey(key ?? id));
  closeTurnRuns(rows, next, id);
  return next;
}

const closedTurnFoldKey = (id: string) => `${CLOSED_TURN_FOLD}${id}`;

/// A continued stop is bookkeeping, not the summary that decides the fold's resting state.
function hidesContinuedSummary(rows: readonly AcpmuxRow[], at: number, last: boolean): boolean {
  const row = rows[at]!;
  if (row.kind !== "turnSummary" || !row.continued) return false;
  const tail = rows.slice(at + 1);
  return tail.some(continuesTurn) || (last && !tail.some((later) => later.kind === "turnSummary"));
}

/// A turn's fold that draws open until a click closes it: a stopped turn's, and the one over an agent's
/// message the turn only replied to (shapeTurn `promptOnly`).
function turnFoldOpensOpen(rows: readonly AcpmuxRow[], id: string): boolean {
  if (!id.startsWith(`${WORKED}-`)) return false;
  const start = rows.findIndex((row) => `${WORKED}-${row.id}` === id);
  if (start < 0) return false;
  let end = start + 1;
  while (end < rows.length && !(opensTurn(rows[end]!) && !isUnsent(rows[end]!))) end += 1;
  const turn = rows.slice(start + 1, end);
  const summary = turn.find(
    (row, at) => row.kind === "turnSummary" && !hidesContinuedSummary(turn, at, end === rows.length),
  );
  if (summary === undefined) return false;
  return (
    isStopped(summary) || (isAgentPrompt(rows[start]!) && repliesOnly(turn.filter((row) => row.kind !== "turnSummary")))
  );
}

/// A turn's fold opens with every line in it closed (Lucas, 2026-11-11): the runs of messages and of
/// background work it holds are opened by key in `expanded`, not in the disclosure store, so a click
/// on "Worked for" `id` clears their keys from `expanded`, in place. Any view's click (App.tsx).
/// Every row of the turn counts, a received message too, and a run's line keyed by a folded copy of
/// an edit run (`<id>:fold`, messageRuns.ts `openMessageRuns`).
export function closeTurnRuns(rows: readonly AcpmuxRow[], expanded: Set<string>, id: string): void {
  if (!id.startsWith(`${WORKED}-`) || expanded.size === 0) return;
  const { key } = turnFoldKeys(rows, id);
  const start = rows.findIndex((row) => `${WORKED}-${row.id}` === (key ?? id));
  if (start < 0) return;
  const { from, end } = foldSpan(rows, start);
  for (let at = from; at < end; at += 1) {
    const row = rows[at]!;
    for (const line of [messageRunRowId(row.id), backgroundRunRowId(row.id)]) {
      expanded.delete(line);
      expanded.delete(`${line}${FOLDED}`);
    }
  }
}

/// The rows and calls inside the turn of "Worked for" `id`, its prompt and steers left out: what the
/// fold draws, whose lines the reader may have opened (transcriptDisclosureModel.ts
/// `forgetInsideTurn`). Empty when `id` is not a turn's fold. An edit call is left out: the turn's
/// edited-files card under its answer, outside the fold, draws the same calls under the same keys,
/// so forgetting them would close a diff the reader opened there; `edits` collects them, for the runs
/// and groups they start (transcriptDisclosureModel.ts `forgetInsideTurn`).
export function turnInsideIds(rows: readonly AcpmuxRow[], id: string, edits?: Set<string>): Set<string> {
  const ids = new Set<string>();
  if (!id.startsWith(`${WORKED}-`)) return ids;
  const edit = (kind: string | undefined) =>
    kind === "edit" || kind === "delete" || kind === "move" || kind === "fileChange";
  const { key } = turnFoldKeys(rows, id);
  const start = rows.findIndex((row) => `${WORKED}-${row.id}` === (key ?? id));
  if (start < 0) return ids;
  const { from, end } = foldSpan(rows, start);
  for (let at = from; at < end; at += 1) {
    const row = rows[at]!;
    if (row.kind === "user") continue;
    ids.add(row.id);
    for (const item of row.items ?? []) if (item.tool?.id) (edit(item.tool.kind) ? edits : ids)?.add(item.tool.id);
  }
  return ids;
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
