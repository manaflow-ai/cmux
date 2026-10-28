// The `thinking` row: a running turn's status line.
import { memo } from "react";
import { Thinking } from "../conversation/Thinking";
import type { RowProps } from "./rowProps";

/// A running turn's status: "Thinking", then "Working for 42s" (turnView in conversation/turns.ts).
export const ThinkingRow = memo(
  function ThinkingRow({ row }: RowProps) {
    const queued = row.queued;
    return (
      <Thinking
        status={row.status}
        since={row.at}
        doing={row.doing}
        doingAt={row.doingAt}
        doingShell={row.doingShell}
        draft={row.doingDraft}
        untimed={row.untimed}
        quietKey={row.quietKey}
        below={row.below}
        command={row.doingCommand}
        onCancel={
          queued
            ? () => void window.cmuxAcpmuxActions?.["chat.harness.cancelPrompt"]?.({ promptId: queued })
            : undefined
        }
      />
    );
  },
  // The start status line (version 0) becomes "Thinking" (version 1) in place.
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.status === b.row.status &&
    a.row.queued === b.row.queued &&
    a.row.at === b.row.at &&
    a.row.doing === b.row.doing &&
    a.row.doingAt === b.row.doingAt &&
    a.row.doingShell === b.row.doingShell &&
    a.row.doingDraft === b.row.doingDraft &&
    a.row.untimed === b.row.untimed &&
    a.row.quietKey === b.row.quietKey &&
    a.row.below === b.row.below &&
    a.row.doingCommand === b.row.doingCommand,
);
