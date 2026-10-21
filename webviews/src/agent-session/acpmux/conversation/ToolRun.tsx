// A settled run of tool calls: one summary line ("Read files, ran commands")
// that opens to the calls themselves, in a list that scrolls past nine rows.
import { useFindReveal } from "./chatFind";
import { useId, type ReactNode } from "react";
import { useT } from "../i18n";
import type { AcpmuxActivity } from "../model";
import { ChevronRight, Globe, Magnifier, Pencil, TerminalSquare, ToolGroup } from "./icons";
import { toolRunCategories, toolRunSummary, type ToolRunCategory } from "./toolRunSummary";
import { useTranscriptDisclosure } from "./transcriptDisclosure";

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
  const list = useId();
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
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <div className="cv-tool-run" id={list}>
          {children}
        </div>
      )}
    </>
  );
}
