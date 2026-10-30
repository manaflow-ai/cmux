import { WrittenArtifactButtons } from "./writtenArtifacts";
// Consecutive calls of one kind under one line ("Ran 3 commands", "Read 4 files", "Edited
// App.tsx +12 -3") over the calls on a tree guide: commands as command rows, edits as their
// diffs, reads and searches as their own rows, and a thought between two calls in its place.
import { useFindReveal } from "./chatFind";
import { useId, useMemo, type ReactNode } from "react";
import { toolFiles } from "../diff";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { EditDiff } from "./EditDiff";
import { ThoughtRow } from "./ThoughtRow";
import { ToolRow } from "./ToolRow";
import { ChevronRight, Magnifier, OpenBook, Pencil, Spinner, TerminalSquare } from "./icons";
import { groupCalls, isFailed, isRunning, toolGroupLabel, type ToolGroupKind } from "./toolGroups";
import { useT } from "../i18n";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { WriteLabel, writeCall } from "./WriteLabel";
import { ToolLabel } from "./ToolVerb";
import { toolFailure } from "./toolFailure";
import { failureWord, InlineFailureCause, ToolFailureCause } from "./ToolFailureCause";

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

type EntryNode = { kind: ToolGroupKind; key: string | number; node: ReactNode };
const entryCache = new WeakMap<AcpmuxActivity, EntryNode>();

/// The group's item rows, one element per item, kept by item identity. direct.ts and childRows.ts
/// replace only the item a chunk changed, so an unchanged item keeps its element and React skips
/// its row: a streamed chunk renders only the changed call, never its siblings, and no sibling
/// output or thought is parsed again. The pass is an identity check per item, with no element,
/// render or parse for an unchanged one. It is the walk React makes over the children anyway,
/// and it notices a delayed update to any earlier call, not only the tail. Items are immutable
/// snapshots, so an entry lives exactly as long as its item (a WeakMap, no cleanup needed).
function entryNodes(
  items: readonly AcpmuxActivity[],
  kind: ToolGroupKind,
  thoughtId: (n: number) => string,
): ReactNode[] {
  const nodes: ReactNode[] = [];
  let thoughts = 0;
  for (let at = 0; at < items.length; at += 1) {
    const item = items[at]!;
    // A thought's stable ordinal keeps its choice when more calls append to the group.
    const key = item.tool ? item.tool.id || at : thoughtId(thoughts++);
    let entry = entryCache.get(item);
    if (entry?.kind !== kind || entry.key !== key) {
      const node = !item.tool ? (
        <ThoughtRow key={key} id={key as string} item={item} />
      ) : kind === "commands" ? (
        <CommandRow key={key} item={item} />
      ) : (
        <ToolRow key={key} item={item} />
      );
      entry = { kind, key, node };
      entryCache.set(item, entry);
    }
    nodes.push(entry.node);
  }
  return nodes;
}

/// Commands, reads and searches open by default, one row per call, as the Codex and Claude Code
/// desktop apps list them; edits stay closed, since each opens to its whole diff. A finished run
/// that is this one group (`folded`: text followed it) stays closed too, one summary line between
/// the paragraphs ("Ran 3 commands"), as the Codex app folds finished work. The glyph turns while
/// any call runs.
export function ToolGroupRow({
  kind,
  items,
  disclosureKey,
  folded = false,
  thoughtId = (n) => `${disclosureKey}:thought:${n}`,
}: {
  kind: ToolGroupKind;
  items: readonly AcpmuxActivity[];
  disclosureKey: string;
  folded?: boolean;
  /// The id of the group's n-th thought (TurnRows.tsx `thoughtIds`): the same one the thought had
  /// drawn on its own before a call joined it to this group.
  thoughtId?: (n: number) => string;
}) {
  const t = useT();
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey, kind !== "edits" && !folded);
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  useFindReveal(items, () => setOpen(true));
  // Opening the group shows every call. Each call still owns its full body's disclosure.
  const entryRows = entryNodes(items, kind, thoughtId);
  const detailsId = useId();
  const tools = useMemo(() => groupCalls(items).map((item) => item.tool!), [items]);
  const files = useMemo(() => (kind === "edits" ? toolFiles(tools) : []), [kind, tools]);
  // The line's totals leave out a file a Write rewrote with old contents unknown (model.ts
  // `contentsUnknown`), as the edited-files card does: its written text is not lines added.
  const counted = useMemo(() => (kind === "edits" ? toolFiles(tools, { known: true }) : []), [kind, tools]);
  const running = tools.some(isRunning);
  const failures = tools.filter(isFailed).length;
  const additions = counted.reduce((sum, file) => sum + file.additions, 0);
  const deletions = counted.reduce((sum, file) => sum + file.deletions, 0);
  // A lone Write reads as what it wrote, "Wrote notes.md +18", not as an edit (WriteLabel.tsx).
  const write = kind === "edits" && tools.length === 1 ? writeCall(tools[0]!) : undefined;
  // A group of one call says why it failed as a lone call does (toolFailure.ts); several say how many.
  const failure = useMemo(() => (tools.length === 1 ? toolFailure(tools[0]!) : undefined), [tools]);
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle${running ? " is-live" : " is-strong"}`}
        data-tool-group={disclosureKey}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        <span className="cv-tool__icon">{running ? <Spinner size={16} /> : groupIcon(kind)}</span>
        <span className="cv-tool__text" data-find-skip>
          {write ? (
            <WriteLabel tool={tools[0]!} write={write} t={t} />
          ) : (
            <>
              <ToolLabel
                text={toolGroupLabel(
                  t,
                  kind,
                  items,
                  files.map((file) => file.path),
                )}
              />
              {counted.length > 0 && (
                <span className="cv-tool__counts">
                  <span className="cv-edit-diff__add">+{additions}</span>
                  <span className="cv-edit-diff__del">-{deletions}</span>
                </span>
              )}
            </>
          )}
          {failures > 0 && (
            <span className="cv-tool__failed">
              {" "}
              {failure ? failureWord(t, failure) : t("tools.failedCount", { n: failures })}
            </span>
          )}
          <InlineFailureCause failure={failure} />
        </span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      <WrittenArtifactButtons tools={tools} />
      <ToolFailureCause failure={failure} />
      {fold.present && (
        <div {...fold.bodyProps}>
          <div
            className={kind === "edits" ? "cv-tool-group" : "cv-tool-group is-flat"}
            id={detailsId}
            data-tool-group-items={disclosureKey}
          >
            {!files.length
              ? entryRows
              : [
                  ...files.map((file) => <EditDiff key={file.path} file={file} />),
                  // Edits that carried no diff (a delete, a move), as rows.
                  ...entryRows.filter((_, index) => !items[index]!.tool?.diffs?.length),
                ]}
          </div>
        </div>
      )}
    </>
  );
}
