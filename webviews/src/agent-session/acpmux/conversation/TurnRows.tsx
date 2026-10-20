// Turn rows for the pane's transcript: the "Worked for" disclosure, tool rows and the
// footer under an answer. Markup and metrics from reference prototype (messages.tsx,
// TurnMessage.tsx); each component takes the pane's row and draws one transcript entry.
import { FindReveal, isRevealRow } from "./chatFind";
import { useContext, useMemo, useState, type ReactNode } from "react";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { copyText } from "./clipboard";
import { MessageCard } from "./MessageCard";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRow } from "./ToolRow";
import { ToolRun } from "./ToolRun";
import { ThoughtRow } from "./ThoughtRow";
import { toolGroups, type ToolGroup } from "./toolGroups";
import { foldsRun } from "./toolRunSummary";
import { TurnActionsContext } from "./turnActions";
import { workedLabel } from "./turns";
import { ChevronDown, ChevronRight, Copy, Retry, TurnFork } from "./icons";
import { Menu, MenuButton, MenuPopup, MenuRadioGroup, MenuRadioItem } from "../../../ui/Menu";
import type { TurnActions } from "./turnActions";
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

/// When an entry began: its first call's start, or a thought's first chunk.
function groupStart(group: ToolGroup | undefined): number | undefined {
  if (!group) return undefined;
  const item = group.type === "group" ? group.items[0] : group.item;
  return item?.tool?.startedAt ?? item?.startedAt;
}

/// One entry of a run: a group, a message card, a lone call or a thought. `live`: the entry is the
/// last of the live turn's latest row, so a thought there may still stream. `next` is the entry
/// after it, whose start ends a thought ("Thought for 4s"); the last entry's thought ends when the
/// row after its row started (`nextAt`).
function groupNode(
  group: ToolGroup,
  index: number,
  rowId: string,
  live: boolean,
  next: ToolGroup | undefined,
  nextAt: number | undefined,
): ReactNode {
  switch (group.type) {
    case "group":
      return (
        <ToolGroupRow
          key={group.items[0]!.tool!.id || index}
          kind={group.kind}
          items={group.items}
          disclosureKey={`group:${group.kind}:${group.items[0]!.tool!.id || `${rowId}:${index}`}`}
        />
      );
    case "message":
      return <MessageCard key={group.item.tool!.id || index} item={group.item} message={group.message} />;
    case "item":
      return group.item.tool ? (
        <ToolRow key={group.item.tool.id || index} item={group.item} />
      ) : (
        <ThoughtRow
          key={index}
          id={`${rowId}:${index}`}
          item={group.item}
          streaming={live}
          until={next ? groupStart(next) : nextAt}
        />
      );
  }
}

/// A run of tool calls and thoughts between two pieces of text, in groups (toolGroups.ts). An ended
/// turn's open "Worked for" lists every entry on its own line, so its thoughts, messages and last
/// steps all show (Leo 2026-10-13); the Debug toggle `agentPane.debug.workedForFoldsRuns` folds a
/// run of two or more entries there under one summary line instead (toolRunSummary.ts), as Codex
/// does. A live turn lists each, unless the Codex-style runs (Debug toggle, on in the app) settle
/// it into that line (`foldRun`) or show its newest entry (`inFlight`).
export function shouldFoldToolRun(
  row: AcpmuxRow,
  groups: readonly ToolGroup[],
  items: readonly AcpmuxActivity[],
): boolean {
  // Coordination cards stay visible beside tool calls so a settled run never hides the
  // agent-to-agent receipt inside the generic tool summary.
  return foldsRun(row, items) && groups.length > 1 && !groups.some((group) => group.type === "message");
}
export function ToolRows({ row, sessionId }: { row: AcpmuxRow; sessionId?: string }) {
  const items = row.items;
  const groups = useMemo(() => toolGroups(items ?? []), [items]);
  // A run in flight (Debug toggle) shows its newest entry alone: one line that replaces itself.
  const first = row.inFlight ? Math.max(0, groups.length - 1) : 0;
  const nodes = groups
    .slice(first)
    .map((group, at) =>
      groupNode(
        group,
        first + at,
        row.id,
        row.live === true && first + at === groups.length - 1,
        groups[first + at + 1],
        row.nextAt,
      ),
    );
  // Find opens what holds its current match in this row only (chatFind.ts).
  const reveal = useContext(FindReveal);
  return (
    <TranscriptDisclosureProvider sessionId={sessionId}>
      <FindReveal.Provider value={reveal && isRevealRow(row, reveal) ? reveal : undefined}>
        <div className="cv-tools">
          {shouldFoldToolRun(row, groups, items ?? []) ? (
            <ToolRun disclosureKey={`run:${row.id}`} items={items ?? []}>
              {nodes}
            </ToolRun>
          ) : (
            nodes
          )}
        </div>
      </FindReveal.Provider>
    </TranscriptDisclosureProvider>
  );
}

