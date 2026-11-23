// AcpmuxPane's turn rows and turn actions (RFD 0046 step 2.5): the bodies of its `turnRowsShown` and
// `turnActions` memos, moved out of App.tsx as they were. The memos, their deps arrays and every
// hook stay in AcpmuxPane; these are plain functions over the values it closes over.
import type { RefObject } from "react";
import type { AccessOffer } from "../accessOffer";
import { callNative } from "../callNative";
import type { HarnessCatalog } from "../catalog";
import type { HunkReview } from "../changes/hunkReview";
import { type ChatAccounts, ownRouteOf } from "../chatAccounts";
import type { Presentation } from "../chatDisplay";
import type { CloudSignIn } from "../cloudAgentLogin";
import type { ComposerHandle } from "../Composer";
import { PICKER_LABELS } from "../composerPickerModel";
import type { MessageBranch } from "../conversation/branches";
import { chatAfterRewind, type ChatMarks } from "../conversation/cloudTurnCheckpoints";
import { projectInboxRows } from "../conversation/laneNoticeBatches";
import { messagesRows } from "../conversation/messagesRows";
import { takeBackSteer, takesSteersBack } from "../conversation/pendingSteerModel";
import type { QueuedMessageActionsValue } from "../conversation/QueuedMessageCard";
import type { RetryModel } from "../conversation/retryModelSections";
import { withoutQuietThoughts } from "../conversation/thoughts";
import {
  answerThrough,
  CHAT_CHANGED,
  compactThrough,
  offersCompact,
  resumeThrough,
  type TurnActions,
} from "../conversation/turnActions";
import {
  callsToHold,
  foldsToHold,
  linedCallOf,
  oneKeyPerMessageRun,
  rowsToHold,
  withHeldFolds,
  withoutHeldCalls,
  withoutHeldRows,
} from "../conversation/turnEndHold";
import { retryFailedPrompt, sendUntilTaken } from "../conversation/turnRetry";
import { trayWaitAgents, turnViewFrom, type TurnView } from "../conversation/turns";
import type { Folds } from "../conversation/viewFolds";
import type { AcpmuxDirectClient } from "../direct";
import { translate } from "../i18n";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import { postNative } from "../native";
import { openPicker } from "../pickerOpeners";
import { acpmuxPerf } from "../perf";
import { withoutAskedCalls } from "../permissions/askRows";
import { editQueued } from "../rows/rowActions";
import { withShellRows, type ShellRun } from "../shell/shellRuns";
import { withStartedSessions, type StartedCache, type StartedSession } from "../started/startedSessions";
import { restartPrompt, restartReaches } from "../subagents/restart";
import { runResume as runSubagentResume } from "../subagents/resumeState";
import { runRetry, type RetryTarget } from "../subagents/retryState";
import { type DoneLineCache, withSubagentLines } from "../subagents/runningTray";
import type { Subagent } from "../subagents/subagentFold";
import { subagentRowsFrom, type SubagentRows } from "../subagents/subagentRows";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;
type Held = { session?: string; keys: ReadonlySet<string> };

/// What `turnRowsShownFrom` reads of AcpmuxPane: the values its `turnRowsShown` memo closes over.
export interface TurnRowsShownDeps {
  chatPresentation: Presentation;
  childRows: AcpmuxRow[] | undefined;
  sourceRows: AcpmuxRow[];
  panelAsks: Set<string>;
  started: readonly StartedSession[];
  startedCache: RefObject<StartedCache>;
  subagentTray: boolean;
  doneLines: RefObject<DoneLineCache>;
  workflowLabsEnabled: boolean;
  lastTurns: RefObject<{ sessionId: string | undefined; turns: TurnView; subagents: SubagentRows } | undefined>;
  shownSessionId: string | undefined;
  heldCalls: RefObject<Held & { lined?: string }>;
  callRelease: number;
  transcriptInView: RefObject<(() => readonly string[] | null) | undefined>;
  heldRuns: RefObject<Held & { asked?: true }>;
  heldWorked: RefObject<Held>;
  heldWorkedClosing: RefObject<boolean>;
  /// Only the fields the memo's deps array names.
  snapshot: Pick<
    AcpmuxSnapshot,
    "isWorking" | "canLoadNewer" | "clockOffsetMs" | "turnStartedAtMs" | "waitingSteers"
  > & {
    summary?: Pick<Summary, "family">;
  };
  sessionStatus: boolean;
  messageBreaks: readonly number[];
  supersededReplyIds: Set<string> | undefined;
  foldsSeen: RefObject<{ session?: string; folds?: Folds }>;
  folds: Folds;
  heldFolds: RefObject<Held>;
  chatShellRuns: ShellRun[];
}

