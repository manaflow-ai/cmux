import { WrittenArtifactButtons } from "./writtenArtifacts";
// Consecutive calls of one kind under one line ("Ran 3 commands", "Read 4 files", "Edited
// App.tsx +12 -3"). Opened, commands, reads and searches list as Claude Code desktop lists a run's
// steps: one bordered, rounded group, the thought that led into the run first as its full text,
// then one row per step (a call's one-line summary, a later thought cut to one line), each with
// its disclosure right after its words, hairlines between them. Edits keep their diffs on a tree
// guide.
import { useFindReveal } from "./chatFind";
import { memo, useId, useMemo, useRef, type ReactNode } from "react";
import { toolFiles } from "../diff";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { EditCounts, useEditTotals } from "./EditCounts";
import { EditDiff } from "./EditDiff";
import { StepThought, ThoughtRow } from "./ThoughtRow";
import { ToolRow } from "./ToolRow";
import { ChevronRight, Magnifier, OpenBook, Pencil, Spinner, TerminalSquare } from "./icons";
import { isQuietThought, isThought } from "./thoughts";
import { groupCalls, isFailed, isRunning, toolGroupLabel, type ToolGroupKind } from "./toolGroups";
import { useT } from "../i18n";
import { useTranscriptDisclosure, useTranscriptViewContext } from "./transcriptDisclosure";
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

/// One drawn step of an opened group: the call or thought at `at` in the group's items, and a
/// thought's number among the group's thoughts (-1 for a call), which names it wherever it draws.
type StepEntry = { at: number; key: string; thought: number };

/// Test probes: how many times the group built its step list and each step drew. Unset in the app.
export const stepProbe: { build?: () => void; render?: (key: string) => void } = {};

/// The group's step entries, rebuilt only when its shape changes (a call or thought joins, or one
/// takes another's place), never when a call already listed streams output: the transcript replaces
/// only that call's activity, so the entries, keyed by tool id and place, stay as they were.
function useStepEntries(items: readonly AcpmuxActivity[]): StepEntry[] {
  const last = useRef<{ items: readonly AcpmuxActivity[]; entries: StepEntry[] } | undefined>(undefined);
  const prior = last.current;
  if (
    prior &&
    prior.items.length === items.length &&
    items.every((item, at) => {
      const before = prior.items[at]!;
      return item === before || (item.tool ? item.tool.id === before.tool?.id : !before.tool);
    })
  ) {
    last.current = { items, entries: prior.entries };
    return prior.entries;
  }
  stepProbe.build?.();
  let thoughts = 0;
  const seen = new Set<string>();
  const entries = items.map((item, at) => {
    if (!item.tool) return { at, key: `thought:${thoughts}`, thought: thoughts++ };
    // A call id seen twice (a child that reused it) keeps two rows apart by place.
    const id = item.tool.id;
    const key = id && !seen.has(id) ? `call:${id}` : `call:${id}:${at}`;
    if (id) seen.add(id);
    return { at, key, thought: -1 };
  });
  last.current = { items, entries };
  return entries;
}

type EntryNode = { kind: ToolGroupKind; key: string | number; node: ReactNode };
const entryCache = new WeakMap<AcpmuxActivity, EntryNode>();

/// An edits group's item rows (commands, reads and searches draw as Steps), one element per item,
/// kept by item identity. direct.ts and childRows.ts
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
        <CommandRow key={key} item={item} grouped />
      ) : (
        <ToolRow key={key} item={item} grouped />
      );
      entry = { kind, key, node };
      entryCache.set(item, entry);
    }
    nodes.push(entry.node);
  }
  return nodes;
}

/// Two drawings of one thought say the same: the transcript merges consecutive thoughts into a new
/// object on each update (thoughts.ts mergeThoughts), so a thought is compared by what it shows.
const sameThought = (a: AcpmuxActivity, b: AcpmuxActivity) =>
  a.text === b.text && a.startedAt === b.startedAt && a.endedAt === b.endedAt;

