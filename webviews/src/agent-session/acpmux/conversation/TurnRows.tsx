// Turn rows for the pane's transcript: the "Worked for" disclosure, tool rows and the
// footer under an answer. Markup and metrics from reference prototype (messages.tsx,
// TurnMessage.tsx); each component takes the pane's row and draws one transcript entry.
import { FindReveal, isRevealRow } from "./chatFind";
import { useContext, useMemo, useState, type ReactNode } from "react";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { copyText } from "./clipboard";
import { MessageCard } from "./MessageCard";
import { DispatchCard } from "./DispatchCard";
import { McpCallRows } from "./McpCallRows";
import { SubsessionCallCard } from "./SubsessionCallCard";
import { AcpmuxSendLine } from "./SentMessageLine";
import { mcpNames, McpNamesContext } from "./mcpCalls";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRow } from "./ToolRow";
import { ToolRun } from "./ToolRun";
import { ThoughtRow } from "./ThoughtRow";
import { awaitsPermission, toolGroups, type ToolGroup } from "./toolGroups";
import { isFoldedRun } from "./toolRunSummary";
import { TurnActionsContext } from "./turnActions";
import { footerLabel, isEmptyFooter, workedLabel } from "./turns";
import { hasTokens, TimedLabel, TurnTokens } from "./TurnTokens";
import { AlertCircle, ArrowRight, ChevronRight, Retry } from "./icons";
import {
  ForkButton,
  forkWithFeedback,
  MessageCopy,
  MessageMore,
  MessageTime,
  PinButton,
  ReadAloudButton,
  ROW_ICON,
} from "./MessageActions";
import { RetryModelMenu } from "./RetryModelMenu";
import { useT } from "../i18n";
import { failureCopy, failureKind, failureRecovery, type FailureRoute } from "../failureCopy";
import { experimentArm } from "../../../experiments/experiment";
import { turnErrorCard } from "./turnErrorCard.experiment";
import { codeRouterOffer } from "./codeRouterOffer.experiment";
import { CodeRouterAction, useCodeRouterChoice } from "./CodeRouterOffer";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";

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
          key={group.items[0]!.tool!.id || index}
          kind={group.kind}
          items={group.items}
          folded={folded}
          disclosureKey={`group:${group.kind}:${group.items[0]!.tool!.id || `${rowId}:${index}`}`}
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
      return <AcpmuxSendLine key={group.item.tool!.id || index} tool={group.item.tool!} send={group.send} />;
    case "subsession":
      return <SubsessionCallCard key={group.item.tool!.id || index} call={group.call} tool={group.item.tool!} />;
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

/// A folded run's entries in stretches: a coordination card (a message, a sub-session started,
/// messaged or waited on) stays in sight, its own stretch, and the work between cards folds under
/// its own summary line ("Edited a file, read 6 files, ran 4 commands") once it holds two calls in
/// more than one entry, so one card never leaves the whole run spread out as a list
/// (Leo 2026-10-21: "it can consolidate a ton of these tool calls"). A run that is not folded
/// (`foldRun`, the Codex-style runs) is one stretch that folds nothing.
export type RunStretch = { from: number; groups: ToolGroup[]; items: AcpmuxActivity[]; fold: boolean };

export function runStretches(row: AcpmuxRow, groups: readonly ToolGroup[]): RunStretch[] {
  const stretches: RunStretch[] = [];
  let current: RunStretch | undefined;
  const close = () => {
    if (current) current.fold = current.groups.length > 1 && isFoldedRun(current.items);
    current = undefined;
  };
  groups.forEach((group, at) => {
    const items = "items" in group ? group.items : [group.item];
    if (row.foldRun === true && staysInSight(group)) {
      close();
      stretches.push({ from: at, groups: [group], items, fold: false });
      return;
    }
    if (!current) stretches.push((current = { from: at, groups: [], items: [], fold: false }));
    current.groups.push(group);
    current.items.push(...items);
  });
  close();
  if (row.foldRun !== true) for (const stretch of stretches) stretch.fold = false;
  return stretches;
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

/// An entry a folded run keeps in sight beside its summary lines: a coordination card, or a file
/// change still waiting for its permission (toolGroups.ts `awaitsPermission`). Other edits fold with
/// the rest of the work and the line names them (Leo 2026-10-22: "this is pretty good ui: … the
/// collapsing i mean"); the turn's edited-files card lists them once it ends.
function staysInSight(group: ToolGroup): boolean {
  if (group.type === "message" || group.type === "send" || group.type === "subsession" || group.type === "dispatch")
    return true;
  // A pending change draws as its own item (toolGroups.ts `toolGroupKind`); any entry holding one
  // stays in sight all the same.
  return ("items" in group ? group.items : [group.item]).some((item) => awaitsPermission(item.tool));
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
          <div className="cv-tools">{nodes}</div>
        </FindReveal.Provider>
      </McpNamesContext.Provider>
    </TranscriptDisclosureProvider>
  );
}