/// What `turnActionsFrom` reads of AcpmuxPane: the values its `turnActions` memo closes over.
export interface TurnActionsDeps {
  showCall: (toolCallId: string, startedAt?: number) => boolean;
  /// True: a failed turn's Retry of `prompt` is held (`@computer-use` while Computer Use is not ready,
  /// CMUX-682); the chat already said why, or the click opened setup.
  holdsRetry?: (prompt: string) => boolean;
  restartChat: string | undefined;
  queuedMessageActionsRef: RefObject<QueuedMessageActionsValue | undefined>;
  stableBranches: Map<string, MessageBranch>;
  runningBranchSessions: ReadonlySet<string>;
  turnForkable: boolean;
  forkAny: boolean;
  stablePromptSeqs: Map<string, number>;
  forkSeq: number | undefined;
  cloudMachineID: string | undefined;
  tryAnotherApproachInFlight: RefObject<Promise<void> | undefined>;
  cloudTurnRewind: ChatMarks | undefined;
  rewindReady: ReadonlySet<string>;
  rewindInFlight: RefObject<boolean>;
  rewindRows: Map<string, string>;
  snapshotRef: RefObject<AcpmuxSnapshot | undefined>;
  setCloudTurnRewind: (
    update: ChatMarks | undefined | ((marks: ChatMarks | undefined) => ChatMarks | undefined),
  ) => void;
  directClient: RefObject<AcpmuxDirectClient | undefined>;
  stableEditSeqs: Map<string, number>;
  connected: boolean;
  sessionIdRef: RefObject<string | undefined>;
  queueRunsNext: boolean;
  nextStepKey: (fire: () => void) => () => void;
  asker: string | undefined;
  /// Only the fields the memo's deps array names.
  snapshot: Pick<AcpmuxSnapshot, "sessionId" | "commands"> & {
    summary?: Pick<Summary, "hostKind" | "cwd" | "harness" | "model" | "backgroundsWork">;
  };
  subagentRelayChat: string | undefined;
  retryModels: RetryModel[];
  retryHarnessName: string | undefined;
  retryTop: string[] | undefined;
  composerHandle: RefObject<ComposerHandle | null>;
  loginCommand: string | undefined;
  chatSignIns: {
    cloudSignIn: CloudSignIn | undefined;
    apiKeySignIn: CloudSignIn | undefined;
    refusedSignIn: CloudSignIn | undefined;
  };
  hunkReview: HunkReview;
  catalog: HarnessCatalog;
  cloudRouteHostKind: "local" | "cloud" | undefined;
  cloudTeamMachine: boolean;
  chatAccounts: ChatAccounts | undefined;
  access: AccessOffer;
}

