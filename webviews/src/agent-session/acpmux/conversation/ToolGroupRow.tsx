// Consecutive calls of one kind under one line ("Ran 3 commands", "Read 4 files", "Edited
// App.tsx +12 -3") over the calls on a tree guide: commands as command rows, edits as their
// diffs, reads and searches as their own rows.
import { useFindReveal } from "./chatFind";
import { useId, useMemo, type ReactNode } from "react";
import { toolFiles } from "../diff";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { EditDiff } from "./EditDiff";
import { ToolRow } from "./ToolRow";
import { ChevronRight, Magnifier, OpenBook, Pencil, Spinner, TerminalSquare } from "./icons";
import { isFailed, isRunning, toolGroupLabel, type ToolGroupKind } from "./toolGroups";
import { useT } from "../i18n";
import { useTranscriptDisclosure } from "./transcriptDisclosure";

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

/// How many of a group's latest calls show under its open line; the earlier ones wait behind
/// "+K more", so a long run stays dense (one line per call) without hiding what just ran.
export const GROUP_TAIL = 5;

/// Commands, reads and searches open by default, one row per call, as the Codex and Claude Code
/// desktop apps list them; edits stay closed, since each opens to its whole diff. The glyph turns
/// while any call runs.
export function ToolGroupRow({
  kind,
  items,
  disclosureKey,
}: {
  kind: ToolGroupKind;
  items: readonly AcpmuxActivity[];
  disclosureKey: string;
}) {
  const t = useT();
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey, kind !== "edits");
  const [all, setAll] = useTranscriptDisclosure(`${disclosureKey}:all`);
  const hidden = kind === "edits" || all ? 0 : Math.max(0, items.length - GROUP_TAIL);
  useFindReveal(items, () => setOpen(true));
  // A match in a call behind "+K more" shows the whole group.
  useFindReveal(
    useMemo(() => items.slice(0, hidden), [items, hidden]),
    () => setAll(true),
  );
  const shown = hidden ? items.slice(hidden) : items;
  const detailsId = useId();
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
        aria-controls={open ? detailsId : undefined}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-tool__icon">{running ? <Spinner size={16} /> : groupIcon(kind)}</span>
        <span className="cv-tool__text" data-find-skip>
          {toolGroupLabel(
            t,
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
        <div className="cv-tool-group" id={detailsId}>
          {hidden > 0 && (
            <button type="button" className="cv-tool cv-tool-group__more" onClick={() => setAll(true)}>
              <span className="cv-tool__text">{t("tools.more", { n: hidden })}</span>
            </button>
          )}
          {kind === "commands"
            ? shown.map((item, index) => <CommandRow key={item.tool!.id || index} item={item} />)
            : [
                ...files.map((file) => <EditDiff key={file.path} file={file} />),
                // Reads and searches, and edits that carried no diff (a delete, a move), as rows.
                ...shown
                  .filter((item) => !files.length || !item.tool!.diffs?.length)
                  .map((item, index) => <ToolRow key={item.tool!.id || index} item={item} />),
              ]}
        </div>
      )}
    </>
  );
}
