// Turn rows for the pane's transcript: the "Worked for" disclosure, tool rows and the
// footer under an answer. Markup and metrics from reference prototype (messages.tsx,
// TurnMessage.tsx); each component takes the pane's row and draws one transcript entry.
import { FindReveal, isRevealRow } from "./chatFind";
import { useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { AcpmuxRow } from "../model";
import { ErrorDetails } from "./ErrorDetails";
import { MessageCard } from "./MessageCard";
import { DispatchCard } from "./DispatchCard";
import { WhoElseCard } from "./WhoElseCard";
import { McpCallRows } from "./McpCallRows";
import { SubsessionCallCard } from "./SubsessionCallCard";
import { AgentCallCard } from "./AgentCallCard";
import { AcpmuxSendLine, SentMessageGroup } from "./SentMessageLine";
import { sendKey } from "./sentMessageLineModel";
import { mcpNames, McpNamesContext } from "./mcpCalls";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRow } from "./ToolRow";
import { ToolRun } from "./ToolRun";
import { toolRunSummary } from "./toolRunSummary";
import { ToolRunSteps } from "./ToolRunSteps";
import { KeepOpenedLine } from "./KeepOpenedLine";
import { visibleToolItems } from "./mcpPresentation";
import { ThoughtRow } from "./ThoughtRow";
import { groupId, runStretches, stretchStart, toolGroups, type RunStretch, type ToolGroup } from "./toolGroups";
import type { RetryNote } from "../subagents/retryState";
import { RowReplyButton } from "./SelectionReply";
import { RetryTargetContext, TurnActionsContext } from "./turnActions";
import { errorRecovery, signInRetry, type ErrorRecovery } from "./errorRecovery";
import {
  footerLabel,
  isEmptyFooter,
  isStopped,
  NO_RETRY_TARGET,
  offersRetry,
  retryPlacement,
  workedCallsText,
  workedLabel,
  workedMessagesText,
} from "./turns";
import { stoppedTurnLook } from "./stoppedTurn.experiment";
import { turnCopyText } from "./turnCopy";
import { TimedLabel } from "./TurnTokens";
import { replyTimeDetail } from "./turnTokensModel";
import { AlertCircle, ArrowRight, ChevronRight, Retry } from "./icons";
import {
  ForkButton,
  MessageCopy,
  MessageFooterRow,
  MessageMore,
  PinButton,
  ReadAloudButton,
  ReplyTime,
} from "./MessageActions";
import { forkWithFeedback, ROW_ICON } from "./messageActionsModel";
import { RetryModelMenu } from "./RetryModelMenu";
import { CloudSignIn } from "./CloudSignIn";
import { offersGateway, type CloudSignIn as CloudSignInActions } from "../cloudAgentLogin";
import { usePaneLanguage, useT } from "../i18n";
import {
  failureCopy,
  failureKind,
  failureRecovery,
  isCloudRejectedCredential,
  isTeamMachineSignIn,
  type FailureRoute,
} from "../failureCopy";
import { experimentArm } from "../../../experiments/experiment";
import { turnErrorCard } from "./turnErrorCard.experiment";
import { codeRouterOffer } from "./codeRouterOffer.experiment";
import { CodeRouterAction } from "./CodeRouterOffer";
import { useCodeRouterChoice } from "./codeRouterOfferModel";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { PresentationContext } from "./presentationContextModel";
import { useTranscriptReadOnly } from "./readOnly";
import { useTurnWaterfall } from "./useTurnWaterfall";
import { groupDisclosureKey, runDisclosureKey, runShape, thoughtIds } from "./turnRowsModel";

/// "Worked for 15s" with its time in the line's quieter color (workedLabel's words otherwise).
function WorkedLabel({ row }: { row: AcpmuxRow }) {
  const t = useT();
  // The `header` arm of turnFoldSteered names the work the line holds after its time.
  const runs = row.workedRuns;
  const work = useMemo(() => (runs?.length ? toolRunSummary(t, runs) : undefined), [t, runs]);
  let label: ReactNode;
  if (row.previous !== undefined || row.durationMs === undefined) label = workedLabel(t, row);
  else {
    const key = row.status === "cancelled" ? "turn.stopped" : "turn.worked";
    // A line that names its runs' work leaves their count to it.
    const after = (work ? "" : workedCallsText(t, row)) + workedMessagesText(t, row);
    label = <TimedLabel text={(time) => t(key, { time }) + after} time={row.durationMs} />;
  }
  if (!work) return label;
  return (
    <>
      {label}
      <span className="cv-worked__work">{` · ${work}`}</span>
    </>
  );
}

