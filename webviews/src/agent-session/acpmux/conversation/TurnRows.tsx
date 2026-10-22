// Turn rows for the pane's transcript: the "Worked for" disclosure, tool rows and the
// footer under an answer. Markup and metrics from reference prototype (messages.tsx,
// TurnMessage.tsx); each component takes the pane's row and draws one transcript entry.
import { FindReveal, isRevealRow } from "./chatFind";
import { useContext, useMemo, useState, type ReactNode } from "react";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { copyText } from "./clipboard";
import { MessageCard } from "./MessageCard";
import { McpCallRows } from "./McpCallRows";
import { SubsessionCallCard } from "./SubsessionCallCard";
import { mcpNames, McpNamesContext } from "./mcpCalls";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRow } from "./ToolRow";
import { ToolRun } from "./ToolRun";
import { ThoughtRow } from "./ThoughtRow";
import { toolGroups, type ToolGroup } from "./toolGroups";
import { isFoldedRun } from "./toolRunSummary";
import { TurnActionsContext } from "./turnActions";
import { workedLabel } from "./turns";
import { ChevronRight, Retry } from "./icons";
import { ForkButton, MessageCopy, MessageTime, PinButton, ReadAloudButton } from "./MessageActions";
import { RetryModelMenu } from "./RetryModelMenu";
import { useT } from "../i18n";
import { failureCopy, failureKind, type FailureRoute } from "../failureCopy";
import { TranscriptDisclosureProvider } from "./transcriptDisclosure";

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
  const t = useT();
  return (
    <button
      type="button"
      className="cv-worked has-divider is-toggle"
      aria-expanded={expanded}
      aria-controls={expanded ? controls : undefined}
      onClick={onToggle}
    >
      <span className="cv-worked__label">{workedLabel(t, row)}</span>
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
/// finished and draws no summary line of its own, so a group starts closed.
function groupNode(group: ToolGroup, index: number, rowId: string, live: boolean, folded = false): ReactNode {
  switch (group.type) {
    case "group":
      return (
        <ToolGroupRow
          key={group.items[0]!.tool!.id || index}
          kind={group.kind}
          items={group.items}
          folded={folded}
          disclosureKey={`group:${group.kind}:${group.items[0]!.tool!.id || `${rowId}:${index}`}`}
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
      return <MessageCard key={group.item.tool!.id || index} item={group.item} message={group.message} />;
    case "subsession":
      return <SubsessionCallCard key={group.item.tool!.id || index} call={group.call} />;
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
        <ThoughtRow key={index} id={`${rowId}:${index}`} item={group.item} streaming={live} />
      );
  }
}

/// A run of tool calls and thoughts between two pieces of text, in groups (toolGroups.ts). The
/// Codex-style runs (Debug toggle `agentPane.debug.codexToolRuns`, on by default) fold a finished
/// run (`foldRun`) of two or more entries under one summary line (toolRunSummary.ts: "Read files,
/// ran commands"), and a run that is one group under that group's closed line ("Ran 3 commands"),
/// so finished work is one click away between the paragraphs. Off, each group and call keeps its
/// own line.
export function shouldFoldToolRun(
  row: AcpmuxRow,
  groups: readonly ToolGroup[],
  items: readonly AcpmuxActivity[],
): boolean {
  // Coordination cards (a message, a sub-session started, messaged or waited on) stay visible
  // beside tool calls so a settled run never hides the agent-to-agent receipt inside the generic
  // tool summary.
  return (
    row.foldRun === true &&
    groups.length > 1 &&
    !groups.some((group) => group.type === "message" || group.type === "subsession") &&
    isFoldedRun(items)
  );
}
export function ToolRows({ row, sessionId }: { row: AcpmuxRow; sessionId?: string }) {
  const items = row.items;
  const groups = useMemo(() => toolGroups(items ?? []), [items]);
  const run = shouldFoldToolRun(row, groups, items ?? []);
  const nodes = groups.map((group, at) =>
    groupNode(group, at, row.id, row.live === true && at === groups.length - 1, row.foldRun === true && !run),
  );
  // Find opens what holds its current match in this row only (chatFind.ts).
  const reveal = useContext(FindReveal);
  // Ids an MCP call names, to the titles the run's other calls give them ("Read Coordination hub").
  const names = useMemo(() => mcpNames(items), [items]);
  return (
    <TranscriptDisclosureProvider sessionId={sessionId}>
      <McpNamesContext.Provider value={names}>
        <FindReveal.Provider value={reveal && isRevealRow(row, reveal) ? reveal : undefined}>
          <div className="cv-tools">
            {run ? (
              <ToolRun disclosureKey={`run:${row.id}`} items={items ?? []}>
                {nodes}
              </ToolRun>
            ) : (
              nodes
            )}
          </div>
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
  const { fork, forkSeq, forkAny, retry, retryWith, reauthenticate, route, switchModel } =
    useContext(TurnActionsContext);
  const text = row.text;
  const prompt = row.prompt;
  const seq = row.seq;
  const failed = row.status === "failed" || row.status === "error";
  const kind = failed ? failureKind(row.error, route) : undefined;
  // Only the CLI's own login (or an unexplained 401 on a direct route) asks to sign in (cx-w10a).
  const authenticationFailed = kind === "subscription-login" || kind === "auth";
  // A failure reads as the turn's answer does: its own block above the footer row, never squeezed
  // into it (Codex, Claude desktop). The row is one quiet line under the answer's left edge; it
  // shows on hover or keyboard focus, and always for a failed turn (VirtualTranscript marks the
  // turn the reader points at, from its answer to its footer).
  return (
    <>
      {failed && <TurnFailure message={row.error} route={route} switchModel={switchModel} />}
      <div className={failed ? "cv-turn-actions cv-turn-actions--failed" : "cv-turn-actions"}>
        {!row.folded && <span className="cv-turn-summary">{workedLabel(t, row)}</span>}
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
              <Retry size={14} />
            </button>
          )}
          {failed && retry && prompt && retryWith && retryWith.models.length > 1 && (
            <RetryModelMenu
              retryWith={retryWith}
              onPick={(model) => retryWith.retry(row.retryRowId ?? "", prompt, model)}
            />
          )}
          {fork && seq !== undefined && (forkAny || seq === forkSeq) && <ForkButton onFork={() => fork(seq)} />}
          <PinButton rowId={row.id} />
          {text && <ReadAloudButton id={row.id} text={text} />}
          {authenticationFailed && reauthenticate && (
            <button type="button" className="cv-turn-auth-action" onClick={reauthenticate}>
              {t("turn.signInAgain")}
            </button>
          )}
        </span>
        <MessageTime at={row.at} className="cv-turn-time" />
      </div>
    </>
  );
}

