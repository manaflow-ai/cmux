// Find in Chat: matches of a query in the transcript's prompts, replies and work (each tool call's
// title, command, output and edit diffs), the one the reader is on, and the highlights over the
// rows on screen (CSS custom highlights, so the rendered rows are never rewritten). The transcript
// is virtualized: matches come from the rows' text, and a row draws its highlights once it mounts.
// The current match opens what hides it: its turn's "Worked for" fold (App.tsx) and, through
// FindReveal, the tool group or call that holds it (cx-ncc.70).
import { createContext, useCallback, useContext, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { commandFolder } from "./commandFolder";
import { execParts, execText, execView, isCmuxExec } from "./cmuxExec";
import { cleanText, mcpCall, mcpOutputResult, prettyOutput, prettyValue } from "./mcpCalls";
import { plainText } from "./messageMenu";
import { drawnThought } from "./thoughts";
import { callOutput, shellOutput, toolFailure } from "./toolFailure";
import { toolResult } from "./toolResult";
import { stripsEnvelopeImages } from "../toolImages";

/** The text Find compares: case-folded, and as long as it was, so a match's offset in the folded text
 * is its offset in what the page draws. `İ` (U+0130) lowercases to two code units (`i` and a
 * combining dot), which moved every highlight after it one character; it folds to `i` instead.
 * `toLowerCase` and not `toLocaleLowerCase`, whose result follows the host's locale (Lithuanian
 * expands more letters, Turkish folds `I` to `ı`): a query matches the same text on every machine. */
export const foldFind = (text: string) => text.replace(/\u0130/g, "i").toLowerCase();

/** One match: the `occurrence`th match of the query in row `rowIndex`. */
export type FindMatch = { rowIndex: number; rowId: string; occurrence: number };

export type FindMatchesCache = {
  needle: string;
  rows: readonly AcpmuxRow[];
  matches: FindMatch[];
};

export type FindMatchesResult = {
  matches: FindMatch[];
  cache: FindMatchesCache;
  /** Number of rows whose searchable text was inspected for this result. */
  scannedRows: number;
};

/** The highlight names conversation.css styles. */
export const FIND_HIGHLIGHT = "acpmux-find";
export const FIND_ACTIVE_HIGHLIGHT = "acpmux-find-active";

/// Prompts, replies, and another agent's message waiting in the queue (QUEUED_MESSAGE, its text),
/// which the transcript draws in the group of waiting messages (pendingMessages.ts).
const SEARCHED_KINDS = new Set(["user", "assistant", "queuedMessage"]);

/** What a tool call or thought draws: a thought's text, or a call's command (else its title) and
 * output. Group and run summaries are not counted, so they are not highlighted (`data-find-skip`). */
/// An MCP call draws its pretty request and response (McpCallRows.tsx); other output draws
/// without the context a host injects into it, as ToolRow does.
function drawnText(item: AcpmuxActivity): string {
  const tool = item.tool;
  // A thought draws its headings without their marks (ThoughtRow.tsx, thoughts.ts thoughtParts).
  if (!tool) return item.kind === "thought" ? drawnThought(item.text) : item.text;
  const call = mcpCall(tool);
  // A finished call's envelope images show in its strip, not its text (toolImages.ts).
  const strip = stripsEnvelopeImages(tool);
  // A cmux script draws its script, calls, result and logs (McpCallRows.tsx CmuxExecDetails).
  const failure = call ? toolFailure(tool) : undefined;
  if (call && isCmuxExec(call) && failure?.kind !== "hook") {
    const parts = execParts(execView(tool, call.args), cleanText);
    return execText(parts, parts.rawResponse ? prettyOutput(tool.output, strip) : undefined);
  }
  if (call) {
    const output = failure?.kind === "hook" ? failure.output : tool.output;
    const result = mcpOutputResult(output, strip, call.tool);
    const text = result?.lang === "markdown" ? plainText(result.text) : result?.text;
    return [prettyValue(call.args), text].filter(Boolean).join("\n");
  }
  const shell = tool.kind === "execute" && Boolean(tool.command);
  // A shell draws its output without Claude Code's leading "Exit code N" line (toolFailure.ts), which
  // its Shell block says once, at its end. Other output reads as ToolRow draws it: out of its envelope,
  // without injected context (toolResult.ts), and Markdown as its words, without the marks
  // (messageMenu.ts plainText).
  const raw = shell ? undefined : callOutput(tool);
  const result = shell || !raw ? undefined : toolResult(raw, cleanText, strip, tool);
  const output = shell
    ? shellOutput(tool)
    : !result
      ? raw
      : result.lang === "markdown"
        ? plainText(result.text)
        : result.text;
  // The command as its rows draw it, without a leading `cd <folder> &&` (commandFolder).
  return [(tool.command && commandFolder(tool.command).rest) || tool.title, output].filter(Boolean).join("\n");
}

/** A call's edits' new text, which draws in @pierre/diffs' shadow root, past the page's highlights. */
const diffText = (item: AcpmuxActivity) => (item.tool?.diffs ?? []).map((diff) => diff.newText).join("\n");

/** What Find reads of one tool call or thought. */
export const activityText = (item: AcpmuxActivity) => `${drawnText(item)}\n${diffText(item)}`;

// Find reveal hooks run in each tool row while the bar is open. Activity snapshots are immutable,
// so reuse their case-folded text instead of rebuilding long command output and diffs per render.
const searchableActivityTextCache = new WeakMap<AcpmuxActivity, string>();

function searchableActivityText(item: AcpmuxActivity): string {
  const cached = searchableActivityTextCache.get(item);
  if (cached !== undefined) return cached;
  const text = foldFind(activityText(item));
  searchableActivityTextCache.set(item, text);
  return text;
}

/** What Find reads of a row: a prompt's or reply's text, or its tool calls'. Diffs come last, so
 * the drawn matches keep their order and a diff's match lands on the row's last drawn one. */
function rowText(row: AcpmuxRow): string | undefined {
  if (SEARCHED_KINDS.has(row.kind)) return row.text;
  if (!row.items?.length) return undefined;
  return [...row.items.map(drawnText), ...row.items.map(diffText)].join("\n");
}

// Rows are immutable snapshots. Keep the assembled, case-folded search text by row identity so
// typing a query does not rebuild every tool output and edit diff on every keystroke. A weak map
// lets old transcript snapshots disappear as virtualization/history replacement releases them.
const searchableTextCache = new WeakMap<AcpmuxRow, string | undefined>();

function searchableText(row: AcpmuxRow): string | undefined {
  if (searchableTextCache.has(row)) return searchableTextCache.get(row);
  const raw = rowText(row);
  const text = raw === undefined ? undefined : foldFind(raw);
  searchableTextCache.set(row, text);
  return text;
}

/** Every match of `query` (case-insensitive) in the prompts, replies and work of `rows`, in order. */
export function findMatchesIncremental(
  rows: readonly AcpmuxRow[],
  query: string,
  previous?: FindMatchesCache,
): FindMatchesResult {
  const needle = foldFind(query);
  if (!needle) {
    return { matches: [], cache: { needle, rows, matches: [] }, scannedRows: 0 };
  }

  let prefix = 0;
  if (previous?.needle === needle) {
    while (prefix < rows.length && prefix < previous.rows.length && rows[prefix] === previous.rows[prefix]) prefix += 1;
  }

  if (previous?.needle === needle && prefix === rows.length && rows.length === previous.rows.length) {
    return { matches: previous.matches, cache: { needle, rows, matches: previous.matches }, scannedRows: 0 };
  }

  const matches = previous?.needle === needle ? previous.matches.filter(({ rowIndex }) => rowIndex < prefix) : [];
  for (let rowIndex = prefix; rowIndex < rows.length; rowIndex += 1) {
    const row = rows[rowIndex];
    const text = searchableText(row);
    if (!text) continue;
    let occurrence = 0;
    for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length))
      matches.push({ rowIndex, rowId: row.id, occurrence: occurrence++ });
  }
  return { matches, cache: { needle, rows, matches }, scannedRows: rows.length - prefix };
}

