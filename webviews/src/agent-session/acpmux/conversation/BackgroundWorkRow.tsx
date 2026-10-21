// The transcript's last row while background work outlives its turn: "Running in background ·
// 2 commands · 3 sessions" (commands from the process registry, chats the agent started, subagents
// still running; backgroundWork.ts). The running turn's line counts the same work
// (WorkingFor.tsx), so it shows only between turns. It is drawn as a tool row, in their font,
// height and rhythm, like a background task's end (BackgroundTaskNote.tsx), with the running
// rows' spinner. A click opens the Inspector (the summary card with it off), which lists each
// with Stop. Find skips it: it is status, not transcript. Its counts come with the running line's
// (WorkingFor.tsx `WorkingCounts`).
import { useContext } from "react";
import { useT } from "../i18n";
import { WorkingCountsContext } from "./WorkingFor";
import { Spinner } from "./icons";

export function BackgroundWorkLine() {
  const t = useT();
  const counts = useContext(WorkingCountsContext);
  const work = counts?.background;
  if (!work) return null;
  const parts = [
    t("bgWork.running"),
    work.commands > 0 && t("turn.working.commands", { n: work.commands }),
    work.sessions > 0 && t("turn.working.sessions", { n: work.sessions }),
    work.agents > 0 && t("turn.working.agents", { n: work.agents }),
  ].filter((part) => part !== false);
  return (
    <div className="cv-tools" data-find-skip>
      <button type="button" className="cv-tool cv-bgtask cv-bgwork" onClick={counts.openBackground}>
        <span className="cv-tool__icon">
          <Spinner />
        </span>
        <span className="cv-tool__text">{parts.join(" · ")}</span>
      </button>
    </div>
  );
}
