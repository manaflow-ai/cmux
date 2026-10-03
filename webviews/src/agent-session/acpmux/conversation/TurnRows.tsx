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
import { ChevronRight, Copy, TurnFork } from "./icons";

/// The "Worked for 15s" line; it opens the turn's commentary and tool calls.
export function WorkedFor({ row, expanded, onToggle }: { row: AcpmuxRow; expanded: boolean; onToggle: () => void }) {
  return (
    <button type="button" className="cv-worked has-divider is-toggle" aria-expanded={expanded} onClick={onToggle}>
      <span className="cv-worked__label">{workedLabel(row)}</span>
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

/// The quiet row under an answer: copy, fork from here (when acpmux serves forks), the time,
/// and why the turn ended when it did not complete. A turn without a "Worked for" line (history paged in mid-turn) says its time
/// and count here instead.
export function TurnFooter({ row }: { row: AcpmuxRow }) {
  const [copied, setCopied] = useState(false);
  const { fork } = useContext(TurnActionsContext);
  const text = row.text;
  const seq = row.seq;
  const failed = row.status === "failed" || row.status === "error";
  return (
    <div className="cv-turn-actions">
      {!row.folded && <span className="cv-turn-summary">{workedLabel(row)}</span>}
      {text && (
        <button
          type="button"
          className="cv-iconbtn"
          aria-label={copied ? "Copied" : "Copy"}
          title={copied ? "Copied" : "Copy"}
          onClick={() =>
            void copyText(text).then(
              () => setCopied(true),
              () => setCopied(false),
            )
          }
        >
          <Copy />
        </button>
      )}
      {fork && seq !== undefined && (
        <button
          type="button"
          className="cv-iconbtn"
          aria-label="Fork from here"
          title="Fork from here"
          onClick={() => fork(seq)}
        >
          <TurnFork />
        </button>
      )}
      {failed && <span className="cv-turn-note">{row.error || "The turn failed"}</span>}
      <time className="cv-turn-time" dateTime={new Date(row.at).toISOString()}>
        {clock.format(row.at)}
      </time>
    </div>
  );
}
