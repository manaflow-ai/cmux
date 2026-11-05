// How an opened run's background commands stand while any still runs, as Claude Code desktop notes
// it among a run's rows: "1 background command completed, 1 running", or "1 background command
// completed, 1 failed, 1 running" with "1 failed" in the error tone (Leo, 2026-11-03: "claude code
// desktop's summarization of tool calls/parsing of them seem kinda good?"). One quiet line on the
// rows' grid at the end of the opened group's steps (ToolGroupRow.tsx); once none runs it goes, and
// the group's head counts what finished ("Finished 2 background tasks, ran 5 commands").
import { Fragment } from "react";
import { useT } from "../i18n";
import { type BackgroundCounts, backgroundStatusParts } from "./backgroundStatusLineModel";
export function BackgroundStatusLine({ counts }: { counts: BackgroundCounts }) {
  const t = useT();
  const parts = backgroundStatusParts(t, counts);
  return (
    <output className="cv-bgstatus" data-find-skip>
      {/* One line box: as flex items, the separator's text would lose its space ("completed,1 failed"). */}
      <span className="cv-bgstatus__text">
        {parts.map((part, at) => (
          <Fragment key={part.text}>
            {at > 0 && t("toolRun.separator")}
            <span className={part.failed ? "cv-tool__failed" : undefined}>{part.text}</span>
          </Fragment>
        ))}
      </span>
    </output>
  );
}
