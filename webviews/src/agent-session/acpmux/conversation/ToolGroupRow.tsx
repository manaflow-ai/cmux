// Consecutive calls of one kind under one line ("Ran 3 commands", "Read 4 files", "Edited
// App.tsx +12 -3") that opens to the calls on a tree guide: commands as command rows, edits
// as their diffs, reads and searches as their own rows.
import { useMemo, useState, type ReactNode } from "react";
import { toolFiles } from "../diff";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { EditDiff } from "./EditDiff";
import { ToolRow } from "./ToolRow";
import { ChevronRight, Magnifier, OpenBook, Pencil, Spinner, TerminalSquare } from "./icons";
import { isFailed, isRunning, toolGroupLabel, type ToolGroupKind } from "./toolGroups";
import { t } from "../i18n";

function groupIcon(kind: ToolGroupKind): ReactNode {
  switch (kind) {
    case "commands":
      return <TerminalSquare />;
    case "reads":
      return <OpenBook />;
    case "edits":
      return <Pencil size={16} strokeWidth={1.1} />;
    case "searches":
      return <Magnifier />;
  }
}

/// A live group stays closed as calls join it, so the transcript's height holds still; its
/// glyph turns while any call runs.
export function ToolGroupRow({ kind, items }: { kind: ToolGroupKind; items: readonly AcpmuxActivity[] }) {
  const [open, setOpen] = useState(false);
  const tools = useMemo(() => items.map((item) => item.tool!), [items]);
  const files = useMemo(() => (kind === "edits" ? toolFiles(tools) : []), [kind, tools]);
  const running = tools.some(isRunning);
  const failures = tools.filter(isFailed).length;
  const additions = files.reduce((sum, file) => sum + file.additions, 0);
  const deletions = files.reduce((sum, file) => sum + file.deletions, 0);
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle${running ? " is-live" : " is-strong"}`}
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-tool__icon">{running ? <Spinner size={16} /> : groupIcon(kind)}</span>
        <span className="cv-tool__text">
          {toolGroupLabel(
            kind,
            items,
            files.map((file) => file.path),
          )}
          {files.length > 0 && (
            <span className="cv-tool__counts">
              <span className="cv-edit-diff__add">+{additions}</span>
              <span className="cv-edit-diff__del">-{deletions}</span>
            </span>
          )}
          {failures > 0 && <span className="cv-tool__failed"> {t("tools.failedCount", { n: failures })}</span>}
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {open && (
        <div className="cv-tool-group">
          {kind === "commands"
            ? items.map((item, index) => <CommandRow key={item.tool!.id || index} item={item} />)
            : [
                ...files.map((file) => <EditDiff key={file.path} file={file} />),
                // Reads and searches, and edits that carried no diff (a delete, a move), as rows.
                ...items
                  .filter((item) => !files.length || !item.tool!.diffs?.length)
                  .map((item, index) => <ToolRow key={item.tool!.id || index} item={item} />),
              ]}
        </div>
      )}
    </>
  );
}