/// The "Worked for 15s" line; it opens the turn's commentary and tool calls. It says the time alone,
/// as Codex does (Lucas, 2026-11-06): the turn's tokens stay on the running line (WorkingFor.tsx).
export function WorkedFor({
  row,
  expanded,
  controls,
  onToggle,
}: {
  row: AcpmuxRow;
  expanded: boolean;
  controls?: string;
  onToggle: () => void;
}) {
  return (
    <button
      type="button"
      className="cv-worked has-divider is-toggle"
      aria-expanded={expanded}
      aria-controls={expanded ? controls : undefined}
      onClick={onToggle}
    >
      <span className="cv-worked__label">
        <WorkedLabel row={row} />
      </span>
      <ChevronRight size={14} className={`cv-worked__chevron cv-rotor${expanded ? " is-open" : ""}`} />
    </button>
  );
}

/// One entry of a run: a group, a message or sub-session card, a lone call or a thought. `live`: the entry is the
/// last of the live turn's latest row, so a thought there may still stream. `folded`: the run is
/// finished and draws no summary line of its own, so a group starts closed. `thoughts`: how many
/// thoughts the row's earlier entries hold, so a thought is `${rowId}:thought:<n>` wherever it
/// draws, on its own or inside a group a later call joined it to.
function groupNode(
  group: ToolGroup,
  index: number,
  rowId: string,
  rowAt: number,
  live: boolean,
  folded = false,
  thoughts = 0,
  runLine?: readonly string[],
): ReactNode {
  switch (group.type) {
    case "group":
      return (
        <ToolGroupRow
          key={groupId(group.items) || index}
          kind={group.kind}
          items={group.items}
          folded={folded}
          disclosureKey={groupDisclosureKey(group, index, rowId)!}
          // An edits group keeps its own state: closed, each file's diff one click away, whatever the
          // run's line around it was (it draws inside the opened run's line as its own line too).
          inherits={group.kind === "edits" ? undefined : runLine}
          closedBy={group.kind === "edits" ? undefined : runLine}
          thoughtId={(n) => `${rowId}:thought:${thoughts + n}`}
        />
      );
    case "mcp":
      return (
        <McpCallRows
          key={group.items[0]!.tool!.id || index}
          items={group.items}
          disclosureKey={groupDisclosureKey(group, index, rowId)!}
        />
      );
    case "message":
      return (
        <MessageCard
          key={group.item.tool!.id || index}
          item={group.item}
          message={group.message}
          messageAt={group.item.tool!.startedAt ?? rowAt}
        />
      );
    case "dispatch":
      return <DispatchCard key={group.item.tool!.id || index} item={group.item} call={group.call} />;
    case "whoElse":
      return <WhoElseCard key={group.item.tool!.id || index} item={group.item} call={group.call} />;
    case "send":
      return (
        <AcpmuxSendLine
          key={sendKey(group.item.tool!.id, group.send.index) || index}
          tool={group.item.tool!}
          send={group.send}
        />
      );
    case "sendGroup": {
      const key = `sends:${group.entries[0]!.type === "send" ? sendKey(group.items[0]!.tool!.id, group.entries[0]!.send.index) : group.items[0]!.tool!.id}`;
      return (
        <SentMessageGroup key={key} entries={group.entries} disclosureKey={key}>
          {group.entries.map((entry, at) =>
            entry.type === "send" ? (
              <AcpmuxSendLine
                key={sendKey(entry.item.tool!.id, entry.send.index) || at}
                tool={entry.item.tool!}
                send={entry.send}
                grouped
              />
            ) : (
              groupNode(entry, at, rowId, rowAt, false)
            ),
          )}
        </SentMessageGroup>
      );
    }
    case "subsession":
      return <SubsessionCallCard key={group.item.tool!.id || index} call={group.call} tool={group.item.tool!} />;
    case "subsessionGroup":
      return (
        <SubsessionCallCard
          key={group.items[0]!.tool!.id || index}
          group={group.calls.map((call, i) => ({ call, tool: group.items[i]!.tool! }))}
        />
      );
    case "agentCall":
      return <AgentCallCard key={group.item.tool!.id || index} call={group.call} tool={group.item.tool!} />;
    case "item":
      // A short interim note folded into the run (turns.ts mergeShortNotes).
      if (group.item.kind === "note")
        return (
          <p key={index} className="cv-tool-note">
            {group.item.text}
          </p>
        );
      return group.item.tool ? (
        <ToolRow key={group.item.tool.id || index} item={group.item} />
      ) : (
        <ThoughtRow
          key={`${rowId}:thought:${thoughts}`}
          id={`${rowId}:thought:${thoughts}`}
          item={group.item}
          streaming={live}
        />
      );
  }
}

/// How a folded stretch's line follows the group lines it grew from and splits back into
/// (`useTranscriptDisclosure` links): any of them the reader opened opens it (`inherits`); its own
/// choice passes down to those they set, but never to an edits group, which keeps its own state as it
/// draws inside the opened line (`passesDown`); and closing every group that drew open while the turn
/// ran, one by one, closes it (`closedBy`).
function runLinks(stretch: RunStretch, rowId: string) {
  const inherits: string[] = [];
  const passesDown: string[] = [];
  const closedBy: string[] = [];
  stretch.groups.forEach((group, offset) => {
    const key = groupDisclosureKey(group, stretch.from + offset, rowId);
    if (!key) return;
    inherits.push(key);
    if (group.type === "group" && group.kind === "edits") return;
    passesDown.push(key);
    if (group.type === "group") closedBy.push(key);
  });
  return { inherits, passesDown, closedBy };
}

