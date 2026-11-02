// Turn rows for the pane's transcript: the "Worked for" disclosure, tool rows and the
// footer under an answer. Markup and metrics from reference prototype (messages.tsx,
// TurnMessage.tsx); each component takes the pane's row and draws one transcript entry.
import { FindReveal, isRevealRow } from "./chatFind";
import { useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { AcpmuxRow } from "../model";
import { copyTextResult } from "./clipboard";
import { MessageCard } from "./MessageCard";
import { DispatchCard } from "./DispatchCard";
import { McpCallRows } from "./McpCallRows";
import { SubsessionCallCard } from "./SubsessionCallCard";
import { AcpmuxSendLine, sendKey } from "./SentMessageLine";
import { mcpNames, McpNamesContext } from "./mcpCalls";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRow } from "./ToolRow";
import { ToolRun } from "./ToolRun";
import { ThoughtRow } from "./ThoughtRow";
import { groupId, runStretches, toolGroups, type ToolGroup } from "./toolGroups";
import type { RetryNote } from "../subagents/retryState";
import { TurnActionsContext } from "./turnActions";
import { errorRecovery, signInRetry, type ErrorRecovery } from "./errorRecovery";
import { footerLabel, isEmptyFooter, workedLabel } from "./turns";
import { turnCopyText } from "./turnCopy";
import { hasTokens, TimedLabel, tokensText, TurnTokens } from "./TurnTokens";
import { AlertCircle, ArrowRight, ChevronRight, Retry } from "./icons";
import {
  ForkButton,
  forkWithFeedback,
  MessageCopy,
  MessageFooterRow,
  MessageMore,
  PinButton,
  ReadAloudButton,
  ReplyTime,
  ROW_ICON,
} from "./MessageActions";
import { RetryModelMenu } from "./RetryModelMenu";
import { CloudSignIn } from "./CloudSignIn";
import type { CloudSignIn as CloudSignInActions } from "../cloudAgentLogin";
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
import { CodeRouterAction, useCodeRouterChoice } from "./CodeRouterOffer";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";
import { PresentationContext } from "./PresentationContext";

/// Where a folded run splits (toolGroups.ts), which the row estimate (model.ts) reads too.
export { runStretches, type RunStretch } from "./toolGroups";

/// "Worked for 15s" with its time in the line's quieter color (workedLabel's words otherwise).
function WorkedLabel({ row }: { row: AcpmuxRow }) {
  const t = useT();
  if (row.previous !== undefined || row.durationMs === undefined) return workedLabel(t, row);
  const key = row.status === "cancelled" ? "turn.stopped" : "turn.worked";
  return <TimedLabel text={(time) => t(key, { time })} time={row.durationMs} />;
}

