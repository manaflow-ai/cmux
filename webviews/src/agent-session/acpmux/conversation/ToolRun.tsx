// A settled run of tool calls: one summary line ("Read 6 files, ran 4 commands", and "1 failed"
// when a call failed) that opens to the calls themselves. The rows grow with the transcript's one
// vertical scroll surface; opened command/output bodies keep their own horizontal overflow.
import { useFindReveal } from "./chatFind";
import { useId, useMemo, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { ChevronRight, Globe, Magnifier, Pencil, Spinner, TerminalSquare, ToolGroup } from "./icons";
import { isFailed, isRunning } from "./toolGroups";
import { mainToolRunCategory, toolRunSummary, type ToolRunCategory } from "./toolRunSummary";
import { useToolRunLook } from "../toolRunLook";
import { useTranscriptDisclosure, useTranscriptViewContext } from "./transcriptDisclosure";
import { isThought } from "./thoughts";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { EditCounts, useEditTotals } from "./EditCounts";
import { ToolLabel } from "./ToolVerb";

/// The summary's glyph: its main kind of work's, with searches and reads both as the magnifier.
function runIcon(category: ToolRunCategory | undefined): ReactNode {
  switch (category) {
    case "edited":
      return <Pencil size={16} strokeWidth={1.1} />;
    case "read":
    case "searched":
      return <Magnifier />;
    case "web":
      return <Globe size={16} strokeWidth={1.1} />;
    case "ran":
      return <TerminalSquare />;
    default:
      return <ToolGroup size={16} strokeWidth={1.2} />;
  }
}

export function ToolRun({
  items,
  children,
  disclosureKey,
}: {
  items: readonly AcpmuxActivity[];
  children: ReactNode;
  disclosureKey: string;
}) {
  const t = useT();
  const look = useToolRunLook();
  // The Verbose transcript view opens the run to its calls; Thinking opens a run that holds a
  // thought, so the thought it opens is on screen.
  const thinking = useTranscriptViewContext() === "thinking";
  const holdsThought = useMemo(() => thinking && items.some(isThought), [thinking, items]);
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey, holdsThought, true);
  useFindReveal(items, () => setOpen(true));
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const list = useId();
  // Read once per run: the row draws again only when its version moves (App.tsx ToolActivityRow),
  // and then only a new list of calls counts again.
  const { summary, main, failures, running } = useMemo(
    () => ({
      summary: toolRunSummary(t, items),
      main: mainToolRunCategory(items),
      // A failed call never hides behind the summary: the line counts it, as a group's line does.
      failures: items.filter((item) => item.tool && isFailed(item.tool)).length,
      // A call still running in the run (a background shell) turns the glyph, as a group's does.
      running: items.some((item) => item.tool && isRunning(item.tool)),
    }),
    [t, items],
  );
  // The lines the run's edits added and removed, on its summary line as Claude Code desktop puts
  // them (Leo 2026-10-30: "i like claude code they put the number overarching too").
  const totals = useEditTotals(items);
  const pencil = look === "pencil" || look === "quiet-pencil";
  const quiet = look === "quiet" || look === "quiet-pencil";
  return (
    <>
      <button
        type="button"
        className={quiet ? "cv-tool is-toggle" : "cv-tool is-toggle is-strong"}
        aria-expanded={open}
        aria-controls={open ? list : undefined}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        <span className="cv-tool__icon">{running ? <Spinner size={16} /> : runIcon(pencil ? "edited" : main)}</span>
        <span className={totals ? "cv-tool__text has-counts" : "cv-tool__text"} data-find-skip>
          <span className="cv-tool__summary">
            <ToolLabel text={summary} />
          </span>
          {totals && <EditCounts totals={totals} />}
          {failures > 0 && <span className="cv-tool__failed"> {t("tools.failedCount", { n: failures })}</span>}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {fold.present && (
        <div {...fold.bodyProps}>
          <div className="cv-tool-run" id={list}>
            {children}
          </div>
        </div>
      )}
    </>
  );
}