export function findMatches(rows: readonly AcpmuxRow[], query: string): FindMatch[] {
  return findMatchesIncremental(rows, query).matches;
}

export type ChatFind = {
  open: boolean;
  query: string;
  matches: FindMatch[];
  /** The index in `matches` of the current match; 0 when there are none. */
  active: number;
  /** Opens the bar, with `text` as the query when given. Bumps `focusRequest`. */
  show: (text?: string) => void;
  hide: () => void;
  setQuery: (query: string) => void;
  next: () => void;
  previous: () => void;
  /** Changes on each `show`, so the bar focuses its field again. */
  focusRequest: number;
};

/** What a find bar (ChatFindBar) reads: the chat's find, or another view's (the changes view). */
export type FindBarState = Omit<ChatFind, "matches"> & { matches: readonly unknown[] };

/** The find state of a transcript of `rows`. */
export function useChatFind(rows: readonly AcpmuxRow[]): ChatFind {
  const [open, setOpen] = useState(false);
  const [query, setQueryState] = useState("");
  const [active, setActive] = useState(0);
  const [focusRequest, setFocusRequest] = useState(0);
  const matchesCache = useRef<FindMatchesCache | undefined>(undefined);
  const matches = useMemo(() => {
    if (!open) return [];
    const result = findMatchesIncremental(rows, query, matchesCache.current);
    matchesCache.current = result.cache;
    return result.matches;
  }, [open, rows, query]);
  const count = matches.length;
  const current = count ? Math.min(active, count - 1) : 0;
  // Where focus was when the bar opened, so closing it puts the reader back there.
  const opener = useRef<HTMLElement | null>(null);
  const show = useCallback((text?: string) => {
    const focused = document.activeElement;
    if (focused instanceof HTMLElement && !focused.closest(".acpmux-find")) opener.current = focused;
    setOpen(true);
    if (text) {
      setQueryState(text);
      setActive(0);
    }
    setFocusRequest((request) => request + 1);
  }, []);
  const hide = useCallback(() => {
    setOpen(false);
    const target = opener.current;
    opener.current = null;
    // Only from the bar itself (or nowhere), so Hide Find from a menu leaves the composer alone.
    const focused = document.activeElement;
    const fromBar = !focused || focused === document.body || focused.closest(".acpmux-find");
    if (fromBar && target?.isConnected) target.focus({ preventScroll: true });
  }, []);
  const setQuery = useCallback((next: string) => {
    setQueryState(next);
    setActive(0);
  }, []);
  const step = useCallback(
    (by: number) => {
      if (!count) return;
      setOpen(true);
      setActive((index) => (Math.min(index, count - 1) + by + count) % count);
    },
    [count],
  );
  const next = useCallback(() => step(1), [step]);
  const previous = useCallback(() => step(-1), [step]);
  return { open, query, matches, active: current, show, hide, setQuery, next, previous, focusRequest };
}

