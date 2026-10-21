// Where a Claude Code chat's session started (sessionStart.ts), in the quiet one-line style of the
// transcript's other notes (a background task's end, a compaction): "Claude Code · Opus 5.5 · sr2".
// The whole of it (Claude Code's version, the model id, the route, the folder) shows on hover and
// opens under the line on a click. Under it, until the person dismisses it, one line says how the
// chat compacts ("cmux manages compaction · Learn more"); Learn more opens the explanation (Leo
// 2026-10-20: the paragraph and the long facts line were a mishmash at the turn's end).
import { useId, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxSessionStart } from "../model";
import { modelIdName } from "../defaultChoice";
import { ChevronRight, Close, SummaryToggle, TerminalSquare } from "./icons";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import {
  compactionModeOf,
  compactionNoticeDismissed,
  dismissCompactionNotice,
  foldHome,
  routeOf,
} from "./sessionStart";

export function SessionStartNote({ start }: { start: AcpmuxSessionStart }) {
  const t = useT();
  const mode = compactionModeOf(start.harness);
  const [dismissed, setDismissed] = useState(() => compactionNoticeDismissed(mode));
  const [open, setOpen] = useTranscriptDisclosure("sessionStart:details");
  const [explained, setExplained] = useTranscriptDisclosure("sessionStart:compaction");
  const detailsId = useId();
  const explainId = useId();
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
        data-compaction={mode}
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
      {!dismissed && (
        <>
          <div className="cv-tool cv-session-start__compaction" data-compaction={mode}>
            <span className="cv-tool__icon">
              <SummaryToggle />
            </span>
            <span className="cv-tool__text">
              <span className="cv-session-start__compaction-text">
                {mode === "managed"
                  ? t("sessionStart.compaction.managedShort")
                  : t("sessionStart.compaction.stockShort")}
              </span>
              <span aria-hidden="true">{" · "}</span>
              <button
                type="button"
                className="cv-session-start__more"
                aria-expanded={explained}
                aria-controls={explained ? explainId : undefined}
                onClick={() => setExplained((value) => !value)}
              >
                {t("sessionStart.compaction.learnMore")}
              </button>
            </span>
            <button
              type="button"
              className="cv-session-start__dismiss"
              aria-label={t("sessionStart.compaction.dismiss")}
              onClick={() => {
                dismissCompactionNotice(mode);
                setDismissed(true);
              }}
            >
              <Close size={12} />
            </button>
          </div>
          {explained && (
            <div id={explainId} className="cv-session-start__detail">
              {mode === "managed" ? t("sessionStart.compaction.managed") : t("sessionStart.compaction.stock")}
            </div>
          )}
        </>
      )}
    </div>
  );
}