/// A failed turn's note (cx-w10a): the cause in plain words, naming the harness and the proxy or endpoint
/// when the error names one, never a generic "sign-in expired"; the agent's own message under Details;
/// Switch model for capacity, network, key, proxy and sign-in failures; Copy error always.
function TurnFailure({
  message,
  route,
  switchModel,
}: {
  message: string | undefined;
  route?: FailureRoute;
  switchModel?: () => void;
}) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const kind = failureKind(message, route);
  const sentence = failureCopy(t, message, route);
  // A sign-in failure offers it too: the picker moves the chat to a route that is signed in (cx-gz0dz).
  const offersSwitch =
    switchModel &&
    ["rate-limited", "unreachable", "invalid-key", "proxy-auth", "subscription-login", "auth"].includes(kind);
  return (
    <div className="cv-turn-note" data-failure-kind={kind}>
      <span className="text-fg">{sentence}</span>
      {message && sentence !== message && (
        <details className="mt-0.5" onToggle={(event) => setDetailsOpen(event.currentTarget.open)}>
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
          <span className="mt-1 block font-mono text-detail whitespace-pre-wrap text-dim select-text">{message}</span>
        </details>
      )}
      {(offersSwitch || message) && (
        <span className="mt-1 flex flex-wrap gap-1.5">
          {offersSwitch && (
            <button type="button" className="cv-turn-auth-action" onClick={switchModel}>
              {t("turn.failure.switchModel")}
            </button>
          )}
          {message && (
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
          )}
        </span>
      )}
    </div>
  );
}