/// The transcript's rows as AcpmuxPane draws them (its `turnRowsShown` memo's body).
export function turnRowsShownFrom(deps: TurnRowsShownDeps) {
  const {
    chatPresentation,
    childRows,
    sourceRows,
    panelAsks,
    started,
    startedCache,
    subagentTray,
    doneLines,
    workflowLabsEnabled,
    lastTurns,
    shownSessionId,
    heldCalls,
    callRelease,
    transcriptInView,
    heldRuns,
    heldWorked,
    heldWorkedClosing,
    snapshot,
    sessionStatus,
    messageBreaks,
    supersededReplyIds,
    foldsSeen,
    folds,
    heldFolds,
    chatShellRuns,
  } = deps;
  if (chatPresentation === "messages") return messagesRows(childRows ?? sourceRows);
  if (childRows) {
    return withoutAskedCalls(withoutQuietThoughts(childRows), panelAsks);
  }
  const startedRows = withStartedSessions(sourceRows, started, startedCache.current);
  // Labs: a Claude workflow is a card where it started (summary/WorkflowCard.tsx), not a tray line.
  const rows = subagentTray ? withSubagentLines(startedRows, doneLines.current, workflowLabsEnabled) : startedRows;
  // The tray takes the running groups out of the rows, so the live line's wait is counted first.
  const trayAgents = subagentTray ? trayWaitAgents(startedRows) : 0;
  return acpmuxPerf.timed("app.rows", () => {
    const last = lastTurns.current?.sessionId === shownSessionId ? lastTurns.current : undefined;
    if (heldCalls.current.session !== shownSessionId) heldCalls.current = { session: shownSessionId, keys: new Set() };
    // Null while the view follows the latest row: what was held out goes back in there. The view
    // following again with calls held (`callRelease`) shapes the rows again for that.
    void callRelease;
    const viewNow = transcriptInView.current?.();
    if (!viewNow && heldCalls.current.keys.size > 0) heldCalls.current = { ...heldCalls.current, keys: new Set() };
    // The reader asked for a held run (`showHeldRuns`): they all go back in, and this pass holds none.
    const asked = heldRuns.current.asked === true;
    if (heldRuns.current.session !== shownSessionId || asked || (!viewNow && heldRuns.current.keys.size > 0))
      heldRuns.current = { session: shownSessionId, keys: new Set() };
    if (heldWorked.current.session !== shownSessionId)
      heldWorked.current = { session: shownSessionId, keys: new Set() };
    else if (!viewNow && heldWorked.current.keys.size > 0) {
      // Back at the latest row: the Worked for held open over what the reader read closes, in
      // the turn's end motion (VirtualTranscript `heldWorkedClosing`), never in one frame.
      heldWorked.current = { session: shownSessionId, keys: new Set() };
      heldWorkedClosing.current = true;
    }
    const shapeFrom = (source: readonly AcpmuxRow[], open: Folds) =>
      turnViewFrom(
        source,
        open,
        {
          // A window whose newer records are left (direct.ts `newerLeft`) ends in history: the running turn's
          // live line is drawn under the chat's latest row, never under the window's last.
          working: snapshot.isWorking && snapshot.canLoadNewer !== true,
          clockOffset: snapshot.clockOffsetMs,
          turnStartedAtMs: snapshot.turnStartedAtMs,
          sessionStatus,
          // A finished turn folds as its harness family's app does: Codex under one Worked for, Claude per run.
          agentFamily: snapshot.summary?.family,
          // Other sessions' messages among them, two or more in a run, draw as one card.
          waitingSteers: snapshot.waitingSteers,
          messageBreaks,
          trayAgents,
          supersededReplyIds,
        },
        last?.turns,
      );
    const shape = (open: Folds) =>
      shapeFrom(withoutHeldRows(withoutHeldCalls(rows, heldCalls.current.keys), heldRuns.current.keys), open);
    // While the reader is scrolled up, an update that would fold away a row they have in view (a
    // turn's end folding its work, a run of calls closing) leaves that fold open
    // (conversation/turnEndHold.ts); the effect below puts it in `expanded`. The reader's own
    // toggles change `folds` and are left alone, as is a chat just switched to.
    const ownChange = foldsSeen.current.session !== shownSessionId || foldsSeen.current.folds !== folds;
    foldsSeen.current = { session: shownSessionId, folds };
    if (heldFolds.current.session !== shownSessionId) heldFolds.current = { session: shownSessionId, keys: new Set() };
    // The open folds with what a turn's end holds: the reader's held folds and a deferred Worked for.
    const heldOpen = () =>
      heldWorked.current.keys.size === 0
        ? heldFolds.current.keys
        : new Set([...heldFolds.current.keys, ...heldWorked.current.keys]);
    let turns = shape(withHeldFolds(folds, heldOpen()));
    const inView = ownChange ? null : transcriptInView.current?.();
    if (inView) {
      const worked = new Set<string>();
      const held = foldsToHold(rows, turns.rows, last?.turns.rows, turns.reusedRows, inView, folds, worked);
      if (worked.size > 0) {
        heldWorked.current = { session: shownSessionId, keys: new Set([...heldWorked.current.keys, ...worked]) };
        turns = shape(withHeldFolds(folds, heldOpen()));
      }
      if (held.length > 0) {
        const kept = heldFolds.current.keys;
        heldFolds.current = { session: shownSessionId, keys: new Set([...kept, ...held]) };
        turns = shape(withHeldFolds(folds, heldOpen()));
        // One key per message run, the one its line closes by (turnEndHold.ts): the line and its
        // rows draw the same with it alone.
        const one = oneKeyPerMessageRun(held, turns.rows, turns.reusedRows);
        if (one.length !== held.length)
          heldFolds.current = { session: shownSessionId, keys: new Set([...kept, ...one]) };
      }
      // The finished runs a running turn kept out of sight, which this update draws again between
      // rows in view (another agent's prompt ends the stretch they are in), stay out while the
      // reader is scrolled up, as they saw the stretch (turnEndHold.ts `rowsToHold`).
      const back = asked ? [] : rowsToHold(rows, turns.rows, last?.turns.rows, turns.reusedRows, inView);
      if (back.length > 0) {
        heldRuns.current = { session: shownSessionId, keys: new Set([...heldRuns.current.keys, ...back]) };
        turns = shape(withHeldFolds(folds, heldOpen()));
      }
    }
    // A command the live line named out of its run, which it no longer names, stays out of the
    // run while the reader is scrolled up, as they saw it (turnEndHold.ts, cmux#33200).
    let lined = linedCallOf(turns.rows);
    // A held command that still runs and that the line would name again (a newer call took the
    // line and finished) goes back to the line, out of its run as before, so it never reads
    // nowhere: in neither its run nor the line. Shaped from every row only while one is held.
    if (snapshot.isWorking && heldCalls.current.keys.size > 0) {
      const again = linedCallOf(shapeFrom(rows, withHeldFolds(folds, heldOpen())).rows);
      if (again !== undefined && heldCalls.current.keys.has(again)) {
        const keys = new Set(heldCalls.current.keys);
        keys.delete(again);
        heldCalls.current = { ...heldCalls.current, keys };
        turns = shape(withHeldFolds(folds, heldOpen()));
        lined = linedCallOf(turns.rows);
      }
    }
    const letGo = viewNow ? callsToHold(heldCalls.current.lined, lined, heldCalls.current.keys) : undefined;
    if (letGo !== undefined) {
      heldCalls.current = { ...heldCalls.current, keys: new Set([...heldCalls.current.keys, letGo]) };
      turns = shape(withHeldFolds(folds, heldOpen()));
      lined = linedCallOf(turns.rows);
    }
    heldCalls.current.lined = lined;
    // Expand inbox summaries only after turn shaping. Source rows remain the semantic anchors
    // for turn boundaries, retries and queue actions; this is a display-only projection.
    const displayRows = projectInboxRows(turns.rows, last?.turns.rows, turns.reusedRows);
    const subagents = subagentRowsFrom(displayRows, folds, last?.subagents);
    lastTurns.current = { sessionId: shownSessionId, turns, subagents };
    // After the turns: a live turn's status reads its last row, the call's included.
    return withoutAskedCalls(withShellRows(subagents.rows, chatShellRuns), panelAsks);
  });
}