/** The transcript row that draws the current match (`id` and whether it is an edited-files card)
 * and the query, while Find shows one; ToolRows passes it to that row only. `repaint` redraws the
 * highlights once a part opens (only that part re-renders otherwise). */
export type FindRevealTarget = {
  rowId: string;
  card: boolean;
  needle: string;
  repaint: () => void;
  /** Opens the part that holds this call instead of the parts whose text holds `needle` (a count on
   * the running line, WorkingFor.tsx). */
  toolId?: string;
  /** The match's own row when `rowId` draws it inside itself (a message in the group of waiting
   * messages, PendingMessagesCard.tsx): only that one opens. */
  matchRowId?: string;
};
export const FindReveal = createContext<FindRevealTarget | undefined>(undefined);

/// A grouped message keeps its own Find/highlight target even though its outer row scrolls in.
export const findMemberRowId = (row: AcpmuxRow | undefined, target: string | undefined): string | undefined =>
  target && (row?.pendingMessages || row?.laneNoticeBatch) && row.id !== target && row.joined?.includes(target)
    ? target
    : undefined;

/** Whether `row` draws match row `rowId` itself: the row, its copy in an open fold, or the run
 * that absorbed it (turns.ts `mergeShortNotes`). */
export const isFindRow = (row: AcpmuxRow, rowId: string) =>
  (!row.ended && (row.id === rowId || Boolean(row.joined?.includes(rowId)))) || row.id === `${rowId}:fold`;