/// The "Worked for 15s" line; it opens the turn's commentary and tool calls.
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
      {hasTokens(row.tokens) && (
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <TurnTokens split={row.tokens} />
        </span>
      )}
      <ChevronRight
        size={14}
        strokeWidth={1.2}
        className={`cv-worked__chevron cv-rotor${expanded ? " is-open" : ""}`}
      />
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
): ReactNode {
  switch (group.type) {
    case "group":
      return (
        <ToolGroupRow
          key={groupId(group.items) || index}
          kind={group.kind}
          items={group.items}
          folded={folded}
          disclosureKey={`group:${group.kind}:${groupId(group.items) || `${rowId}:${index}`}`}
          thoughtId={(n) => `${rowId}:thought:${thoughts + n}`}
        />
      );
    case "mcp":
      return (
        <McpCallRows
          key={group.items[0]!.tool!.id || index}
          items={group.items}
          disclosureKey={`group:mcp:${group.items[0]!.tool!.id || `${rowId}:${index}`}`}
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
    case "send":
      return (
        <AcpmuxSendLine
          key={sendKey(group.item.tool!.id, group.send.index) || index}
          tool={group.item.tool!}
          send={group.send}
        />
      );
    case "subsession":
      return <SubsessionCallCard key={group.item.tool!.id || index} call={group.call} tool={group.item.tool!} />;
    case "subsessionGroup":
      return (
        <SubsessionCallCard
          key={group.items[0]!.tool!.id || index}
          group={group.calls.map((call, i) => ({ call, tool: group.items[i]!.tool! }))}
        />
      );
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

/// A run of tool calls and thoughts between two pieces of text, in groups (toolGroups.ts). The
/// Codex-style runs (Debug toggle `agentPane.debug.codexToolRuns`, on by default) fold a finished
/// run (`foldRun`) of two or more entries under one summary line (toolRunSummary.ts: "Read 6 files,
/// ran 4 commands"), and a run that is one group under that group's closed line ("Ran 3 commands"),
/// so finished work is one click away between the paragraphs; coordination cards stay in sight
/// between such lines (`runStretches`). Off, each group and call keeps its own line.
/// Whether the whole run folds under one summary line.
export function shouldFoldToolRun(row: AcpmuxRow, groups: readonly ToolGroup[]): boolean {
  const stretches = runStretches(row, groups);
  return stretches.length === 1 && stretches[0]!.fold;
}

/// How many thoughts come before each entry of a run. A thought keeps its number as calls arrive
/// (a run only grows at its end, and grouping keeps the order), so its open state stays with it when
/// a call that finished joins it to a group (Codex review of #24075).
export function thoughtIds(groups: readonly ToolGroup[]): number[] {
  let thoughts = 0;
  return groups.map((group) => {
    const before = thoughts;
    const items = "items" in group ? group.items : [group.item];
    thoughts += items.filter((item) => !item.tool && item.kind !== "note").length;
    return before;
  });
}

export function ToolRows({ row, sessionId }: { row: AcpmuxRow; sessionId?: string }) {
  const items = row.items;
  const groups = useMemo(() => toolGroups(items ?? []), [items]);
  const stretches = useMemo(() => runStretches(row, groups), [row, groups]);
  const thoughts = useMemo(() => thoughtIds(groups), [groups]);
  const nodes = stretches.map((stretch) => {
    const drawn = stretch.groups.map((group, offset) => {
      const at = stretch.from + offset;
      return groupNode(
        group,
        at,
        row.id,
        row.at,
        row.live === true && at === groups.length - 1,
        row.foldRun === true && !stretch.fold,
        thoughts[at],
      );
    });
    if (!stretch.fold) return drawn;
    // The first stretch keeps the run's own key, so a run that grew a card keeps its open state.
    const first = stretch.items.find((item) => item.tool)?.tool?.id;
    const key = stretch.from === 0 ? `run:${row.id}` : `run:${row.id}:${first || stretch.from}`;
    return (
      <ToolRun key={key} disclosureKey={key} items={stretch.items}>
        {drawn}
      </ToolRun>
    );
  });
  // Find opens what holds its current match in this row only (chatFind.ts).
  const reveal = useContext(FindReveal);
  // Ids an MCP call names, to the titles the run's other calls give them ("Read Coordination hub").
  const names = useMemo(() => mcpNames(items), [items]);
  return (
    <TranscriptDisclosureProvider sessionId={sessionId}>
      <McpNamesContext.Provider value={names}>
        <FindReveal.Provider value={reveal && isRevealRow(row, reveal) ? reveal : undefined}>
          {/* No verb column: each row reads icon, verb, then its subject one space after, as Claude Code
              lists them (Leo, 2026-10-31: "why are these indented for no reason"). */}
          <div className="cv-tools">{nodes}</div>
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
/// row. Retry is the prompt's (UserBubble.tsx), and also here when the turn failed, whose row always
/// shows; so does the footer that ends the chat (#31503), so a finished reply's Copy is in sight.
export function TurnFooter({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const language = usePaneLanguage();
  const messages = useContext(PresentationContext) === "messages";
  const {
    fork,
    forkSeq,
    forkAny,
    retry,
    retryFailed,
    retryWith,
    reauthenticate,
    transferCloudCredentials,
    cloudSignIn,
    resume,
    compact,
    route,
    switchModel,
  } = useContext(TurnActionsContext);
  const text = row.text;
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
  // The turn's time and tokens, for the time's tooltip: "Worked for 13s · ↓ 359 out ↑ 328.8K in".
  const detail =
    [label, hasTokens(row.tokens) ? tokensText(t, language, row.tokens) : undefined].filter(Boolean).join(" · ") ||
    undefined;
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
          setRetrying(true);
          setRetryNote(undefined);
          void retryFailed(row.retryRowId, prompt)
            .then(setRetryNote, () => setRetryNote("retry.failed"))
            .finally(() => setRetrying(false));
        }
      : retry && prompt && row.retryRowId
        ? () => retry(row.retryRowId!, prompt)
        : undefined;
  // The card's lead (errorRecovery.ts): Continue when the turn had done work, Retry when nothing
  // ran; it shares the footer Retry's one-at-a-time state and refusal note. A sign-in failure's comes
  // only after its Sign in again, so only the card offers it (signInRetry), never the native command.
  const goOnRecovery = failed ? errorRecovery(row, route, { resume, retry, retryFailed }) : undefined;
  const recovery = goOnRecovery ?? (failed ? signInRetry(row, route, { retryFailed, reauthenticate }) : undefined);
  const goOn =
    recovery &&
    (() => {
      if (retrying) return;
      setRetrying(true);
      setRetryNote(undefined);
      void recovery
        .run()
        .then(setRetryNote, () => setRetryNote("retry.failed"))
        .finally(() => setRetrying(false));
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
          retryRowId={row.retryRowId}
          prompt={prompt}
          retry={failedRetry}
          goOn={goOn}
          goOnLabel={recovery?.label}
          retrying={retrying}
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
            {failedRetry && (
              <button
                type="button"
                className="cv-iconbtn cv-iconbtn--compact"
                aria-label={t("turn.retry")}
                title={t("turn.retryLabel")}
                disabled={retrying}
                onClick={failedRetry}
              >
                <Retry size={ROW_ICON} />
              </button>
            )}
            {failed && retry && prompt && retryWith && retryWith.models.length > 1 && (
              <RetryModelMenu
                retryWith={retryWith}
                onPick={(model) => retryWith.retry(row.retryRowId ?? "", prompt, model)}
              />
            )}
            {!messages && fork && seq !== undefined && (forkAny || seq === forkSeq) && (
              <ForkButton throughSeq={seq} onFork={() => forkWithFeedback(seq, () => fork(seq))} />
            )}
            {!messages && <PinButton rowId={row.id} />}
            {!messages && text && <ReadAloudButton id={row.id} text={text} />}
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
          {!messages && <ReplyTime at={row.at} detail={detail} />}
        </MessageFooterRow>
      </div>
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
  retryRowId,
  prompt,
  retry,
  goOn,
  goOnLabel,
  retrying = false,
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
  /// The failed prompt's row and text, which the Cloud sign-in sends again once signed in.
  retryRowId?: string;
  prompt?: string;
  /// Sends the prompt again; CodeRouter's move runs it once the chat is on the new route.
  retry?: () => void;
  /// The way on (errorRecovery.ts): Continue or Retry, the card's lead and its Return.
  goOn?: () => void;
  /// What the lead says: Continue when the turn had done work, Retry when nothing ran.
  goOnLabel?: ErrorRecovery["label"];
  /// A Continue or Retry is in flight: its button waits.
  retrying?: boolean;
  /// Why acpmux refused the last Continue or Retry (turnRetry.ts), shown beside the actions.
  retryNote?: RetryNote;
}) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const [detailsOpen, setDetailsOpen] = useState(false);
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
  // Continue or Retry is the way out, or the second one after Switch model for a key or proxy
  // failure, or after Sign in again; never for trust (errorRecovery.ts).
  const offersRetry = goOn !== undefined && (recovery !== "sign-in" || signInFirst);
  // A chat that outgrew its context window fails the same way on Retry until it is compacted, so
  // Compact leads and Retry follows it; a harness without /compact keeps Retry alone.
  const compactFirst = recovery === "compact" && compact !== undefined;
  // The way out goes first and reads as the card's one filled button.
  // Sign in again leads whenever the chat has a login to run, with or without a Retry beside it.
  const switchFirst =
    offersSwitch && !signInFirst && !cloudSignInLeads && (recovery === "switch-model" || !offersRetry);
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
      <span className="cv-turn-error__actions">
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
          <CloudSignIn signIn={cloudSignIn} rowId={retryRowId} prompt={prompt} keyOnly={teamMachine} />
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
        {retryNote && <output className="cv-turn-error__note text-detail text-dim">{t(retryNote)}</output>}
        {message && (
          <details className="cv-turn-error__details" onToggle={(event) => setDetailsOpen(event.currentTarget.open)}>
            {/* The chat's chevron, as on Worked for, not the browser's triangle. */}
            <summary className="cv-turn-note__summary">
              {t("turn.failure.details")}
              <ChevronRight
                size={12}
                strokeWidth={1.2}
                aria-hidden="true"
                className={`cv-rotor${detailsOpen ? " is-open" : ""}`}
              />
            </summary>
            <span className="cv-turn-error__raw">
              <span className="block font-mono text-detail whitespace-pre-wrap text-dim select-text">{message}</span>
              <button
                type="button"
                className="cv-turn-auth-action"
                onClick={() =>
                  void copyTextResult(message).then(
                    (accepted) => setCopied(accepted),
                    () => setCopied(false),
                  )
                }
              >
                {copied ? t("turn.copied") : t("turn.failure.copyError")}
              </button>
            </span>
          </details>
        )}
      </span>
    </div>
  );
}
