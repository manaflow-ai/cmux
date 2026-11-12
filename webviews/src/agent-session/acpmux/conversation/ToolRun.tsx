// A settled run of tool calls: one summary line ("Read 6 files, ran 4 commands", and "1 failed"
// when a call failed) that opens to the calls themselves. The rows grow with the transcript's one
// vertical scroll surface; opened command/output bodies keep their own horizontal overflow.
import { useFindReveal } from "./chatFind";
import { useId, useMemo, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { ChevronRight, Globe, Magnifier, MultiTool, Pencil, TerminalSquare, ToolGroup } from "./icons";
import { countsFailed, isRunning } from "./toolGroups";
import { isMixedToolRun, mainToolRunCategory, toolRunSummary, type ToolRunCategory } from "./toolRunSummary";
import { useToolRunLook } from "../toolRunLook";
import {
  callDisclosureKeys,
  FoldPin,
  useFoldPin,
  useTranscriptDisclosure,
  useTranscriptViewContext,
} from "./transcriptDisclosureModel";
import { isThought } from "./thoughts";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { EditCounts } from "./EditCounts";
import { useEditTotals } from "./editCountsModel";
import { FailedCount } from "./FailedCount";
import { ToolLabel } from "./ToolVerb";
import { RunScroll } from "./RunScroll";

/// The summary's glyph: its one kind of work's, with searches and reads both as the magnifier, or the
/// several-tools mark when it did more than one kind.
function runIcon(category: ToolRunCategory | "mixed" | undefined): ReactNode {
  switch (category) {
    case "mixed":
      return <MultiTool />;
    case "edited":
      return <Pencil size={16} />;
    case "read":
    case "searched":
      return <Magnifier />;
    case "web":
      return <Globe size={16} />;
    case "ran":
      return <TerminalSquare />;
    default:
      return <ToolGroup size={16} />;
  }
}

export function ToolRun({
  items,
  children,
  disclosureKey,
  inherits,
  passesDown,
  closedBy,
  thoughts,
  defaultOpen = false,
}: {
  items: readonly AcpmuxActivity[];
  children: ReactNode;
  disclosureKey: string;
  /// The keys of the group lines this run's line took the place of: one the reader opened opens it.
  inherits?: readonly string[];
  /// The group lines this run's line splits back into, which take the reader's choice on it.
  passesDown?: readonly string[];
  /// The group lines that drew open while the turn ran: the reader closing every one closes this.
  closedBy?: readonly string[];
  /// The ids of the thoughts among its calls (TurnRows.tsx): closing the run forgets their open choices.
  thoughts?: readonly string[];
  /// Open until the reader closes it: a run inside a steered turn's opened Worked for (turns.ts).
  defaultOpen?: boolean;
}) {
  const t = useT();
  const look = useToolRunLook();
  // The Verbose transcript view opens the run to its calls; Thinking opens a run that holds a
  // thought, so the thought it opens is on screen.
  const thinking = useTranscriptViewContext() === "thinking";
  const holdsThought = useMemo(() => thinking && items.some(isThought), [thinking, items]);
  // A call in the run the reader opened keeps the run open when it folds (`members`); a choice inside
  // the run pins it (`pin`).
  const members = useMemo(() => callDisclosureKeys(items), [items]);
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey, defaultOpen || holdsThought, true, {
    inherits,
    passesDown,
    members,
    closedBy,
    thoughts,
  });
  const pin = useFoldPin(disclosureKey);
  useFindReveal(items, () => setOpen(true));
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const list = useId();
  // Read once per run: the row draws again only when its version moves (App.tsx ToolActivityRow),
  // and then only a new list of calls counts again.
  const { summary, main, failures } = useMemo(
    () => ({
      summary: toolRunSummary(t, items),
      main: isMixedToolRun(items) ? ("mixed" as const) : mainToolRunCategory(items),
      // A failed call never hides behind the summary: the line counts it, as a group's line does.
      failures: items.filter((item) => item.tool && countsFailed(item.tool)).length,
    }),
    [t, items],
  );
  // The lines the run's edits added and removed, on its summary line as Claude Code desktop puts
  // them (Leo 2026-10-30: "i like claude code they put the number overarching too").
  const totals = useEditTotals(items);
  // A call still running keeps a long run's scroll box at its end as lines arrive (RunScroll.tsx).
  const running = items.some((item) => item.tool !== undefined && isRunning(item.tool));
  const pencil = look === "pencil" || look === "quiet-pencil";
  const quiet = look === "quiet" || look === "quiet-pencil";
  return (
    <>
      <button
        type="button"
        className={quiet ? "cv-tool is-toggle is-run" : "cv-tool is-toggle is-run is-strong"}
        data-tool-run={disclosureKey}
        aria-expanded={open}
        aria-controls={open ? list : undefined}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        <span className="cv-tool__icon">{runIcon(pencil ? "edited" : main)}</span>
        <span className={totals ? "cv-tool__text has-counts" : "cv-tool__text"} data-find-skip>
          <span className="cv-tool__summary">
            <ToolLabel text={summary} tight />
          </span>
          {totals && <EditCounts totals={totals} />}
          <FailedCount n={failures} />
        </span>
        <ChevronRight size={14} className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`} />
      </button>
      {fold.present && (
        <FoldPin.Provider value={pin}>
          <div {...fold.bodyProps}>
            <RunScroll running={running}>
              <div className="cv-tool-run" id={list}>
                {children}
              </div>
            </RunScroll>
          </div>
        </FoldPin.Provider>
      )}
    </>
  );
}