/** Whether `row` is the edited-files card (turns.ts) that merges edit `rowId`. */
const isCardOf = (row: AcpmuxRow, rowId: string) => Boolean(row.ended) && (row.merged ?? [row.id]).includes(rowId);

/** Whether `row` is the one `reveal` names. */
export const isRevealRow = (row: AcpmuxRow, reveal: Pick<FindRevealTarget, "rowId" | "card">) =>
  (row.id === reveal.rowId || Boolean(row.joined?.includes(reveal.rowId))) && Boolean(row.ended) === reveal.card;

/** Where the transcript draws match row `rowId`: the row or its fold copy (isFindRow), else the
 * edited-files card that holds it (an edit after the answer is only there); -1 while hidden. */
export function findRowIndex(rows: readonly AcpmuxRow[], rowId: string): number {
  const at = rows.findIndex((row) => isFindRow(row, rowId));
  return at >= 0 ? at : rows.findIndex((row) => isCardOf(row, rowId));
}

/** Calls `open` when the current match is in `items`, so a closed group or call shows it. */
export function useFindReveal(items: readonly AcpmuxActivity[], open: () => void) {
  const reveal = useContext(FindReveal);
  const hit = Boolean(
    reveal &&
    items.some((item) =>
      reveal.toolId !== undefined
        ? item.tool?.id === reveal.toolId
        : searchableActivityText(item).includes(reveal.needle),
    ),
  );
  useLayoutEffect(() => {
    if (!hit) return;
    open();
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [hit, reveal]);
}

type HighlightRegistry = { set(name: string, value: unknown): void; delete(name: string): void };

function registry(): HighlightRegistry | undefined {
  return (globalThis.CSS as unknown as { highlights?: HighlightRegistry } | undefined)?.highlights;
}

/** The text a highlight searches, in runs: each text node on its own, except that consecutive ones
 * inside one `data-find-join` element (a tool row's label, its verb in the column apart from its
 * subject, ToolVerb.tsx) are one run, so a match may span them as it spans the words they draw. */
function findRuns(walker: TreeWalker): Node[][] {
  const runs: Node[][] = [];
  let join: Element | null = null;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const owner = node.parentElement?.closest("[data-find-join]") ?? null;
    if (owner && owner === join) runs[runs.length - 1]!.push(node);
    else runs.push([node]);
    join = owner;
  }
  return runs;
}

/** Where offset `at` of a run's joined text lies: its node and the offset in it. An end that falls
 * on a boundary stays in the node before it; a start moves to the node after it. */
function nodeAt(nodes: readonly Node[], at: number, end: boolean): [Node, number] {
  let rest = at;
  for (const [index, node] of nodes.entries()) {
    const length = node.textContent?.length ?? 0;
    if (rest < length || (end && rest === length) || index === nodes.length - 1) return [node, rest];
    rest -= length;
  }
  return [nodes[0]!, 0];
}

/** Clears the find highlights. */
export function clearFindHighlights() {
  const highlights = registry();
  highlights?.delete(FIND_HIGHLIGHT);
  highlights?.delete(FIND_ACTIVE_HIGHLIGHT);
}