export function ToolRows({ row, sessionId }: { row: AcpmuxRow; sessionId?: string }) {
  const reveal = useContext(FindReveal);
  // Keep the original transcript for copy/export and reveal discovery calls when Find names them.
  const revealing = reveal && isRevealRow(row, reveal);
  const items = useMemo(() => visibleToolItems(row.items, Boolean(revealing)), [row.items, revealing]);
  const groups = useMemo(() => toolGroups(items ?? []), [items]);
  const foldRun = row.foldRun;
  const stretches = useMemo(() => runStretches({ foldRun }, groups), [foldRun, groups]);
  const thoughts = useMemo(() => thoughtIds(groups), [groups]);
  // The row's groups and runs, in a word: when a new call changes it, the line the reader opened is
  // kept where it is on screen (KeepOpenedLine.tsx).
  const shape = useMemo(() => runShape(stretches), [stretches]);
  const nodes = stretches.map((stretch) => {
    // A stretch's line and its groups' lines take each other's place as calls arrive (one group
    // grows into a run of two kinds; a run loses its line when a call in it runs again): each opens
    // where the reader opened the other, so a line the reader opened never closes on its own.
    const key = runDisclosureKey(stretch, row.id);
    // model.ts estimates the stretch from the same start (toolGroups.ts `stretchStart`).
    const start = stretchStart(row, stretch);
    const drawn =
      !stretch.fold &&
      stretch.groups.map((group, offset) => {
        const at = stretch.from + offset;
        return groupNode(
          group,
          at,
          row.id,
          row.at,
          row.live === true && at === groups.length - 1,
          // A run line open from the start (`runOpen`) opens the groups it holds too.
          start.groupsClosed,
          thoughts[at],
          [key],
        );
      });
    if (!stretch.fold) return drawn;
    const links = runLinks(stretch, row.id);
    // Its thoughts' ids, as ToolRunSteps numbers them from the row's earlier thoughts.
    const before = thoughts[stretch.from] ?? 0;
    const runThoughts = stretch.items
      .filter((item) => !item.tool && item.kind !== "note")
      .map((_, at) => `${row.id}:thought:${before + at}`);
    return (
      <ToolRun
        key={key}
        disclosureKey={key}
        inherits={links.inherits}
        passesDown={links.passesDown}
        closedBy={links.closedBy}
        thoughts={runThoughts}
        items={stretch.items}
        defaultOpen={start.lineOpen}
      >
        <ToolRunSteps items={stretch.items} rowId={row.id} thoughtsBefore={thoughts[stretch.from] ?? 0} />
      </ToolRun>
    );
  });
  // Find opens what holds its current match in this row only (chatFind.ts).
  // Ids an MCP call names, to the titles the run's other calls give them ("Read Coordination hub").
  const names = useMemo(() => mcpNames(items), [items]);
  // Leave no child in RowFrame: its empty-row rule removes padding as well as content height.
  if (row.items?.length && !items?.length) return null;
  return (
    <TranscriptDisclosureProvider sessionId={sessionId}>
      <McpNamesContext.Provider value={names}>
        <FindReveal.Provider value={reveal && isRevealRow(row, reveal) ? reveal : undefined}>
          {/* No verb column: each row reads icon, verb, then its subject one space after, as Claude Code
              lists them (Leo, 2026-10-31: "why are these indented for no reason"). */}
          <KeepOpenedLine shape={shape}>{nodes}</KeepOpenedLine>
        </FindReveal.Provider>
      </McpNamesContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

/// The quiet row under an answer, as ChatGPT's: its buttons first, the first glyph's ink on the
/// prose's left edge whatever the turn did (Copy, Fork from here when acpmux serves forks, Pin, Read
/// aloud, More), then Continue for a stopped last turn, then the answer's exact time, shown on hover.
/// Leo, 2026-11-02: "this should not be placed in front of the copy/whatever buttons. those buttons
/// should always just be there left aligned". A turn without a "Worked for" line (a Claude turn,
/// #30176; history paged in mid-turn) keeps its time and tokens in the time's tooltip, never in the
/// row. Retry, with its model switch, is the last turn's: after Copy on the chat's last footer, failed
/// or not, never under the prompt (Leo, 2026-11-04: "Today Retry is on your prompt bubble, and appears
/// on the reply only after a failure. Put it, with the model switch, in the last turn's footer."). A
/// failed turn's row always shows; so does the footer that ends the chat (#31503), so a finished
/// reply's Copy and Retry are in sight.
export function TurnFooter({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const language = usePaneLanguage();
  const messages = useContext(PresentationContext) === "messages";
  const readOnly = useTranscriptReadOnly();
  const {
    fork,
    forkSeq,
    forkAny,
    tryAnotherApproach,
    retry,
    retryFailed,
    retryWith,
    reauthenticate,
    transferCloudCredentials,
    cloudSignIn,
    apiKeySignIn,
    resume,
    compact,
    route,
    switchModel,
  } = useContext(TurnActionsContext);
  const text = row.text;
  // The turn's Timeline (TurnWaterfall.tsx): a clock button, closed until the reader opens it.
  const timeline = useTurnWaterfall(row);
  // Copy copies the whole turn, its replies and tool lines (turnCopy.ts), as Claude Code desktop's;
  // a turn of tool calls alone draws no Copy and no Read aloud.
  const turnCopy = row.turnCopy;
  const copy = useMemo(() => (turnCopy ? turnCopyText(t, turnCopy) : text), [t, turnCopy, text]);
  const prompt = row.prompt;
  const seq = row.seq;
  const failed = row.status === "failed" || row.status === "error";
  const kind = failed ? failureKind(row.error, route, row.errorCode) : undefined;
  // Only the CLI's own login (or an unexplained 401 on a direct route) asks to sign in (cx-w10a);
  // its Sign in again is on the card (TurnFailure), and a Cloud chat's credential transfer stays here.
  // A team Cloud machine refuses a personal login transfer: no Set up credentials, and no automatic one.
  const teamMachine = route?.hostKind === "cloud" && route.teamMachine === true;
  const authenticationFailed = (kind === "subscription-login" || kind === "auth") && !teamMachine;
  const label = footerLabel(t, row);
  // The turn's time and tokens, for the time's tooltip: "Worked for 13s", then one token count per
  // row (turnTokensModel.ts `replyTimeDetail`). A Stop acpmux had to force (the agent never answered it)
  // says so here only, never in the transcript's text (Leo, 2026-11-03: "idk if it should be showing
  // things like that").
  const forced = row.stopForced ? t("stop.forced") : undefined;
  const detail = replyTimeDetail(t, language, [label, forced], row.tokens);
  // A stopped turn says so in one muted word, whoever ended it (stoppedTurn.experiment.ts).
  const stoppedLook = isStopped(row) ? experimentArm(stoppedTurnLook) : "none";
  const stoppedWord = stoppedLook !== "none" && (
    <span className="cv-turn-stopped" title={forced ?? workedLabel(t, row)}>
      {t("turn.stoppedMark")}
    </span>
  );
  // The last turn, stopped and not yet followed by a prompt, offers Continue (Codex's): it sends the
  // continue prompt as the composer would, and the button goes once that prompt shows (turns.ts).
  const resumable = row.resumable === true && resume !== undefined;
  // One click sends one prompt: the button stays disabled while the send is in flight (its pending
  // prompt row takes the button away first). A chat without the action (View Only, disconnected)
  // draws no Continue, so its footer is empty or not as it would be without one.
  const [resuming, setResuming] = useState(false);
  // A failed turn's Retry (card and footer) asks acpmux's turn retry where the chat has one
  // (turnRetry.ts): one at a time, and a refusal leaves its note on the card.
  const [retrying, setRetrying] = useState(false);
  const [retryNote, setRetryNote] = useState<RetryNote>();
  // The card says Retrying… from the click until the retried attempt reaches the transcript and
  // changes this row (it stops offering Retry, or a new attempt draws below it), and only while this
  // row is still the version that was clicked (cmux#34369). Without it the card came back at once
  // looking untouched, and a retry that failed again as fast (a gateway outage) read as a click that
  // did nothing. The button waits only while the request is in flight (acpmux's answer, or a fallback
  // send until acpmux took it): a second click is acpmux's to refuse (Busy, try again shortly), so a
  // row that never changes cannot leave it stuck. Its label is the click's: the attempt can reach the
  // chat (and change what the row offers) before acpmux answers.
  const [retryAt, setRetryAt] = useState<number>();
  const [retryWent, setRetryWent] = useState(false);
  const [retryLabel, setRetryLabel] = useState<ErrorRecovery["label"]>("retry");
  const retryProgress = retryAt !== undefined && retryAt === row.version && (retrying || retryWent);
  const runRetry = (run: () => Promise<RetryNote | undefined>, label: ErrorRecovery["label"]) => {
    setRetryAt(row.version);
    setRetryWent(false);
    setRetryLabel(label);
    setRetrying(true);
    setRetryNote(undefined);
    void run()
      .then(
        (note) => {
          setRetryNote(note);
          setRetryWent(note === undefined);
        },
        () => setRetryNote("retry.failed"),
      )
      .finally(() => setRetrying(false));
  };
  const automaticRecoveryAttempted = useRef<string | undefined>(undefined);
  const automaticRecoveryRow =
    failed &&
    !teamMachine &&
    row.retryable === true &&
    row.retryRowId &&
    prompt &&
    isCloudRejectedCredential(row.error, route)
      ? row.retryRowId
      : undefined;
  useEffect(() => {
    if (
      !automaticRecoveryRow ||
      !transferCloudCredentials ||
      !prompt ||
      automaticRecoveryAttempted.current === automaticRecoveryRow
    )
      return;
    automaticRecoveryAttempted.current = automaticRecoveryRow;
    void transferCloudCredentials(automaticRecoveryRow, prompt, true).catch(() => undefined);
  }, [automaticRecoveryRow, prompt, transferCloudCredentials]);
  // acpmux's retry needs no prompt: an attempt it sent (a hidden prompt row) that failed again
  // still offers Retry. Without it, Retry sends the turn's prompt again, so it needs one.
  const failedRetry = !failed
    ? undefined
    : retryFailed && row.retryable
      ? () => {
          if (retrying) return;
          runRetry(() => retryFailed(row.retryRowId, prompt), row.continuable ? "continue" : "retry");
        }
      : retry && prompt && row.retryRowId
        ? () => {
            // A chat without acpmux's retry sends the prompt again; a send that did not go says so.
            if (retrying) return;
            const rowId = row.retryRowId!;
            runRetry(async () => ((await retry(rowId, prompt)) === false ? "retry.failed" : undefined), "retry");
          }
        : undefined;
  // The footer of the person's last prompt, when that turn ended well, sends it again as the
  // prompt's Retry did, where turns.ts retryPlacement puts the chat's one Retry on this footer.
  const retryTarget = useContext(RetryTargetContext);
  const footerTarget = retryTarget
    ? retryTarget.footerId === row.id
      ? retryTarget
      : NO_RETRY_TARGET
    : offersRetry(row) && !isEmptyFooter(row)
      ? { promptId: row.retryRowId, footerId: row.id }
      : NO_RETRY_TARGET;
  // An attachment-only prompt's `prompt` is empty (turns.ts offersRetry): its attachments go again.
  const lastRetry =
    !failed &&
    retryPlacement(footerTarget, { canRetry: Boolean(retry), readOnly, messages }) === "footer" &&
    retry &&
    prompt !== undefined &&
    row.retryRowId
      ? () => retry(row.retryRowId!, prompt)
      : undefined;
  const footerRetry = failedRetry ?? lastRetry;
  const retryTitle = row.changedFiles ? t("turn.retryChangedFiles") : t("turn.retryLabel");
  const retryModels =
    ((failed && prompt) || lastRetry) && retry && retryWith && retryWith.models.length > 1 ? retryWith : undefined;
  // The card's lead (errorRecovery.ts): Continue when the turn had done work, Retry when nothing
  // ran; it shares the footer Retry's one-at-a-time state and refusal note. A sign-in failure's comes
  // only after its Sign in again, so only the card offers it (signInRetry), never the native command.
  const goOnRecovery = failed ? errorRecovery(row, route, { resume, retry, retryFailed }) : undefined;
  const recovery = goOnRecovery ?? (failed ? signInRetry(row, route, { retryFailed, reauthenticate }) : undefined);
  const goOn =
    recovery &&
    (() => {
      if (retrying) return;
      runRetry(recovery.run, recovery.label);
    });
  // A failure reads as the turn's answer does: its own block above the footer row, never squeezed
  // into it (Codex, Claude desktop). The row is one quiet line under the answer's left edge; it
  // shows on hover or keyboard focus, and always for a failed turn (VirtualTranscript marks the
  // turn the reader points at, from its answer to its footer).
  return (
    <>
      {failed && (
        <TurnFailure
          message={row.error}
          code={row.errorCode}
          route={route}
          switchModel={switchModel}
          compact={compact}
          reauthenticate={reauthenticate}
          cloudSignIn={cloudSignIn}
          apiKeySignIn={apiKeySignIn}
          retryRowId={row.retryRowId}
          prompt={prompt}
          retry={failedRetry}
          goOn={goOn}
          goOnLabel={recovery?.label}
          retrying={retrying}
          retryProgress={retryProgress}
          retryLabel={retryLabel}
          failedAgain={row.failedAgain === true}
          retryNote={retryNote}
        />
      )}
      <div
        className={
          failed
            ? "cv-turn-actions cv-turn-actions--failed"
            : resumable
              ? "cv-turn-actions cv-turn-actions--resumable"
              : isEmptyFooter(row.resumable ? { ...row, resumable: undefined } : row)
                ? "cv-turn-actions cv-turn-actions--empty"
                : "cv-turn-actions"
        }
      >
        <MessageFooterRow className="cv-turn-footer-row">
          <span className="cv-turn-action-group">
            {!messages && copy && <MessageCopy text={copy} />}
            {(footerRetry || retryModels) && (
              // Retry and its model switch read as one split control: Retry's square, then a narrow
              // chevron tight against it (conversation.css .cv-turn-retry).
              <span className="cv-turn-retry">
                {footerRetry && (
                  <button
                    type="button"
                    className="cv-iconbtn cv-iconbtn--compact"
                    aria-label={t("turn.retry")}
                    title={retryTitle}
                    disabled={retrying}
                    onClick={footerRetry}
                  >
                    <Retry size={ROW_ICON} />
                  </button>
                )}
                {retryModels && prompt !== undefined && (
                  <RetryModelMenu
                    retryWith={retryModels}
                    onPick={(model) => retryModels.retry(row.retryRowId ?? "", prompt, model)}
                  />
                )}
              </span>
            )}
            {!messages && fork && seq !== undefined && (forkAny || seq === forkSeq) && (
              <ForkButton throughSeq={seq} onFork={() => forkWithFeedback(seq, () => fork(seq))} />
            )}
            {tryAnotherApproach && seq !== undefined && seq === forkSeq && (
              <TryAnotherApproachButton onTry={() => tryAnotherApproach(seq)} />
            )}
            {!messages && <PinButton rowId={row.id} />}
            {!messages && timeline.toggle}
            {!messages && text && <ReadAloudButton id={row.id} text={text} />}
            {!messages && text && <RowReplyButton text={text} />}
            {!messages && text && row.answerId && <MessageMore rowId={row.answerId} />}
            {authenticationFailed && transferCloudCredentials && row.retryRowId && prompt && (
              <button
                type="button"
                className="cv-turn-auth-action"
                onClick={() => {
                  void transferCloudCredentials(row.retryRowId!, prompt).catch(() => undefined);
                }}
              >
                {t("turn.transferCredentials", {
                  harness: route?.name || route?.harness || t("turn.failure.theAgent"),
                })}
              </button>
            )}
          </span>
          {stoppedLook === "word" && stoppedWord}
          {resumable && (
            <button
              type="button"
              className="cv-iconbtn cv-turn-continue"
              disabled={resuming}
              onClick={() => {
                setResuming(true);
                void resume().finally(() => setResuming(false));
              }}
            >
              {t("turn.continue")}
              <ArrowRight size={ROW_ICON} aria-hidden="true" />
            </button>
          )}
          {stoppedLook === "trailing" && stoppedWord}
          {!messages && <ReplyTime at={row.at} detail={detail} />}
        </MessageFooterRow>
      </div>
      {!messages && timeline.panel}
    </>
  );
}

/// A failed turn's card (cx-w10a; Leo 2026-10-22: "we need to have prettier errors"): the cause in
/// one human line, naming the harness and the proxy or endpoint when the error names one, never a
/// generic "sign-in expired" and never the agent's raw words; the way out first (Retry, or Switch
/// model for capacity, key and proxy failures; Sign in again for a sign-in failure, with Retry and
/// Switch model after it; Compact for a chat that outgrew its context window, with Retry after it); Details opens the agent's own message with Copy error. Its surface is the
/// `turn-error-card` experiment's arm (turnErrorCard.experiment.ts).
function TurnFailure({
  message,
  code,
  route,
  switchModel,
  compact,
  reauthenticate,
  cloudSignIn,
  apiKeySignIn,
  retryRowId,
  prompt,
  retry,
  goOn,
  goOnLabel,
  retrying = false,
  retryProgress = false,
  retryLabel = "retry",
  failedAgain = false,
  retryNote,
}: {
  message: string | undefined;
  code?: string;
  route?: FailureRoute;
  switchModel?: () => void;
  compact?: () => Promise<void>;
  /// Runs the chat harness's login (only the CLI's own login, or an unexplained 401 on a direct
  /// route, asks to sign in; cx-w10a).
  reauthenticate?: () => void;
  /// A Cloud chat's own sign-in on its machine (cloudAgentLogin.ts, CloudSignIn.tsx).
  cloudSignIn?: CloudSignInActions;
  /// A chat here whose built-in Claude Code or Codex is not signed in: Use an API key
  /// (cloudAgentLogin.ts `localApiKeyLogin`).
  apiKeySignIn?: CloudSignInActions;
  /// The failed prompt's row and text, which the Cloud sign-in sends again once signed in.
  retryRowId?: string;
  prompt?: string;
  /// Sends the prompt again; CodeRouter's move runs it once the chat is on the new route.
  retry?: () => void;
  /// The way on (errorRecovery.ts): Continue or Retry, the card's lead and its Return.
  goOn?: () => void;
  /// What the lead says: Continue when the turn had done work, Retry when nothing ran.
  goOnLabel?: ErrorRecovery["label"];
  /// A Continue or Retry is in flight: its button waits, and the note says Retrying….
  retrying?: boolean;
  /// The note says Retrying… (or Continuing…): from the click, while this row is still the version
  /// that was clicked and the retry is in flight or acpmux took it (cmux#34369).
  retryProgress?: boolean;
  /// What the click under way was: the note says Continuing… or Retrying….
  retryLabel?: ErrorRecovery["label"];
  /// This turn was a retry of a failed one and failed too (turns.ts `failedAgain`).
  failedAgain?: boolean;
  /// Why acpmux refused the last Continue or Retry (turnRetry.ts), shown beside the actions.
  retryNote?: RetryNote;
}) {
  const t = useT();
  const actionsRef = useRef<HTMLSpanElement>(null);
  const { access } = useContext(TurnActionsContext);
  // One click sends one /compact: the button stays disabled until that send settles.
  const [compacting, setCompacting] = useState(false);
  const kind = failureKind(message, route, code);
  const sentence = failureCopy(t, message, route, code);
  const arm = experimentArm(turnErrorCard);
  const recovery = failureRecovery(kind);
  // A sign-in failure offers it too: the picker moves the chat to a route that is signed in (cx-gz0dz).
  const offersSwitch =
    switchModel &&
    [
      "rate-limited",
      "unreachable",
      "invalid-key",
      "proxy-auth",
      "subscription-login",
      "auth",
      "needs-credits",
      "team-cap",
      "no-credit",
      "cloud-auth-expired",
    ].includes(kind);
  // The cmux model router refused the turn: no paid plan and no credits, or credits that do not cover
  // the call (accessOffer.ts; Leo 2026-10-26: "we offer them to add credits or add their own api key").
  // A paid plan lifts both, so Add Credits… leads as the card's one filled button.
  const accessOffer = kind === "needs-credits" ? access : undefined;
  const accessLeads = accessOffer !== undefined;
  const accessButtons = accessOffer && (
    <button type="button" className="cv-turn-auth-action cv-turn-error__primary" onClick={accessOffer.addCredits}>
      {t("access.addCredits")}
    </button>
  );
  // An expired login leads with Sign in again, and Continue or Retry follows it for once the login
  // is done. Where the chat has no login to run (a Cloud chat, a harness that names none), the card
  // is as it was: Switch model or CodeRouter, and no Retry, which would fail the same way.
  const signInFirst = recovery === "sign-in" && reauthenticate !== undefined;
  // A Cloud chat's agent signs in on its own machine (Leo 2026-11-01, on the one-click sign-in:
  // "yes those are important"): Sign in to Claude or Codex leads the card, Use an API key beside it,
  // and Switch model follows them outlined.
  // A team Cloud machine takes no personal login (isTeamMachineSignIn): Switch model leads, and the
  // card keeps only Use an API key of the sign-in, never Sign in to Claude, which would dead-end.
  const teamMachine = isTeamMachineSignIn(kind, route);
  const cloudSignInLeads = recovery === "sign-in" && cloudSignIn !== undefined && !signInFirst && !teamMachine;
  // A chat here whose built-in Claude Code or Codex is not signed in (Leo 2026-10-26: "if user picks a
  // model they don't have api key, we offer them to add credits or add their own api key"): Use an API
  // key follows Sign in again, outlined; the key goes where the agent's own CLI reads it.
  const localKey = recovery === "sign-in" && cloudSignIn === undefined ? apiKeySignIn : undefined;
  // Continue or Retry is the way out, or the second one after Switch model for a key or proxy
  // failure, or after Sign in again; never for trust (errorRecovery.ts).
  const offersRetry = goOn !== undefined && (recovery !== "sign-in" || signInFirst);
  // A chat that outgrew its context window fails the same way on Retry until it is compacted, so
  // Compact leads and Retry follows it; a harness without /compact keeps Retry alone.
  const compactFirst = recovery === "compact" && compact !== undefined;
  // The way out goes first and reads as the card's one filled button.
  // Sign in again leads whenever the chat has a login to run, with or without a Retry beside it.
  // A server or connection that could not be reached is not the model's fault (Leo 2026-11-03, on a
  // card that led with Switch model: "this ui is pretty awkward looking"): Retry leads it, the same
  // acpmux turn retry whose attempts the live line counts (Thinking.tsx, "Can't reach the model ·
  // retrying"), and Switch model only ever follows, outlined. Where the card has no Retry (an
  // earlier turn, or one a retry already went on from) it keeps Switch model outlined, never filled.
  const connectionFailure = kind === "unreachable";
  const switchFirst =
    offersSwitch &&
    !connectionFailure &&
    !signInFirst &&
    !cloudSignInLeads &&
    (recovery === "switch-model" || !offersRetry);
  // cmux's own route for a key, sign-in or capacity failure (CodeRouterOffer.tsx), placed by the
  // `coderouter-offer` arm. It takes the filled button only in the `primary` arm, or when it is the
  // only way out; the card keeps exactly one.
  const codeRouter = useCodeRouterChoice(kind, route, retry !== undefined);
  const offerArm = experimentArm(codeRouterOffer);
  // Never ahead of Sign in again: moving the chat (and retrying it there) before the person has signed
  // in is not the way out the card leads with; in that case it follows the others, outlined.
  const offerLeads = codeRouter !== undefined && offerArm === "primary" && !signInFirst && !cloudSignInLeads;
  const offerTrails =
    codeRouter !== undefined &&
    (offerArm === "button" || (offerArm === "primary" && (signInFirst || cloudSignInLeads)));
  // CodeRouter's button fills only when it is the card's only way out: not beside Switch model, Retry,
  // Sign in again or Compact, which each lead.
  const offerFilled =
    offerLeads ||
    (codeRouter !== undefined &&
      offerArm === "button" &&
      !offersSwitch &&
      !offersRetry &&
      !signInFirst &&
      !cloudSignInLeads &&
      !compactFirst);
  const switchButton = offersSwitch && (
    <button
      type="button"
      className={`cv-turn-auth-action${switchFirst && !offerLeads && !accessLeads ? " cv-turn-error__primary" : ""}`}
      onClick={switchModel}
    >
      {t("turn.failure.switchModel")}
    </button>
  );
  return (
    <div
      className={`cv-turn-note cv-turn-error cv-turn-error--${arm}${arm === "card" ? " ui-glass" : ""}`}
      data-failure-kind={kind}
    >
      <span className="cv-turn-error__cause">
        {arm !== "note" && <AlertCircle size={arm === "card" ? 16 : 14} className="cv-turn-error__icon" />}
        <span className="text-fg">
          {sentence}
          {codeRouter && offerArm === "link" && (
            <>
              {" "}
              <CodeRouterAction choice={codeRouter} retry={retry} className="cv-turn-error__offer-link" />
            </>
          )}
        </span>
      </span>
      <span className="cv-turn-error__actions" ref={actionsRef}>
        {accessButtons}
        {offerLeads && (
          <CodeRouterAction choice={codeRouter} retry={retry} className="cv-turn-auth-action cv-turn-error__primary" />
        )}
        {switchFirst && switchButton}
        {compactFirst && (
          <button
            type="button"
            className="cv-turn-auth-action cv-turn-error__primary"
            disabled={compacting}
            onClick={() => {
              setCompacting(true);
              void compact().finally(() => setCompacting(false));
            }}
          >
            {t("context.compact")}
          </button>
        )}
        {(cloudSignInLeads || (teamMachine && cloudSignIn)) && (
          <CloudSignIn
            signIn={cloudSignIn}
            rowId={retryRowId}
            prompt={prompt}
            keyOnly={teamMachine}
            gateway={offersGateway(message)}
            actionsRef={actionsRef}
          />
        )}
        {signInFirst && (
          <button
            type="button"
            className={`cv-turn-auth-action${offerLeads ? "" : " cv-turn-error__primary"}`}
            onClick={reauthenticate}
          >
            {t("turn.signInAgain")}
          </button>
        )}
        {localKey && (
          <CloudSignIn signIn={localKey} rowId={retryRowId} prompt={prompt} keyOnly actionsRef={actionsRef} />
        )}
        {offersRetry && (
          <button
            type="button"
            className={`cv-turn-auth-action${switchFirst || offerLeads || accessLeads || compactFirst || signInFirst ? "" : " cv-turn-error__primary"}`}
            // The card's first stop in the tab order, so Return on the focused card goes on.
            aria-keyshortcuts="Enter"
            disabled={retrying}
            onClick={goOn}
          >
            {goOnLabel === "continue" ? t("turn.continue") : t("turn.retry")}
          </button>
        )}
        {!switchFirst && switchButton}
        {offerTrails && (
          <CodeRouterAction
            choice={codeRouter}
            retry={retry}
            className={`cv-turn-auth-action${offerFilled ? " cv-turn-error__primary" : ""}`}
          />
        )}
        {retryNote ? (
          <output className="cv-turn-error__note text-detail text-dim">{t(retryNote)}</output>
        ) : retryProgress ? (
          // The click went (cmux#34369): said from the click until the retried attempt shows.
          <output className="cv-turn-error__note text-detail text-dim">
            {t(retryLabel === "continue" ? "turn.continuing" : "turn.retrying")}
          </output>
        ) : (
          // A retried attempt that failed too says so, so the new card is not read as the old one.
          failedAgain && <output className="cv-turn-error__note text-detail text-dim">{t("turn.failedAgain")}</output>
        )}
        {message && <ErrorDetails text={message} />}
      </span>
    </div>
  );
}

/// Cloud's Try another approach, labelled. A machine snapshot takes a while, so the button says it
/// is working; a refused click or a Cloud error says the fork failed (the Fork button's copy) and a
/// second click tries again.
function TryAnotherApproachButton({ onTry }: { onTry(): Promise<unknown> }) {
  const t = useT();
  const [state, setState] = useState<"idle" | "pending" | "failed">("idle");
  const label =
    state === "pending"
      ? `${t("turn.tryAnotherApproach")}…`
      : state === "failed"
        ? t("notice.forkFailed")
        : t("turn.tryAnotherApproach");
  return (
    <button
      type="button"
      className="cv-iconbtn cv-iconbtn--compact cv-turn-try-another"
      aria-label={label}
      title={label}
      aria-busy={state === "pending"}
      data-try-state={state}
      disabled={state === "pending"}
      onClick={() => {
        setState("pending");
        onTry().then(
          () => setState("idle"),
          () => setState("failed"),
        );
      }}
    >
      {state === "failed" && <AlertCircle size={ROW_ICON} />}
      {label}
    </button>
  );
}
