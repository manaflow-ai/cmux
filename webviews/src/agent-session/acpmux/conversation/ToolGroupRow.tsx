import { WrittenArtifactButtons } from "./writtenArtifacts";
// Consecutive calls of one kind under one line ("Ran 3 commands", "Read 4 files", "Edited
// App.tsx +12 -3"). Opened, commands, reads and searches list as Claude Code desktop lists a run's
// steps: one bordered, rounded group, the thought that led into the run first as its full text,
// then one row per step (a call's one-line summary, a later thought cut to one line), each with
// its disclosure right after its words, hairlines between them. Edits keep their diffs on a tree
// guide.
import { FindReveal, foldFind, useFindReveal } from "./chatFind";
import { memo, useContext, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { foldMs, markHeightFold } from "./fold";
import { toolFiles } from "../diff";
import type { AcpmuxActivity } from "../model";
import { CommandRow } from "./CommandRow";
import { EditCounts } from "./EditCounts";
import { useEditTotals } from "./editCountsModel";
import { FailedCount } from "./FailedCount";
import { EditDiff } from "./EditDiff";
import { StepThought, ThoughtRow } from "./ThoughtRow";
import { ToolRow } from "./ToolRow";
import { ChevronRight, Magnifier, OpenBook, Pencil, TerminalSquare } from "./icons";
import { isQuietThought, isThought } from "./thoughts";
import { countsFailed, groupCalls, isRunning, toolGroupLabel, type ToolGroupKind } from "./toolGroups";
import { RunScroll } from "./RunScroll";
import { useT } from "../i18n";
import {
  callDisclosureKeys,
  FoldPin,
  useFoldPin,
  useTranscriptDisclosure,
  useTranscriptViewContext,
} from "./transcriptDisclosureModel";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { WriteLabel } from "./WriteLabel";
import { writeCall } from "./writeLabelModel";
import { ToolLabel } from "./ToolVerb";
import { toolFailure } from "./toolFailure";
import { InlineFailureCause, ToolFailureCause } from "./ToolFailureCause";
import { failureWord, InStep } from "./toolFailureCauseModel";
import { firstStepCount, stepProbe } from "./toolGroupRowModel";

function groupIcon(kind: ToolGroupKind): ReactNode {
  switch (kind) {
    case "commands":
      return <TerminalSquare />;
    case "reads":
      return <OpenBook />;
    case "edits":
      return <Pencil size={16} />;
    case "searches":
      return <Magnifier />;
  }
}

/// One drawn step of an opened group: the call or thought at `at` in the group's items, and a
/// thought's number among the group's thoughts (-1 for a call), which names it wherever it draws.
type StepEntry = { at: number; key: string; thought: number };

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
      <div
        className={item.tool ? "cv-step" : lead ? "cv-step is-thought is-lead" : "cv-step is-thought"}
        data-step-call={item.tool?.id}
      >
        {item.tool ? (
          commands ? (
            <CommandRow item={item} />
          ) : (
            <ToolRow item={item} />
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

/// The height a step not drawn yet is given: the median distance between the drawn steps' tops, so
/// the lead thought drawn in full, or a failure's or image's taller row, does not set it. Rows that
/// differ from it are corrected as they draw (StepList).
function stepSlot(steps: NodeListOf<HTMLElement>): number {
  const tops = [...steps].map((step) => step.getBoundingClientRect().top);
  const slots = tops.slice(1).map((top, index) => top - tops[index]!);
  if (!slots.length) return steps[0]!.getBoundingClientRect().height;
  slots.sort((a, b) => a - b);
  return slots[Math.floor(slots.length / 2)]!;
}

/// How long after an opened run's last deferred rows drew it still keeps what the reader sees (a
/// thumbnail decoding late).
const KEEP_MS = 1000; // motion-allow: a watch window after the last draw, not an animation

/// What the reader sees first inside a run scrolled into: a drawn step (its top) or, past the drawn
/// steps, the run's foot, each as its distance from the run's row's top. Measured from the row, a
/// move of the whole row (rows above it) is the transcript's to keep (scrollAnchor.ts), not this.
type ViewAnchor = { node: HTMLElement; foot: boolean; at: number };

/// Puts back what the reader saw first (`before`) if a change above it in the run moved it, by
/// moving the offset the same distance, then returns what is first in view now. Nothing while the
/// run's top is in view: then every change in it is under what the reader sees first.
function keepView(list: HTMLElement, before: ViewAnchor | undefined): ViewAnchor | undefined {
  const scroller = list.closest<HTMLElement>(".acpmux-scroll");
  const row = list.closest<HTMLElement>(".acpmux-row");
  if (!scroller || !row) return undefined;
  const edge = (anchor: ViewAnchor) => {
    const box = anchor.node.getBoundingClientRect();
    return (anchor.foot ? box.bottom : box.top) - row.getBoundingClientRect().top;
  };
  if (before?.node.isConnected) {
    const moved = edge(before) - before.at;
    if (Math.abs(moved) >= 0.5) {
      const want = scroller.scrollTop + moved;
      scroller.scrollTop = want;
      // Cut short by the transcript's height (not yet as tall as the run): once more on the next
      // frame, after it has grown. One try only.
      if (Math.abs(scroller.scrollTop - want) >= 0.5)
        list.ownerDocument.defaultView?.requestAnimationFrame(() => {
          if (Math.abs(scroller.scrollTop - want) >= 0.5) scroller.scrollTop = want;
        });
    }
  }
  const view = scroller.getBoundingClientRect().top;
  if (list.getBoundingClientRect().top >= view) return undefined;
  // The first drawn step whose foot is under the view's top: they are in order, so a binary search.
  const steps = list.querySelectorAll<HTMLElement>(":scope > .cv-step");
  let low = 0;
  let high = steps.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (steps[mid]!.getBoundingClientRect().bottom > view) high = mid;
    else low = mid + 1;
  }
  const first = steps[low];
  const anchor: ViewAnchor | undefined = first
    ? { node: first, foot: false, at: 0 }
    : row.getBoundingClientRect().bottom > view
      ? { node: row, foot: true, at: 0 }
      : undefined;
  if (anchor) anchor.at = edge(anchor);
  return anchor;
}

/// An opened run's step rows. Opened by the reader's click, it draws only the rows the window can
/// show (`firstStepCount`) in the click's frame, and a box under them for the rest (`stepSlot`
/// each), set before the fold reads its height (a child's layout effect runs before its parent's),
/// so the fold opens in one motion. The rest draw once the fold is over, a window's worth per task,
/// into that box, off screen while the fold plays. A row taller or shorter than its room moves
/// only what is under it; when the reader has scrolled into the run, what they see first stays
/// where it is (`keepView`), so nothing in view moves. The draws stop when every row is drawn or
/// the list unmounts (the run closed). Opened any other way (Find, a view switch, a run that opens
/// itself), every row draws at once, and Find into a run still drawing draws the rest at once (Leo,
/// 2026-11-06: "The tool call expansion, when it has several tool calls, I think sometimes it lags
/// a bit").
function StepList({
  id,
  disclosureKey,
  entries,
  items,
  kind,
  thoughtId,
  defer,
}: {
  id: string;
  disclosureKey: string;
  entries: readonly StepEntry[];
  items: readonly AcpmuxActivity[];
  kind: ToolGroupKind;
  thoughtId: (n: number) => string;
  defer: boolean;
}) {
  // The rows per task; 0 draws every row at once.
  const [chunk] = useState(() => (defer && typeof window !== "undefined" ? firstStepCount(window.innerHeight) : 0));
  const [shown, setShown] = useState(() => chunk || Infinity);
  // An open that is not the reader's click (Find) takes over: every row draws now, so its match is there.
  if (!defer && shown !== Infinity) setShown(Infinity);
  const count = Math.min(shown, entries.length);
  const rest = entries.length - count;
  const list = useRef<HTMLDivElement>(null);
  const spacer = useRef<HTMLDivElement>(null);
  /// The height each row not drawn yet is given, set once from the first rows drawn.
  const slot = useRef<number | undefined>(undefined);
  /// What the reader sees first, once scrolled into the run, kept where it is (`keepView`).
  const anchor = useRef<ViewAnchor | undefined>(undefined);
  // Late sizes (an image that decodes after its row drew) are kept too, until KEEP_MS after the
  // last rows drew: then the run is the reader's again.
  const [keeping, setKeeping] = useState(chunk > 0);
  // Before paint: the box for the rows not drawn yet, and what the reader sees kept still as rows
  // replace it.
  useLayoutEffect(() => {
    const node = list.current;
    if (!node || !keeping) return;
    if (rest > 0) {
      slot.current ??= stepSlot(node.querySelectorAll<HTMLElement>(":scope > .cv-step"));
      if (spacer.current) spacer.current.style.height = `${rest * slot.current}px`;
    }
    // The rows under the run are placed before each frame paints while its rows draw (VirtualTranscript),
    // so the transcript is as tall as the run when `keepView` (its size observer, below) moves the offset.
    markHeightFold(node, KEEP_MS);
  }, [rest, keeping]);
  // While rows draw and a little after: a size change inside the run (rows drawn, a late thumbnail)
  // keeps what is first in view, and the reader's scroll picks it again. The size observer runs after
  // the transcript's own (made first), which has made the transcript as tall as the run by then, so
  // the offset it moves is not cut short. Stops KEEP_MS after the last rows drew, or on unmount.
  useEffect(() => {
    const node = list.current;
    const scroller = node?.closest<HTMLElement>(".acpmux-scroll");
    if (!keeping || !node || !scroller || typeof ResizeObserver !== "function") return;
    const sizes = new ResizeObserver(() => (anchor.current = keepView(node, anchor.current)));
    sizes.observe(node);
    const scrolled = () => (anchor.current = keepView(node, undefined));
    scroller.addEventListener("scroll", scrolled, { passive: true });
    return () => {
      sizes.disconnect();
      scroller.removeEventListener("scroll", scrolled);
    };
  }, [keeping]);
  useEffect(() => {
    if (!keeping || rest > 0) return;
    const timer = window.setTimeout(() => setKeeping(false), KEEP_MS);
    return () => window.clearTimeout(timer);
  }, [keeping, rest]);
  // The rest, a window's worth per task, from the fold's end: one timer at a time, none once all show.
  useEffect(() => {
    if (rest <= 0 || !chunk) return;
    const wait = shown === chunk ? foldMs(list.current?.closest<HTMLElement>(".cv-fold") ?? null) : 0;
    const timer = window.setTimeout(() => {
      const draw = () => setShown((now) => (now + chunk >= entries.length ? Infinity : now + chunk));
      if (stepProbe.hold) stepProbe.hold(draw);
      else draw();
    }, wait);
    return () => window.clearTimeout(timer);
  }, [rest, shown, chunk, entries.length]);
  return (
    <div
      ref={list}
      className="cv-tool-group is-flat cv-steps"
      id={id}
      data-kind={kind}
      data-tool-group-items={disclosureKey}
    >
      {/* Every call here is a step: a failure reads as one plain line (InStep). */}
      {/* A background command is a step like any other, its words shimmering while it runs;
          no line under the steps counts them (Leo, 2026-11-06: "why doesn't it just show it
          normally like the other ones?"). */}
      <InStep.Provider value>
        {entries.slice(0, count).map(({ at, key, thought }) => (
          <Step
            key={thought < 0 ? key : thoughtId(thought)}
            probeKey={key}
            item={items[at]!}
            commands={kind === "commands"}
            thoughtId={thought < 0 ? "" : thoughtId(thought)}
            lead={at === 0 && thought === 0}
          />
        ))}
      </InStep.Provider>
      {rest > 0 && <div ref={spacer} className="cv-steps__rest" data-steps-rest={rest} aria-hidden />}
    </div>
  );
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
  findTitle,
  inherits,
  closedBy,
  thoughtId = (n) => `${disclosureKey}:thought:${n}`,
}: {
  kind: ToolGroupKind;
  items: readonly AcpmuxActivity[];
  disclosureKey: string;
  folded?: boolean;
  /// The key of the run line this group's line takes the place of (TurnRows.tsx): opened, it opens this.
  inherits?: readonly string[];
  /// The key of the run line this group's line takes the place of: closed by the reader, it closes this.
  closedBy?: readonly string[];
  /** Original single-call title, revealed when Find matches a path the summary shortens. */
  findTitle?: string;
  /// The id of the group's n-th thought (TurnRows.tsx `thoughtIds`): the same one the thought had
  /// drawn on its own before a call joined it to this group.
  thoughtId?: (n: number) => string;
}) {
  const t = useT();
  const reveal = useContext(FindReveal);
  const showFindTitle = Boolean(findTitle && reveal?.needle && foldFind(findTitle).includes(reveal.needle));
  // The Verbose transcript view opens every group, edits included. Thinking opens a group that
  // holds a thought, so the thought it opens is on screen.
  const thinking = useTranscriptViewContext() === "thinking";
  const holdsThought = useMemo(() => thinking && items.some(isThought), [thinking, items]);
  // A call in the group the reader opened, before or after it was grouped, keeps the group open when
  // its run finishes; a choice inside the group pins it (`pin`).
  const members = useMemo(() => callDisclosureKeys(items), [items]);
  // Its thoughts' ids, as `entryNodes` numbers them: closing the group forgets their open choices.
  const thoughts = items.filter((item) => !item.tool).map((_, n) => thoughtId(n));
  const [open, setOpen] = useTranscriptDisclosure(disclosureKey, (kind !== "edits" && !folded) || holdsThought, true, {
    inherits,
    members,
    closedBy,
    thoughts,
  });
  const pin = useFoldPin(disclosureKey);
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  // Whether the reader's click opened the run: only then do its rows past the window draw after the
  // fold (StepList). Find opens it with every row drawn, so its match is there to show.
  const [byClick, setByClick] = useState(false);
  // Closed and gone, the next open is no click until the reader clicks it (a view switch, Find).
  if (byClick && !fold.present) setByClick(false);
  useFindReveal(items, () => {
    setByClick(false);
    setOpen(true);
  });
  // Every step shows, as Claude Code desktop lists a run's: no "+K more" behind the latest few.
  const entries = useStepEntries(kind === "edits" ? [] : items);
  const detailsId = useId();
  const tools = useMemo(() => groupCalls(items).map((item) => item.tool!), [items]);
  const files = useMemo(() => (kind === "edits" ? toolFiles(tools) : []), [kind, tools]);
  // The line's totals leave out a file a Write rewrote with old contents unknown (model.ts
  // `contentsUnknown`), as the edited-files card does: its written text is not lines added.
  const totals = useEditTotals(items);
  const running = tools.some(isRunning);
  const failures = tools.filter(countsFailed).length;
  // A lone Write reads as what it wrote, "Wrote notes.md +18", not as an edit (WriteLabel.tsx).
  const write = kind === "edits" && tools.length === 1 ? writeCall(tools[0]!) : undefined;
  // A group of one call says why it failed as a lone call does (toolFailure.ts); several say how many.
  const failure = useMemo(() => (tools.length === 1 ? toolFailure(tools[0]!) : undefined), [tools]);
  return (
    <>
      <button
        type="button"
        className={`cv-tool is-toggle is-run${running ? " is-live" : " is-strong"}`}
        data-tool-group={disclosureKey}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        ref={fold.headerRef}
        onClick={(event) => {
          // The click itself, so a drag across the line opens nothing (useAnchoredCollapse `deliberateClick`).
          const opening = !open;
          if (fold.toggle(event) && opening) setByClick(true);
        }}
      >
        <span className="cv-tool__icon">{groupIcon(kind)}</span>
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
            {/* One call says why it failed in a word; several say how many, "(2 failed)", as Claude
                Code desktop's header does (FailedCount.tsx). */}
            {failures > 0 && failure ? (
              <span className="cv-tool__failed"> {failureWord(t, failure)}</span>
            ) : (
              <FailedCount n={failures} />
            )}
            <InlineFailureCause failure={failure} />
          </span>
        )}
        <ChevronRight size={14} className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`} />
      </button>
      <WrittenArtifactButtons tools={tools} />
      <ToolFailureCause failure={failure} />
      {fold.present && (
        <FoldPin.Provider value={pin}>
          <div {...fold.bodyProps}>
            {showFindTitle && <pre className="cv-mcp-call__body selectable">{findTitle}</pre>}
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
              <RunScroll running={running}>
                <StepList
                  id={detailsId}
                  disclosureKey={disclosureKey}
                  entries={entries}
                  items={items}
                  kind={kind}
                  thoughtId={thoughtId}
                  defer={byClick}
                />
              </RunScroll>
            )}
          </div>
        </FoldPin.Provider>
      )}
    </>
  );
}
