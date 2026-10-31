// Where a Claude Code chat's session started (sessionStart.ts), in the quiet one-line style of the
// transcript's other notes (a background task's end, a compaction): "Claude Code · Opus 5.5 · sr2".
// The whole of it (Claude Code's version, the model id, the route, the folder) shows on hover and
// opens under the line on a click. Nothing else: how the chat compacts is not an event, so it does
// not take a transcript row; each compaction shows as its own note when it happens (Leo
// 2026-10-21: no "cmux manages compaction" explainer in the transcript).
import { useId } from "react";
import { useT } from "../i18n";
import type { AcpmuxSessionStart } from "../model";
import { modelIdName } from "../defaultChoice";
import { ChevronRight, TerminalSquare } from "./icons";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { foldHome, routeOf } from "./sessionStart";

export function SessionStartNote({ start }: { start: AcpmuxSessionStart }) {
  const t = useT();
  const [open, setOpen] = useTranscriptDisclosure("sessionStart:details");
  const detailsId = useId();
  const route = routeOf(start.harness);
  const short = [
    t("sessionStart.agent"),
    start.model ? modelIdName(start.model, t) : undefined,
    route === "sr2"
      ? t("sessionStart.routeShort.sr2")
      : route === "coderouter"
        ? t("sessionStart.routeShort.coderouter")
        : undefined,
  ].filter((fact): fact is string => !!fact);
  const facts = [
    t("sessionStart.claudeCode", { version: start.version }),
    start.model,
    route === "sr2"
      ? t("sessionStart.route.sr2")
      : route === "coderouter"
        ? t("sessionStart.route.coderouter")
        : t("sessionStart.route.own"),
    start.cwd ? foldHome(start.cwd) : undefined,
  ]
    .filter((fact): fact is string => !!fact)
    .join(" · ");
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
        <span className="cv-tool__text">{short.join(" · ")}</span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <div id={detailsId} className="cv-session-start__detail selectable">
          {facts}
        </div>
      )}
    </div>
  );
}
