// A settled run of tool calls: one summary line ("Read 6 files, ran 4 commands", and "1 failed"
// when a call failed) that opens to the calls themselves, in a list that scrolls past nine rows.
import { useFindReveal } from "./chatFind";
import { useId, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { ChevronRight, Globe, Magnifier, Pencil, TerminalSquare, ToolGroup } from "./icons";
import { isFailed } from "./toolGroups";
import { toolRunCategories, toolRunSummary, type ToolRunCategory } from "./toolRunSummary";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { useFold } from "./fold";

/// The summary's glyph: its leading category's, with searches and reads both as the magnifier.
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
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey);
  useFindReveal(items, () => setOpen(true));
  const fold = useFold(open);
  const list = useId();
  // A failed call never hides behind the summary: the line counts it, as a group's line does.
  const failures = items.filter((item) => item.tool && isFailed(item.tool)).length;
  return (
    <>
      <button
        type="button"
        className="cv-tool is-toggle is-strong"
        aria-expanded={open}
        aria-controls={open ? list : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-tool__icon">{runIcon(toolRunCategories(items)[0])}</span>
        <span className="cv-tool__text" data-find-skip>
          {toolRunSummary(t, items)}
          {failures > 0 && <span className="cv-tool__failed"> {t("tools.failedCount", { n: failures })}</span>}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {fold.present && (
        <div ref={fold.ref} className="cv-fold">
          <div className="cv-tool-run" id={list}>
            {children}
          </div>
        </div>
      )}
    </>
  );
}
