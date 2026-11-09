// A Claude Code chat's model and route, in the quiet one-line style of the transcript's other notes
// (a background task's end, a compaction): "Claude Code · Sonnet 5.5 · sr2". The transcript draws
// it nowhere (Lucas, 2026-11-06: it landed inside the first turn's work and read as noise;
// rows/SessionStartRow.tsx), so it lives in the gallery and its unit test; /status says the same
// facts (Leo, 2026-11-05: "why does it even show that ... like we know what it is ... giving tmi").
// The whole of it (Claude Code's version, the model id, the route, the folder) shows on hover and
// opens under the line on a click.
import { useId } from "react";
import { useT } from "../i18n";
import type { AcpmuxSessionStart } from "../model";
import { ChevronRight, TerminalSquare } from "./icons";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { sessionStartLabels } from "./sessionStart";

export function SessionStartNote({ start, id = "details" }: { start: AcpmuxSessionStart; id?: string }) {
  const t = useT();
  const [open, setOpen] = useTranscriptDisclosure(`sessionStart:${id}`);
  const detailsId = useId();
  const { short, facts } = sessionStartLabels(start, t);
  return (
    <div className="cv-tools">
      <button
        type="button"
        className="cv-tool cv-session-start is-toggle"
        /* tooltip-allow: the line shows the short facts; the whole of them (version, model id, folder) is on hover */
        title={facts}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-tool__icon">
          <TerminalSquare />
        </span>
        <span className="cv-tool__text">{short}</span>
        <ChevronRight size={14} className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`} />
      </button>
      {open && (
        <div id={detailsId} className="cv-session-start__detail selectable">
          {facts}
        </div>
      )}
    </div>
  );
}