/// The actions a turn's rows offer (AcpmuxPane's `turnActions` memo's body).
export function turnActionsFrom(deps: TurnActionsDeps): TurnActions {
  const {
    showCall,
    holdsRetry,
    restartChat,
    queuedMessageActionsRef,
    stableBranches,
    runningBranchSessions,
    turnForkable,
    forkAny,
    stablePromptSeqs,
    forkSeq,
    cloudMachineID,
    tryAnotherApproachInFlight,
    cloudTurnRewind,
    rewindReady,
    rewindInFlight,
    rewindRows,
    snapshotRef,
    setCloudTurnRewind,
    directClient,
    stableEditSeqs,
    connected,
    sessionIdRef,
    queueRunsNext,
    nextStepKey,
    asker,
    snapshot,
    subagentRelayChat,
    retryModels,
    retryHarnessName,
    retryTop,
    composerHandle,
    loginCommand,
    chatSignIns,
    hunkReview,
    catalog,
    cloudRouteHostKind,
    cloudTeamMachine,
    chatAccounts,
    access,
  } = deps;
  return {
    showCall,
    canSendPromptAgain: restartChat !== undefined,
    queuedMessages: () => queuedMessageActionsRef.current,
    ...(stableBranches.size > 0 && {
      branches: {
        of: stableBranches,
        running: runningBranchSessions,
        open: (sessionId: string) => void callNative("chat.select", { sessionId }).catch(() => undefined),
      },
    }),
    ...(turnForkable && {
      fork: (throughSeq: number) => void callNative("chat.fork", { throughSeq }).catch(() => undefined),
      forkAny,
      promptTurns: stablePromptSeqs,
    }),
    // Cloud's latest-turn action is available even when the harness does not advertise the
    // ordinary transcript fork capability; ForkRuns supplies the machine copy and this action
    // uses the child acpmux bridge for the transcript.
    forkSeq,
    ...(cloudMachineID &&
      forkSeq !== undefined && {
        tryAnotherApproach: async (throughSeq: number) => {
          if (tryAnotherApproachInFlight.current) return tryAnotherApproachInFlight.current;
          // Straight to native: callNative would select the page action of the same name.
          const task = postNative("chat.tryAnotherApproach", { throughSeq });
          const settled = task.then(
            () => undefined,
            () => undefined,
          );
          tryAnotherApproachInFlight.current = settled;
          try {
            await task;
          } finally {
            if (tryAnotherApproachInFlight.current === settled) tryAnotherApproachInFlight.current = undefined;
          }
        },
      }),
    // Back to before this turn: the host restores the Cloud machine to the checkpoint taken before
    // the prompt's turn and answers how long it took. Straight to native, as Try another approach.
    ...(cloudMachineID &&
      cloudTurnRewind && {
        rewind: {
          ready: rewindReady,
          before: async (rowId: string) => {
            if (rewindInFlight.current) throw new Error("rewind in flight"); // l10n-allow: an error the button reads as failed, never shown
            rewindInFlight.current = true;
            const mark = rewindRows.get(rowId) ?? rowId;
            const session = snapshotRef.current?.sessionId;
            try {
              const answer = await postNative<{ seconds?: unknown } | null>("chat.rewindTurn", { rowId: mark });
              // Back at that checkpoint: the chat's marks past it name discarded states.
              setCloudTurnRewind((marks) => chatAfterRewind(marks, answer, session, mark));
              return { seconds: typeof answer?.seconds === "number" ? answer.seconds : Number.NaN };
            } finally {
              rewindInFlight.current = false;
            }
          },
        },
      }),
    promptImage: (id: string) => directClient.current?.promptImage(id) ?? Promise.resolve(undefined),
    ...(stableEditSeqs.size > 0 && {
      edit: {
        seqs: stableEditSeqs,
        send: (rowId: string, throughSeq: number, text: string) =>
          callNative<boolean>("chat.editResend", { rowId, throughSeq, text }).then(
            (sent) => sent === true,
            () => false,
          ),
      },
    }),

    ...(connected &&
      ((resend: (rowId: string, prompt: string) => Promise<unknown>) => ({
        retry: (rowId: string, prompt: string) =>
          resend(rowId, prompt).then(
            () => true,
            () => false,
          ),
        // A failed turn's Retry asks acpmux to retry the turn of the chat its row was drawn for
        // (turnRetry.ts), and sends the prompt again only where acpmux cannot. Like Continue and
        // Restart, never to a View Only chat or a read-only pane, and never to the next chat
        // during a switch's hold: checked before it asks and again before a fallback send.
        ...(restartChat && {
          retryFailed: ((owner: string) => (rowId: string | undefined, prompt: string | undefined) => {
            const reaches = () => restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession);
            const client = directClient.current;
            // Nothing to ask (the daemon went away and the client is not back yet, or the pane moved
            // to another chat): say so on the card. Settling as sent left a Retry that did nothing
            // (cmux#34369).
            if (!client || !reaches()) return Promise.resolve("retry.failed" as const);
            // The footer's Retry sends the turn's prompt again (acpmux rebuilds it): held as a send is.
            if (prompt && holdsRetry?.(prompt)) return Promise.resolve("retry.failed" as const);
            return retryFailedPrompt({
              sessionId: owner,
              rowId,
              prompt,
              client,
              currentClient: () => directClient.current,
              owns: reaches,
              capabilities: client.capabilities,
              request: (method, params) => client.retry(method, params),
              restore: (rowId, prompt) => client.resendPrompt(rowId, prompt),
              send: (draft) =>
                sendUntilTaken((taken) =>
                  callNative("chat.send", { text: draft.input, attachments: draft.attachments, taken }),
                ),
            });
          })(restartChat),
        }),
      }))(async (rowId: string, prompt: string) => {
        const draft = await directClient.current?.resendPrompt(rowId, prompt);
        // Settled once acpmux took it, not when its turn ends (turnRetry.ts `sendUntilTaken`).
        return sendUntilTaken((taken) =>
          callNative("chat.send", {
            text: draft?.input ?? prompt,
            attachments: draft?.attachments ?? [],
            taken,
          }),
        );
      })),

    // Continue after a stop (Codex's) sends its prompt as the composer would: it shows as the
    // reader's prompt and starts the next turn, or queues behind one already sent. Like Restart
    // (restart.ts), never to a View Only chat, a subagent's read-only pane or where the composer
    // cannot send, and only to the chat this pane still shows, never the next during a switch's hold.
    // A prompt that runs next anyway (a queued one no Stop or owner holds, such as a message acpmux
    // queued again after the Stop) starts the next turn: no Continue beside it.
    ...(restartChat &&
      !queueRunsNext && {
        resume: (
          (owner: string) => () =>
            restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession)
              ? resumeThrough(callNative)()
              : Promise.resolve()
        )(restartChat),
      }),
    // A tagged ask's answer (NextStepCard.tsx) sends as Continue does, with the same reach.
    ...(restartChat && {
      nextStepKey,
      ...(asker && { asker }),
      // A pane that moved to another chat since sends nothing there, and says so on the card.
      answer: (
        (owner: string) => (text: string) =>
          restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession)
            ? answerThrough(callNative)(text)
            : Promise.reject(new Error(CHAT_CHANGED))
      )(restartChat),
    }),
    // A context-full failure's Compact sends the agent's own /compact as Continue sends its prompt,
    // with the same reach: never to a View Only chat or a read-only pane, never the next chat.
    ...(restartChat &&
      offersCompact(snapshot.commands) && {
        compact: (
          (owner: string) => () =>
            restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession)
              ? compactThrough(callNative)()
              : Promise.resolve()
        )(restartChat),
      }),
    // Restart sends a prompt as the composer would (restart.ts `restartOwner`, `restartReaches`):
    // never to a View Only chat, from a subagent's read-only pane or where the composer cannot send,
    // and only to the chat whose row was clicked, never to the next chat during a switch's hold.
    ...(restartChat && {
      restartSubagent: ((owner: string) => (agent: Subagent) => {
        if (!restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession)) return;
        const text = restartPrompt(agent, translate);
        if (text) void callNative("chat.send", { text }).catch(() => undefined);
      })(restartChat),
      // Retry asks acpmux, the only one that retries (subagents/retryState.ts); it reads acpmux's
      // capabilities, `retryCapabilities`, set with Resume below.
      // One it can't reach (a reconnect, a switch's hold) is refused with a note, never taken as sent.
      retryAgent: ((owner: string) => (agent: RetryTarget) => {
        const client = directClient.current;
        const reaches = () => restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession);
        if (!client) return Promise.resolve("retry.failed" as const);
        const request = (method: string, params: Record<string, unknown>) => client.retry(method, params);
        return runRetry(agent, owner, { request, capabilities: client.capabilities, reaches });
      })(restartChat),
    }),
    // Resume asks acpmux to start a stopped subagent again from its transcript (resumeState.ts).
    // It sends no prompt through the composer, so the helper's own read-only pane offers it too,
    // on its tab (Leo, 2026-11-12: "A Resume button in cmux on a stopped helper's row and tab"):
    // owned by the chat that pane's composer relays to.
    ...(subagentRelayChat && {
      retryCapabilities: directClient.current?.capabilities,
      resumeAgent: ((owner: string) => (agent: Subagent) => {
        const client = directClient.current;
        const reaches = () => restartReaches(owner, sessionIdRef.current, directClient.current?.selectedSession);
        if (!client) return Promise.resolve("retry.failed" as const);
        const request = (method: string, params: Record<string, unknown>) => client.retry(method, params);
        return runSubagentResume(agent, owner, { request, capabilities: client.capabilities, reaches });
      })(subagentRelayChat),
    }),
    ...(connected &&
      retryModels.length > 1 && {
        retryWith: {
          models: retryModels,
          current: snapshot.summary?.model,
          ...(retryHarnessName ? { harness: retryHarnessName } : {}),
          ...(retryTop ? { top: retryTop } : {}),
          retry: (rowId: string, prompt: string, model: string) =>
            void callNative("chat.retryWith", { rowId, prompt, model }).catch(() => undefined),
        },
      }),
    // The X beside a steer the agent has not read: it comes back into the composer to edit. Only
    // Claude Code's adapter takes one back (acpmux `_acpmux/steer_withdraw`), under any family.
    ...(takesSteersBack({ backgroundsWork: snapshot.summary?.backgroundsWork }, connected) && {
      unsteer: (row: AcpmuxRow) =>
        takeBackSteer(row, {
          withdraw: (promptId) => editQueued(promptId, { op: "withdraw" }),
          attachments: (rowId) => directClient.current?.promptAttachments(rowId) ?? Promise.resolve([]),
          draft: (rowId, text) =>
            directClient.current?.resendPrompt(rowId, text) ?? Promise.reject(new Error(translate("error.notOpen"))),
          restore: (text, attachments) => composerHandle.current?.restore(text, attachments),
        }),
    }),
    // Sign in again runs the login in a terminal only where the card can't: a chat on this Mac, or
    // on a machine whose acpmux has no `agent_login`.
    ...(connected &&
      loginCommand &&
      !cloudMachineID &&
      !chatSignIns.cloudSignIn &&
      snapshot.summary?.hostKind !== "cloud" && {
        reauthenticate: () =>
          void callNative("tab.open", {
            kind: "terminal",
            text: loginCommand,
            ...(snapshot.summary?.cwd ? { cwd: snapshot.summary.cwd } : {}),
            run: true,
          }).catch(() => undefined),
      }),
    cloudSignIn: chatSignIns.cloudSignIn,
    apiKeySignIn: chatSignIns.apiKeySignIn,
    review: hunkReview,
    route: {
      harness: snapshot.summary?.harness,
      name: catalog.find((entry) => entry.id === (snapshot.summary?.harness ?? ""))?.name,
      hostKind: cloudRouteHostKind,
      ...(cloudMachineID && cloudTeamMachine && { teamMachine: true }),
    },
    switchModel: () => void openPicker(translate(PICKER_LABELS.model)),
    // A failure's cmux CodeRouter action: only this Mac's acpmux lists and binds a chat's routes.
    ...(chatAccounts && snapshot.sessionId ? { ownRoute: ownRouteOf(chatAccounts, snapshot.sessionId) } : {}),
    access,
  };
}
