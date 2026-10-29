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

type ShownEntry = { item: AcpmuxActivity; at: number; thought: number };
type EntryUpdate = {
  items: readonly AcpmuxActivity[];
  entries: ShownEntry[];
  thoughtCount: number;
  version: number;
  changedIndex: number;
};

function makeEntry(item: AcpmuxActivity, at: number, thought: number): ShownEntry {
  return { item, at, thought: item.tool ? -1 : thought };
}

/// Keep a stable index as direct.ts appends a call or replaces only the streaming tail. Structural
/// changes rebuild the index for correctness; the normal streaming path updates one slot.
function createEntryCache(): (items: readonly AcpmuxActivity[]) => EntryUpdate {
  let current: EntryUpdate | undefined;
  return (items) => {
    if (!current) {
      const entries: ShownEntry[] = [];
      let thoughtCount = 0;
      for (let at = 0; at < items.length; at += 1) {
        entries.push(makeEntry(items[at]!, at, thoughtCount));
        if (!items[at]!.tool) thoughtCount += 1;
      }
      current = { items, entries, thoughtCount, version: 0, changedIndex: -1 };
      return current;
    }
    if (current.items === items) return current;
    const previousItems = current.items;
    const previousLength = previousItems.length;
    current.changedIndex = -1;
    if (
      items.length === previousLength + 1 &&
      (previousLength === 0 || items[previousLength - 1] === previousItems[previousLength - 1])
    ) {
      const item = items[previousLength]!;
      current.entries.push(makeEntry(item, previousLength, current.thoughtCount));
      if (!item.tool) current.thoughtCount += 1;
      current.changedIndex = previousLength;
    } else if (
      items.length === previousLength &&
      previousLength > 0 &&
      items[previousLength - 1] !== previousItems[previousLength - 1]
    ) {
      const at = previousLength - 1;
      const previous = current.entries[at]!;
      const item = items[at]!;
      if (previous.item.tool && !item.tool) {
        previous.thought = current.thoughtCount;
        current.thoughtCount += 1;
      } else if (!previous.item.tool && item.tool) {
        current.thoughtCount -= 1;
      }
      current.entries[at] = makeEntry(item, at, previous.thought);
      current.changedIndex = at;
    } else {
      current.entries.length = 0;
      current.thoughtCount = 0;
      for (let at = 0; at < items.length; at += 1) {
        current.entries.push(makeEntry(items[at]!, at, current.thoughtCount));
        if (!items[at]!.tool) current.thoughtCount += 1;
      }
      current.changedIndex = 0;
    }
    current.items = items;
    current.version += 1;
    return current;
  };
}

function createEntryNodeCache(): (
  update: EntryUpdate,
  kind: ToolGroupKind,
  thoughtId: (n: number) => string,
  present: boolean,
) => ReactNode[] {
  let current:
    | {
        version: number;
        kind: ToolGroupKind;
        thoughtId: (n: number) => string;
        nodes: ReactNode[];
        present: boolean;
      }
    | undefined;
  return (update, kind, thoughtId, present) => {
    if (!current || current.kind !== kind || current.thoughtId !== thoughtId) {
      const nodes: ReactNode[] = [];
      for (const entry of update.entries) {
        nodes.push(
          entry.item.tool ? (
            kind === "commands" ? (
              <CommandRow key={entry.item.tool.id || entry.at} item={entry.item} />
            ) : (
              <ToolRow key={entry.item.tool.id || entry.at} item={entry.item} />
            )
          ) : (
            <ThoughtRow key={thoughtId(entry.thought)} id={thoughtId(entry.thought)} item={entry.item} />
          ),
        );
      }
      current = { version: update.version, kind, thoughtId, nodes, present };
      return nodes;
    }
    if (present && !current.present) {
      current.present = true;
      return current.nodes.slice();
    }
    current.present = present;
    if (current.version === update.version) return current.nodes;
    if (update.changedIndex === update.entries.length - 1 && update.changedIndex >= 0) {
      const entry = update.entries[update.changedIndex]!;
      const node = entry.item.tool ? (
        kind === "commands" ? (
          <CommandRow key={entry.item.tool.id || entry.at} item={entry.item} />
        ) : (
          <ToolRow key={entry.item.tool.id || entry.at} item={entry.item} />
        )
      ) : (
        <ThoughtRow key={thoughtId(entry.thought)} id={thoughtId(entry.thought)} item={entry.item} />
      );
      if (update.changedIndex === current.nodes.length) current.nodes.push(node);
      else current.nodes[update.changedIndex] = node;
    } else {
      current.nodes.length = 0;
      for (const entry of update.entries) {
        current.nodes.push(
          entry.item.tool ? (
            kind === "commands" ? (
              <CommandRow key={entry.item.tool.id || entry.at} item={entry.item} />
            ) : (
              <ToolRow key={entry.item.tool.id || entry.at} item={entry.item} />
            )
          ) : (
            <ThoughtRow key={thoughtId(entry.thought)} id={thoughtId(entry.thought)} item={entry.item} />
          ),
        );
      }
    }
    current.version = update.version;
    return current.nodes;
  };
}

function buildEntryNodes(
  entries: readonly ShownEntry[],
  kind: ToolGroupKind,
  thoughtId: (n: number) => string,
): ReactNode[] {
  const nodes: ReactNode[] = [];
  for (const entry of entries) {
    nodes.push(
      entry.item.tool ? (
        kind === "commands" ? (
          <CommandRow key={entry.item.tool.id || entry.at} item={entry.item} />
        ) : (
          <ToolRow key={entry.item.tool.id || entry.at} item={entry.item} />
        )
      ) : (
        <ThoughtRow key={thoughtId(entry.thought)} id={thoughtId(entry.thought)} item={entry.item} />
      ),
    );
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
  // A thought's stable ordinal keeps its choice when more calls append to the group.
  const shown = useMemo(() => createEntryCache(), []);
  const entryNodes = useMemo(() => createEntryNodeCache(), []);
  const shownUpdate = shown(items);
  const entryRows = entryNodes(shownUpdate, kind, thoughtId, fold.present);
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
            {kind === "commands"
              ? entryNodes
              : [
                  ...files.map((file) => <EditDiff key={file.path} file={file} />),
                  // Reads and searches, and edits that carried no diff (a delete, a move), as rows.
                  ...entryRows.filter(
                    (_, index) => !files.length || !shownUpdate.entries[index]!.item.tool?.diffs?.length,
                  ),
                ]}
          </div>
        </div>
      )}
    </>
  );
}