/// One step row between the group's hairlines. Memoized on its activity, so a call streaming its
/// output draws again alone and its siblings stay as they were.
const Step = memo(
  function Step({
    item,
    commands,
    thoughtId,
    lead,
    probeKey,
  }: {
    item: AcpmuxActivity;
    commands: boolean;
    thoughtId: string;
    lead: boolean;
    probeKey: string;
  }) {
    stepProbe.render?.(probeKey);
    if (!item.tool && isQuietThought(item)) return null;
    return (
      <div className={item.tool ? "cv-step" : lead ? "cv-step is-thought is-lead" : "cv-step is-thought"}>
        {item.tool ? (
          commands ? (
            <CommandRow item={item} grouped />
          ) : (
            <ToolRow item={item} grouped />
          )
        ) : (
          <StepThought id={thoughtId} item={item} lead={lead} />
        )}
      </div>
    );
  },
  (a, b) =>
    a.commands === b.commands &&
    a.thoughtId === b.thoughtId &&
    a.lead === b.lead &&
    a.probeKey === b.probeKey &&
    (a.item === b.item || (!a.item.tool && !b.item.tool && sameThought(a.item, b.item))),
);

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
  // The Verbose transcript view opens every group, edits included. Thinking opens a group that
  // holds a thought, so the thought it opens is on screen.
  const thinking = useTranscriptViewContext() === "thinking";
  const holdsThought = useMemo(() => thinking && items.some(isThought), [thinking, items]);
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey, (kind !== "edits" && !folded) || holdsThought, true);
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  useFindReveal(items, () => setOpen(true));
  // Every step shows, as Claude Code desktop lists a run's: no "+K more" behind the latest few.
  const entries = useStepEntries(kind === "edits" ? [] : items);
  const detailsId = useId();
  const tools = useMemo(() => groupCalls(items).map((item) => item.tool!), [items]);
  const files = useMemo(() => (kind === "edits" ? toolFiles(tools) : []), [kind, tools]);
  // The line's totals leave out a file a Write rewrote with old contents unknown (model.ts
  // `contentsUnknown`), as the edited-files card does: its written text is not lines added.
  const totals = useEditTotals(items);
  const running = tools.some(isRunning);
  const failures = tools.filter(isFailed).length;
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
        {write ? (
          <span className="cv-tool__text" data-find-skip>
            <WriteLabel tool={tools[0]!} write={write} t={t} />
            {failures > 0 && (
              <span className="cv-tool__failed">
                {" "}
                {failure ? failureWord(t, failure) : t("tools.failedCount", { n: failures })}
              </span>
            )}
            <InlineFailureCause failure={failure} />
          </span>
        ) : (
          // The summary cuts with an ellipsis; the totals after it never do (EditCounts.tsx).
          <span className={totals ? "cv-tool__text has-counts" : "cv-tool__text"} data-find-skip>
            <span className="cv-tool__summary">
              {/* The group's line reads as words, "Ran 2 commands", its count never pushed out to the
                  verb column its calls' rows share (Leo, 2026-10-29: "Why is there space between ran
                  and two?"). */}
              <ToolLabel
                whole
                text={toolGroupLabel(
                  t,
                  kind,
                  items,
                  files.map((file) => file.path),
                )}
              />
            </span>
            {totals && <EditCounts totals={totals} zero={kind === "edits"} />}
            {failures > 0 && (
              <span className="cv-tool__failed">
                {" "}
                {failure ? failureWord(t, failure) : t("tools.failedCount", { n: failures })}
              </span>
            )}
            <InlineFailureCause failure={failure} />
          </span>
        )}
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
          {kind === "edits" ? (
            <div className="cv-tool-group" id={detailsId} data-tool-group-items={disclosureKey}>
              {!files.length
                ? entryNodes(items, kind, thoughtId)
                : [
                    ...files.map((file) => <EditDiff key={file.path} file={file} />),
                    // Edits that carried no diff (a delete, a move), as rows.
                    ...entryNodes(items, kind, thoughtId).filter((_, index) => !items[index]!.tool?.diffs?.length),
                  ]}
            </div>
          ) : (
            <div
              className="cv-tool-group is-flat cv-steps"
              id={detailsId}
              data-kind={kind}
              data-tool-group-items={disclosureKey}
            >
              {entries.map(({ at, key, thought }) => (
                <Step
                  key={thought < 0 ? key : thoughtId(thought)}
                  probeKey={key}
                  item={items[at]!}
                  commands={kind === "commands"}
                  thoughtId={thought < 0 ? "" : thoughtId(thought)}
                  lead={at === 0 && thought === 0}
                />
              ))}
            </div>
          )}
        </div>
      )}
    </>
  );
}
