// Turn rows for the pane's transcript: the "Worked for" disclosure, tool rows and the
// footer under an answer. Markup and metrics from reference prototype (messages.tsx,
// TurnMessage.tsx); each component takes the pane's row and draws one transcript entry.
import { useContext, useMemo, useState, type ReactNode } from "react";
import type { AcpmuxRow } from "../model";
import { copyText } from "./clipboard";
import { MessageCard } from "./MessageCard";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRow } from "./ToolRow";
import { ToolRun } from "./ToolRun";
import { toolGroups, type ToolGroup } from "./toolGroups";
import { isFoldedRun } from "./toolRunSummary";
import { TurnActionsContext } from "./turnActions";
import { workedLabel } from "./turns";
import { ChevronRight, Copy, Retry, TurnFork } from "./icons";
import { useT } from "../i18n";
import { failureCopy, failureKind, type FailureRoute } from "../failureCopy";

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

/// One entry of a run: a group, a message card, a lone call or a thought.
function groupNode(group: ToolGroup, index: number): ReactNode {
  switch (group.type) {
    case "group":
      return <ToolGroupRow key={group.items[0]!.tool!.id || index} kind={group.kind} items={group.items} />;
    case "message":
      return <MessageCard key={group.item.tool!.id || index} item={group.item} message={group.message} />;
    case "item":
      return group.item.tool ? (
        <ToolRow key={group.item.tool.id || index} item={group.item} />
      ) : (
        <div className="cv-tool cv-thought" key={index}>
          <span className="cv-tool__text">{group.item.text}</span>
        </div>
      );
  }
}

/// A run of tool calls and thoughts between two pieces of text, in groups (toolGroups.ts). In an
/// ended turn's open "Worked for", a run of two or more entries folds under one summary line
/// (toolRunSummary.ts); a run that is one group already has its line. A live turn lists each.
export function ToolRows({ row }: { row: AcpmuxRow }) {
  const items = row.items;
  const groups = useMemo(() => toolGroups(items ?? []), [items]);
  const nodes = groups.map(groupNode);
  return (
    <div className="cv-tools">
      {row.settled && groups.length > 1 && isFoldedRun(items ?? []) ? (
        <ToolRun items={items ?? []}>{nodes}</ToolRun>
      ) : (
        nodes
      )}
    </div>
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
  const { fork, forkSeq, retry, reauthenticate, route, switchModel } = useContext(TurnActionsContext);
  const text = row.text;
  const prompt = row.prompt;
  const seq = row.seq;
  const failed = row.status === "failed" || row.status === "error";
  const kind = failed ? failureKind(row.error, route) : undefined;
  // Only the CLI's own login (or an unexplained 401 on a direct route) asks to sign in (cx-w10a).
  const authenticationFailed = kind === "subscription-login" || kind === "auth";
  return (
    <div className="cv-turn-actions">
      {!row.folded && <span className="cv-turn-summary">{workedLabel(t, row)}</span>}
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
            onClick={() => retry(prompt)}
          >
            <Retry size={14} />
          </button>
        )}
        {authenticationFailed && reauthenticate && (
          <button type="button" className="cv-turn-auth-action" onClick={reauthenticate}>
            {t("turn.signInAgain")}
          </button>
        )}
        {fork && seq !== undefined && seq === forkSeq && (
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
      {failed && <TurnFailure message={row.error} route={route} switchModel={switchModel} />}
      <time className="cv-turn-time" dateTime={new Date(row.at).toISOString()}>
        {clock.format(row.at)}
      </time>
    </div>
  );
}

/// A failed turn's note (cx-w10a): the cause in plain words, naming the harness and the proxy or endpoint
/// when the error names one, never a generic "sign-in expired"; the agent's own message under Details;
/// Switch model for capacity, network, key and proxy failures; Copy error always.
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
  const kind = failureKind(message, route);
  const sentence = failureCopy(t, message, route);
  const offersSwitch = switchModel && ["rate-limited", "unreachable", "invalid-key", "proxy-auth"].includes(kind);
  return (
    <span className="cv-turn-note" data-failure-kind={kind}>
      <span className="text-fg">{sentence}</span>
      {message && sentence !== message && (
        <details className="mt-0.5">
          <summary className="cursor-pointer text-detail text-dim">{t("turn.failure.details")}</summary>
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
    </span>
  );
}