const clock = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

/// The quiet row under an answer: copy, retry (the last turn, while acpmux is reachable), fork
/// from here (when acpmux serves forks), the time, and why the turn ended when it did not
/// complete. A turn without a "Worked for" line (history paged in mid-turn) says its time and
/// count here instead.
export function TurnFooter({ row }: { row: AcpmuxRow }) {
  const t = useT();
  const [copied, setCopied] = useState(false);
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
  // between Worked for and the time (Codex, Claude desktop). The row is one quiet line at the
  // column's right edge, where a prompt's Copy and Edit sit under its bubble: Worked for and the
  // time as muted text, then the actions (Leo 2026-10-13). It shows for the last turn, a failed
  // one, or while the reader points at its turn (VirtualTranscript marks it).
  return (
    <>
      {failed && <TurnFailure message={row.error} route={route} switchModel={switchModel} />}
      <div className={failed ? "cv-turn-actions cv-turn-actions--failed" : "cv-turn-actions"}>
        {!row.folded && <span className="cv-turn-summary">{workedLabel(t, row)}</span>}
        <time className="cv-turn-time" dateTime={new Date(row.at).toISOString()}>
          {clock.format(row.at)}
        </time>
        <span className="cv-turn-action-group">
          {text && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={copied ? t("turn.copied") : t("turn.copy")}
              title={copied ? t("turn.copied") : t("turn.copy")}
              onClick={() =>
                void copyText(text).then(
                  () => setCopied(true),
                  () => setCopied(false),
                )
              }
            >
              <Copy size={14} />
            </button>
          )}
          {retry && prompt && (
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
          {retry && prompt && retryWith && retryWith.models.length > 1 && (
            <RetryModelMenu
              retryWith={retryWith}
              onPick={(model) => retryWith.retry(row.retryRowId ?? "", prompt, model)}
            />
          )}
          {authenticationFailed && reauthenticate && (
            <button type="button" className="cv-turn-auth-action" onClick={reauthenticate}>
              {t("turn.signInAgain")}
            </button>
          )}
          {fork && seq !== undefined && (forkAny || seq === forkSeq) && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("turn.fork")}
              title={t("turn.fork")}
              onClick={() => fork(seq)}
            >
              <TurnFork size={14} />
            </button>
          )}
        </span>
      </div>
    </>
  );
}

/// Retry with another model (cx-ncc.62): the chat harness's models, the current one checked.
function RetryModelMenu({
  retryWith,
  onPick,
}: {
  retryWith: NonNullable<TurnActions["retryWith"]>;
  onPick(model: string): void;
}) {
  const t = useT();
  return (
    <Menu>
      <MenuButton
        className="cv-iconbtn cv-iconbtn--compact cv-turn-retry-menu"
        label={t("turn.retryWith")}
        title={t("turn.retryWith")}
      >
        <ChevronDown size={12} />
      </MenuButton>
      <MenuPopup label={t("turn.retryWith")} align="start">
        <MenuRadioGroup value={retryWith.current ?? ""} onValueChange={onPick}>
          {retryWith.models.map((model) => (
            <MenuRadioItem key={model.id} value={model.id} closeOnClick>
              {model.name}
            </MenuRadioItem>
          ))}
        </MenuRadioGroup>
      </MenuPopup>
    </Menu>
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