/// The quiet row under an answer, as Claude Code desktop's: Copy, Fork from here (when acpmux
/// serves forks), Pin, Read aloud, then the answer's age, and why the turn ended when it did not
/// complete. Retry is the prompt's (UserBubble.tsx), and also here when the turn failed, whose row
/// always shows. A turn without a "Worked for" line (history paged in mid-turn) says its time and
/// count here first.
export function TurnFooter({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const {
    fork,
    forkSeq,
    forkAny,
    retry,
    retryWith,
    reauthenticate,
    transferCloudCredentials,
    resume,
    route,
    switchModel,
  } = useContext(TurnActionsContext);
  const text = row.text;
  const prompt = row.prompt;
  const seq = row.seq;
  const failed = row.status === "failed" || row.status === "error";
  const kind = failed ? failureKind(row.error, route, row.errorCode) : undefined;
  // Only the CLI's own login (or an unexplained 401 on a direct route) asks to sign in (cx-w10a).
  const authenticationFailed = kind === "subscription-login" || kind === "auth";
  const label = footerLabel(t, row);
  // The last turn, stopped and not yet followed by a prompt, offers Continue (Codex's): it sends the
  // continue prompt as the composer would, and the button goes once that prompt shows (turns.ts).
  const resumable = row.resumable === true && resume !== undefined;
  // One click sends one prompt: the button stays disabled while the send is in flight (its pending
  // prompt row takes the button away first). A chat without the action (View Only, disconnected)
  // draws no Continue, so its footer is empty or not as it would be without one.
  const [resuming, setResuming] = useState(false);
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
          retry={retry && prompt && row.retryRowId ? () => retry(row.retryRowId!, prompt) : undefined}
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
        {label && (
          <span className="cv-turn-summary">
            {label}
            {hasTokens(row.tokens) && (
              <>
                <span className="cv-worked__sep" aria-hidden="true">
                  {" · "}
                </span>
                <TurnTokens split={row.tokens} />
              </>
            )}
          </span>
        )}
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
        <span className="cv-turn-action-group">
          {text && <MessageCopy text={text} />}
          {failed && retry && prompt && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("turn.retry")}
              title={t("turn.retryLabel")}
              onClick={() => retry(row.retryRowId ?? "", prompt)}
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
          {fork && seq !== undefined && (forkAny || seq === forkSeq) && (
            <ForkButton onFork={() => forkWithFeedback(seq, () => fork(seq))} />
          )}
          <PinButton rowId={row.id} />
          {text && <ReadAloudButton id={row.id} text={text} />}
          {text && row.answerId && <MessageMore rowId={row.answerId} />}
          {authenticationFailed && reauthenticate && (
            <button type="button" className="cv-turn-auth-action" onClick={reauthenticate}>
              {t("turn.signInAgain")}
            </button>
          )}
          {authenticationFailed && transferCloudCredentials && row.retryRowId && prompt && (
            <button
              type="button"
              className="cv-turn-auth-action"
              onClick={() => {
                void transferCloudCredentials(row.retryRowId!, prompt).catch(() => undefined);
              }}
            >
              {t("turn.transferCredentials", { harness: route?.name || route?.harness || t("turn.failure.theAgent") })}
            </button>
          )}
        </span>
        <MessageTime at={row.at} className="cv-turn-time" />
      </div>
    </>
  );
}

/// A failed turn's card (cx-w10a; Leo 2026-10-22: "we need to have prettier errors"): the cause in
/// one human line, naming the harness and the proxy or endpoint when the error names one, never a
/// generic "sign-in expired" and never the agent's raw words; the way out first (Retry, or Switch
/// model for capacity, key and proxy failures, and for sign-in ones beside the footer's Sign in
/// again); Details opens the agent's own message with Copy error. Its surface is the
/// `turn-error-card` experiment's arm (turnErrorCard.experiment.ts).
function TurnFailure({
  message,
  code,
  route,
  switchModel,
  retry,
}: {
  message: string | undefined;
  code?: string;
  route?: FailureRoute;
  switchModel?: () => void;
  retry?: () => void;
}) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const kind = failureKind(message, route, code);
  const sentence = failureCopy(t, message, route, code);
  const arm = experimentArm(turnErrorCard);
  const recovery = failureRecovery(kind);
  // A sign-in failure offers it too: the picker moves the chat to a route that is signed in (cx-gz0dz).
  const offersSwitch =
    switchModel &&
    ["rate-limited", "unreachable", "invalid-key", "proxy-auth", "subscription-login", "auth"].includes(kind);
  // Retry is the way out, or the second one after Switch model; never for a sign-in or trust failure.
  const offersRetry = recovery !== undefined && retry !== undefined;
  // The way out goes first and reads as the card's one filled button.
  const switchFirst = offersSwitch && (recovery === "switch-model" || !offersRetry);
  // cmux's own route for a key, sign-in or capacity failure (CodeRouterOffer.tsx), placed by the
  // `coderouter-offer` arm. It takes the filled button only in the `primary` arm, or when it is the
  // only way out; the card keeps exactly one.
  const codeRouter = useCodeRouterChoice(kind, route, retry !== undefined);
  const offerArm = experimentArm(codeRouterOffer);
  const offerLeads = codeRouter !== undefined && offerArm === "primary";
  const offerFilled =
    offerLeads || (codeRouter !== undefined && offerArm === "button" && !offersSwitch && !offersRetry);
  const switchButton = offersSwitch && (
    <button
      type="button"
      className={`cv-turn-auth-action${switchFirst && !offerLeads ? " cv-turn-error__primary" : ""}`}
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
        {arm !== "note" && <AlertCircle size={14} className="cv-turn-error__icon" />}
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
        {offerLeads && (
          <CodeRouterAction choice={codeRouter} retry={retry} className="cv-turn-auth-action cv-turn-error__primary" />
        )}
        {switchFirst && switchButton}
        {offersRetry && (
          <button
            type="button"
            className={`cv-turn-auth-action${switchFirst || offerLeads ? "" : " cv-turn-error__primary"}`}
            onClick={retry}
          >
            {t("turn.retry")}
          </button>
        )}
        {!switchFirst && switchButton}
        {codeRouter && offerArm === "button" && (
          <CodeRouterAction
            choice={codeRouter}
            retry={retry}
            className={`cv-turn-auth-action${offerFilled ? " cv-turn-error__primary" : ""}`}
          />
        )}
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
                  void copyText(message).then(
                    () => setCopied(true),
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