/**
 * Highlights `query` in the rows mounted under `root` (elements with `data-row-id`), and `active`
 * apart from the rest. A match that spans formatting (a bold word inside it) is not drawn. Returns
 * the active match's range when its row is mounted (its last match when the drawn text has fewer
 * than the row's text, such as a link's hidden address).
 */
export function paintFindHighlights(
  root: HTMLElement,
  query: string,
  active?: { rowId: string; card: boolean; occurrence: number },
): Range | undefined {
  const highlights = registry();
  const Highlight = (globalThis as unknown as { Highlight?: new (...ranges: Range[]) => unknown }).Highlight;
  const needle = foldFind(query);
  if (!highlights || !Highlight || !needle) {
    clearFindHighlights();
    return undefined;
  }
  const all: Range[] = [];
  let current: Range | undefined;
  for (const row of root.querySelectorAll<HTMLElement>("[data-row-id]")) {
    // Alternate presentations share one indexed value. Prefer Markdown only when its light-DOM
    // ranges cover every Raw occurrence of this query. Otherwise use Raw for the whole value:
    // mixing copies by ordinal would misidentify a hidden URL preceding a visible occurrence.
    const alternatives = new Map<string, { primary: number; fallback: number }>();
    for (const fallback of row.querySelectorAll<HTMLElement>("[data-find-fallback]")) {
      alternatives.set(fallback.dataset.findFallback!, { primary: 0, fallback: 0 });
    }
    const candidates: { range: Range; pair?: string; kind?: "primary" | "fallback" }[] = [];
    const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT, {
      // A member row drawn inside this one (`data-find-member`) counts its own matches, never twice.
      acceptNode: (node) =>
        node.parentElement?.closest("[data-find-skip]") ||
        node.parentElement
          ?.closest("[data-find-member][data-row-id]")
          ?.closest("[data-row-id]:not([data-find-member])") === row
          ? NodeFilter.FILTER_REJECT
          : NodeFilter.FILTER_ACCEPT,
    });
    for (const nodes of findRuns(walker)) {
      // A run's nodes share one presentation (a label's verb and subject sit in one element).
      const presentation = nodes[0]!.parentElement?.closest<HTMLElement>("[data-find-primary], [data-find-fallback]");
      const pair = presentation?.dataset.findPrimary ?? presentation?.dataset.findFallback;
      const kind = presentation?.hasAttribute("data-find-primary") ? "primary" : "fallback";
      const counts = pair === undefined ? undefined : alternatives.get(pair);
      const text = foldFind(nodes.map((node) => node.textContent ?? "").join(""));
      for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length)) {
        const range = document.createRange();
        const [startNode, startAt] = nodeAt(nodes, at, false);
        const [endNode, endAt] = nodeAt(nodes, at + needle.length, true);
        range.setStart(startNode, startAt);
        range.setEnd(endNode, endAt);
        if (counts) counts[kind]++;
        candidates.push({ range, pair, kind });
      }
    }
    const ranges = candidates
      .filter(({ pair, kind }) => {
        const counts = pair === undefined ? undefined : alternatives.get(pair);
        if (!counts) return true;
        return kind === (counts.primary === counts.fallback ? "primary" : "fallback");
      })
      .map(({ range }) => range);
    all.push(...ranges);
    // The row that draws the match (an edit and its edited-files card share an id).
    if (active && row.dataset.rowId === active.rowId && (row.dataset.rowCard === "true") === active.card) {
      if (ranges.length) current = ranges[Math.min(active.occurrence, ranges.length - 1)];
    }
  }
  highlights.set(FIND_HIGHLIGHT, new Highlight(...all.filter((range) => range !== current)));
  if (current) highlights.set(FIND_ACTIVE_HIGHLIGHT, new Highlight(current));
  else highlights.delete(FIND_ACTIVE_HIGHLIGHT);
  return current;
}
