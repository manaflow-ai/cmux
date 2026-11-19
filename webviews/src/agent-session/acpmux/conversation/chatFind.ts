// Find in Chat: matches of a query in the transcript's prompts, replies and work (each tool call's
// title, command, output and edit diffs), the one the reader is on, and the highlights over the
// rows on screen (CSS custom highlights, so the rendered rows are never rewritten). The transcript
// is virtualized: matches come from the rows' text, and a row draws its highlights once it mounts.
// The current match opens what hides it: its turn's "Worked for" fold (App.tsx) and, through
// FindReveal, the tool group or call that holds it (cx-ncc.70).
import { createContext, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { commandFolder } from "./commandFolder";
import { execParts, execText, execView, isCmuxExec } from "./cmuxExec";
import { cleanText, mcpCall, mcpOutputResult, prettyOutput, type McpCall } from "./mcpCalls";
import { acpmuxMcpSends } from "./acpmuxMcpSends";
import { agentMessage } from "./agentMessages";
import { dispatchCall, dispatchDestination, type DispatchCall } from "./dispatchCalls";
import { subsessionCall } from "./subsessionCalls";
import { argsSource, fieldsText, inputFields, opensToFields, requestText } from "./toolInputFields";
import { fileCard, fileCardText } from "./fileResults";
import { plainText } from "./messageMenu";
import { drawnPromptText, type PasteJoin } from "./promptCollapse";
import { bubbleParts } from "./bubbleParts";
import { sentPromptFindText } from "./sentUIPickModel";
import { chiefEnvelope } from "./chiefEnvelope";
import { sentPasteJoin } from "./sentPasteJoin.experiment";
import { experimentArm } from "../../../experiments/experiment";
import { drawnThought } from "./thoughts";
import { callOutput, rowFailed, shellOutput, toolFailure } from "./toolFailure";
import { agentCall } from "./agentCalls";
import { toolResult } from "./toolResult";
import { withoutLinks } from "./webSourceList";
import { stripsEnvelopeImages } from "../toolImages";
import { foldFind } from "../../../find/fold";
import { rowsWithLiveOutput } from "../liveToolOutput";
import { clearAdaptiveFind, paintAdaptiveFind, type FindColors } from "../../../ui/findPaint";
import {
  findSteps,
  hitLoaded,
  INDEX_DEBOUNCE_MS,
  INDEX_PAGE,
  INDEX_PAGES,
  landedStep,
  mergeHits,
  nearestStep,
  WINDOW_PAGE,
  type FindIndexSource,
  type FindStep,
  type IndexHit,
} from "./findIndex";
import type { FindRevealValue } from "./findReveal";

export { foldFind };

/** One match: the `occurrence`th match of the query in row `rowIndex`. */
export type FindMatch = { rowIndex: number; rowId: string; occurrence: number };

export type FindMatchesCache = {
  needle: string;
  /// How prompts drew when these matches were found (`promptLook`): another look redoes every row.
  look: string;
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
/// The theme's find highlight (conversation.css's fallback rules), fit to the surface under each
/// match: a prompt's bubble, a card, a command's output, the transcript (ui/findPaint.ts; Leo
/// 2026-11-07: "the inner highlight, I feel like needs to be a bit more, like distinguishable").
const CHAT_FIND_COLORS: FindColors = {
  match: "color-mix(in srgb, var(--agent-highlight, #f5c542) 40%, transparent)",
  current: "var(--agent-highlight, #f5c542)",
  currentInk: "var(--agent-highlight-text, #1d1d1f)",
};
/// Dispatched on the pane's shell when Find in Chat's bar opens (ChatFindBar.tsx): where the chat has
/// no room for the bar beside Session Info, the panel steps aside (session-info/SessionInfo.tsx
/// findBarCramped) instead of covering it.
export const FIND_OPEN_EVENT = "acpmux-find-open";
/// Dispatched on the pane's shell to close Find in Chat's bar: the person opened Session Info over it
/// where the chat has no room for both.
export const FIND_HIDE_EVENT = "acpmux-find-hide";

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
  // A dispatch or message card draws its words, never its call's input (DispatchCard.tsx,
  // MessageCard.tsx): Find reads those, from either harness's shape.
  const dispatch = dispatchCall(item);
  if (dispatch) return dispatchText(dispatch);
  const message = !tool.command && !acpmuxMcpSends(tool) ? agentMessage(tool) : undefined;
  // Its text draws as Markdown (AgentMessageBody.tsx), so Find reads its words, not its marks.
  if (message) return [message.to, message.text && plainText(message.text)].filter(Boolean).join("\n");
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
    // Arguments that open as labeled fields are read as their values (ToolDetail.tsx); any other
    // shape, and a hook's refusal, as the pretty request.
    const source = argsSource(tool);
    const fields = failure?.kind === "hook" || drawnAsCard(item, call) ? undefined : inputFields(call.args, source);
    return [fields ? fieldsText(fields, plainText) : requestText(call.args, source), text].filter(Boolean).join("\n");
  }
  // A subagent's card draws its report, then its prompt (AgentCallCard.tsx); its line is a summary.
  const agent = agentCall(tool);
  if (agent)
    return [agent.report, agent.prompt]
      .filter(Boolean)
      .map((text) => plainText(text!))
      .join("\n");
  const shell = tool.kind === "execute" && Boolean(tool.command);
  // A shell draws its output without Claude Code's leading "Exit code N" line (toolFailure.ts), which
  // its Shell block says once, at its end. Other output reads as ToolRow draws it: out of its envelope,
  // without injected context (toolResult.ts), and Markdown as its words, without the marks
  // (messageMenu.ts plainText).
  // A search's links line is its sources chip's, not its body's (webSourceList.ts withoutLinks).
  const called = shell ? undefined : callOutput(tool);
  const raw = called && withoutLinks(tool, called);
  const result = shell || !raw ? undefined : toolResult(raw, cleanText, strip, tool);
  // A finished read or file search draws its card: a read's lines, a search's files and matching
  // lines, never its input fields (FileResultCard.tsx).
  const card = shell || rowFailed(tool) ? undefined : fileCard(tool, result?.text);
  if (card) return [tool.title, fileCardText(card)].filter(Boolean).join("\n");
  const output = shell
    ? shellOutput(tool)
    : !result
      ? raw
      : result.lang === "markdown"
        ? plainText(result.text)
        : result.text;
  // A call that is not a shell or an edit opens to its input's fields, over its output when it has
  // any (ToolRow.tsx).
  const fields =
    !shell && opensToFields(tool, rowFailed(tool) ? toolFailure(tool) : undefined)
      ? inputFields(tool.inputSummary)
      : undefined;
  // The command as its rows draw it, without a leading `cd <folder> &&` (commandFolder).
  return [
    (tool.command && commandFolder(tool.command).rest) || tool.title,
    fields && fieldsText(fields, plainText),
    output,
  ]
    .filter(Boolean)
    .join("\n");
}

/** An MCP call a card draws instead of the MCP row (toolGroups.ts): a sub-session, a sent or
 * another agent's message. Its Raw keeps the request as it came, which Find reads. */
const drawnAsCard = (item: AcpmuxActivity, call: McpCall) =>
  Boolean(acpmuxMcpSends(item.tool!) || agentMessage(item.tool!) || subsessionCall(item.tool!, call));

/** A dispatch card's words, as DispatchCard.tsx draws them opened. */
const dispatchText = (call: DispatchCall) =>
  [
    call.title ?? call.briefId,
    call.text,
    call.summary !== call.text && call.summary,
    call.from,
    dispatchDestination(call),
    call.stopCondition,
    call.briefId,
  ]
    .filter(Boolean)
    .join("\n");

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

/// What a prompt's bubble draws depends on (bubbleParts.ts): the paste join. Its attachments draw
/// in the block above it in every attachment view, so the view changes nothing Find reads.
type PromptLook = { join: PasteJoin };
const promptLook = (): PromptLook => ({ join: experimentArm(sentPasteJoin) });
const lookKey = (look: PromptLook) => look.join;

/** What Find reads of a row: a prompt's or reply's text, or its tool calls'. Diffs come last, so
 * the drawn matches keep their order and a diff's match lands on the row's last drawn one. */
function rowText(row: AcpmuxRow, look: PromptLook): string | undefined {
  // A prompt its bubble draws in its parts' order: the words it draws, and a text file's body
  // where its chip opens to it (the chip opens to a match, InlinePromptContent.tsx PromptTextFile).
  // One whose parts are only for its bands draws its recorded text, as any prompt does, and a
  // Chief's draws its own bubble (ChiefPromptBubble.tsx), as the row's estimate reads it (model.ts).
  const parts = row.kind === "user" && row.from !== "chief" && !chiefEnvelope(row.text) ? bubbleParts(row) : undefined;
  if (parts) return drawnPromptText(parts, look.join);
  // A legacy prompt's inspector picks draw as their chips (PromptText.tsx PromptTyped): Find reads
  // their reports, not the names and fences they went with.
  if (row.kind === "user" && row.text && row.from !== "chief" && !chiefEnvelope(row.text))
    return sentPromptFindText(row.text);
  if (SEARCHED_KINDS.has(row.kind)) return row.text;
  if (!row.items?.length) return undefined;
  return [...row.items.map(drawnText), ...row.items.map(diffText)].join("\n");
}

// Rows are immutable snapshots. Keep the assembled, case-folded search text by row identity so
// typing a query does not rebuild every tool output and edit diff on every keystroke. A weak map
// lets old transcript snapshots disappear as virtualization/history replacement releases them.
// A prompt's text depends on how it draws (`PromptLook`), so the entry keeps the look it was read in.
const searchableTextCache = new WeakMap<AcpmuxRow, { look: string; text: string | undefined }>();

function searchableText(row: AcpmuxRow, look: PromptLook, key: string): string | undefined {
  const cached = searchableTextCache.get(row);
  if (cached?.look === key) return cached.text;
  const raw = rowText(row, look);
  const text = raw === undefined ? undefined : foldFind(raw);
  searchableTextCache.set(row, { look: key, text });
  return text;
}

/** Every match of `query` (case-insensitive) in the prompts, replies and work of `rows`, in order. */
export function findMatchesIncremental(
  rows: readonly AcpmuxRow[],
  query: string,
  previous?: FindMatchesCache,
): FindMatchesResult {
  const needle = foldFind(query);
  const look = promptLook();
  const key = lookKey(look);
  if (!needle) {
    return { matches: [], cache: { needle, look: key, rows, matches: [] }, scannedRows: 0 };
  }

  const same = previous?.needle === needle && previous.look === key;
  let prefix = 0;
  if (same) {
    while (prefix < rows.length && prefix < previous.rows.length && rows[prefix] === previous.rows[prefix]) prefix += 1;
  }

  if (same && prefix === rows.length && rows.length === previous.rows.length) {
    return { matches: previous.matches, cache: { needle, look: key, rows, matches: previous.matches }, scannedRows: 0 };
  }

  const matches = same ? previous.matches.filter(({ rowIndex }) => rowIndex < prefix) : [];
  for (let rowIndex = prefix; rowIndex < rows.length; rowIndex += 1) {
    const row = rows[rowIndex];
    const text = searchableText(row, look, key);
    if (!text) continue;
    let occurrence = 0;
    for (let at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length))
      matches.push({ rowIndex, rowId: row.id, occurrence: occurrence++ });
  }
  return { matches, cache: { needle, look: key, rows, matches }, scannedRows: rows.length - prefix };
}

export function findMatches(rows: readonly AcpmuxRow[], query: string): FindMatch[] {
  return findMatchesIncremental(rows, query).matches;
}

export type ChatFind = {
  open: boolean;
  query: string;
  /** The matches in the loaded rows, in order. */
  matches: FindMatch[];
  /** The index in `matches` of the current match; 0 when there are none; -1 while the current one
   * is an index hit in a turn not loaded yet (`pending`). */
  active: number;
  /** Where the reader is among every match, the index's hits in turns not loaded included (the
   * bar's "3 of 41"); 0 when there are none. */
  position: number;
  /** The loaded matches and the index's hits outside them. */
  total: number;
  /** The index is still answering, or the current hit's turn is paging in. */
  busy: boolean;
  /** The current index hit, while no loaded row holds it. */
  pending?: IndexHit;
  /** How far the daemon's index answered this query: `absent` when the chat has none (an older
   * acpmux, a host that does not relay it), and Find reads the loaded rows alone. */
  index: "none" | "searching" | "window" | "whole" | "absent";
  /** Opens the bar, with `text` as the query when given. Bumps `focusRequest`. */
  show: (text?: string) => void;
  /** Opens the bar on `query` with the match nearest `atMs` current (a `find:` reveal, findReveal.ts). */
  reveal: (find: FindRevealValue) => void;
  hide: () => void;
  setQuery: (query: string) => void;
  next: () => void;
  previous: () => void;
  /** Changes on each `show`, so the bar focuses its field again. */
  focusRequest: number;
};

/** What a find bar (ChatFindBar) reads: the chat's find, or another view's (the changes view). */
export type FindBarState = Omit<
  ChatFind,
  "matches" | "position" | "total" | "busy" | "pending" | "index" | "reveal"
> & {
  matches: readonly unknown[];
  /** Where the reader is among `total`, when that counts more than `matches` (the transcript index). */
  position?: number;
  total?: number;
  /** Still searching: no "No results" yet. */
  busy?: boolean;
};

/// No matches while the bar is closed: one value, so the find a closed bar hands the transcript
/// keeps its identity as the rows change (VirtualTranscript skips a render its props do not change).
const NO_MATCHES: FindMatch[] = [];
const NO_HITS: IndexHit[] = [];

/** The current step, kept by its key (FindStep.key); its hit and time find it again once it is gone. */
type CurrentStep = { key: string; hit?: IndexHit; at: number };
const stepIdentity = (step: FindStep): CurrentStep => ({
  key: step.key,
  at: step.at,
  ...(step.hit && { hit: step.hit }),
});

type IndexAnswerState = { key: string; hits: IndexHit[]; phase: "window" | "whole" | "absent" };

/** The newest of `hits` (an acpmux before `order` answers newest first). */
const newestHit = (hits: readonly IndexHit[]) =>
  hits.reduce<IndexHit | undefined>((best, hit) => (!best || hit.at > best.at ? hit : best), undefined);

/** The find state of a transcript of `rows`; `index` adds the daemon's hits in turns not loaded
 * (findIndex.ts). Without one, or when the daemon has no index, Find reads the loaded rows alone. */
export function useChatFind(rows: readonly AcpmuxRow[], index?: FindIndexSource): ChatFind {
  const [open, setOpen] = useState(false);
  const [query, setQueryState] = useState("");
  // The current step by its identity (FindStep.key), so it stays put as answers and pages land;
  // undefined while it is the default one.
  // With it, the hit the step was, so the match that stands for it is current once its turn lands,
  // and the step's time, so a match whose row went hands its place to the nearest one.
  const [currentStep, setCurrentStep] = useState<CurrentStep>();
  const currentKey = currentStep?.key;
  // A `find:` reveal's time: the default step is the one nearest it.
  const [near, setNear] = useState<number>();
  const [focusRequest, setFocusRequest] = useState(0);
  const [answer, setAnswer] = useState<IndexAnswerState>();
  // The hit whose turn is paging in.
  const [loading, setLoading] = useState<string>();
  const matchesCache = useRef<FindMatchesCache | undefined>(undefined);
  // While Find is open the pane draws every output update (ChatFindScope.tsx); a running
  // command's output from before it opened is in liveToolOutput.ts, not `rows`.
  const searched = useMemo(() => (open ? rowsWithLiveOutput(rows) : rows), [open, rows]);
  const matches = useMemo(() => {
    if (!open) return NO_MATCHES;
    const result = findMatchesIncremental(searched, query, matchesCache.current);
    matchesCache.current = result.cache;
    return result.matches;
  }, [open, searched, query]);
  // The newest rows and index for the asks below, written after render (a render may be discarded).
  const rowsNow = useRef(searched);
  const indexNow = useRef(index);
  useLayoutEffect(() => {
    rowsNow.current = searched;
    indexNow.current = index;
  }, [searched, index]);
  // Two asks per query once typing settles: the rows on screen first (`window`), drawn at once, then
  // the whole chat, page by page until a page's newest hit is loaded (the rest are newer still).
  // A newer query or another chat drops what an older ask answers.
  const searchKey = open && index && foldFind(query).trim() ? `${index.key}\u0000${query}` : undefined;
  useEffect(() => {
    const source = indexNow.current;
    if (!searchKey || !source) return;
    let live = true;
    const timer = setTimeout(() => {
      void (async () => {
        const window = source.window?.();
        if (window) {
          const first = await source.search({ query, window, limit: WINDOW_PAGE }).catch(() => undefined);
          if (!live) return;
          if (first) setAnswer({ key: searchKey, hits: mergeHits(first.hits), phase: "window" });
        }
        let hits: IndexHit[] = [];
        for (let page = 0; page < INDEX_PAGES; page++) {
          const read = await source
            .search({ query, limit: INDEX_PAGE, ...(page > 0 && { offset: page * INDEX_PAGE }) })
            .catch(() => undefined);
          if (!live) return;
          if (!read) {
            if (page === 0) return setAnswer({ key: searchKey, hits: [], phase: "absent" });
            break;
          }
          hits = mergeHits(hits, read.hits);
          const newest = newestHit(read.hits);
          const counted = read.total !== undefined && (page + 1) * INDEX_PAGE >= read.total;
          if (read.hits.length < INDEX_PAGE || counted || !newest || hitLoaded(newest, rowsNow.current, source)) break;
        }
        setAnswer({ key: searchKey, hits, phase: "whole" });
      })();
    }, INDEX_DEBOUNCE_MS);
    return () => {
      live = false;
      clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- one search per query and chat
  }, [searchKey]);
  const answered = answer !== undefined && answer.key === searchKey ? answer : undefined;
  const phase: ChatFind["index"] = !searchKey ? "none" : (answered?.phase ?? "searching");
  const hits = answered?.hits ?? NO_HITS;
  // The hits no loaded row holds: a loaded one is a local match already.
  const unloaded = useMemo(
    () => (hits.length && index ? hits.filter((hit) => !hitLoaded(hit, searched, index)) : NO_HITS),
    [hits, searched, index],
  );
  const steps = useMemo(() => findSteps(matches, searched, unloaded), [matches, searched, unloaded]);
  const settled = phase !== "searching" && phase !== "window";
  let position = currentKey === undefined ? -1 : steps.findIndex((step) => step.key === currentKey);
  if (position < 0 && currentStep !== undefined && steps.length) {
    const hit = currentStep.hit;
    position = hit ? landedStep(steps, hit, index?.rowsOfMessage) : nearestStep(steps, currentStep.at);
    if (position < 0) position = nearestStep(steps, hit?.at ?? 0);
  }
  if (currentKey === undefined && steps.length) {
    // The default: the step nearest a reveal's time, else the first loaded match (as before the
    // index), else the newest hit, the nearest to the loaded rows.
    const firstLoaded = steps.findIndex((step) => step.match);
    position = near !== undefined ? nearestStep(steps, near) : firstLoaded >= 0 ? firstLoaded : steps.length - 1;
  }
  position = Math.max(0, position);
  const current = steps[position];
  // The current step is kept by its key: once the answers are in, the default stays where it is as
  // more pages land, and a hit that landed hands its place to its match.
  useLayoutEffect(() => {
    if (!current || current.key === currentKey || (currentKey === undefined && !settled)) return;
    setCurrentStep(stepIdentity(current));
  }, [current, currentKey, settled]);
  // Stepping to a hit in a turn not loaded pages the transcript in through it (bounded); the match
  // that stands for it then becomes current, and the transcript scrolls to it as to any match.
  const pending = current?.hit;
  const pendingKey = pending ? current.key : undefined;
  const loadable = pendingKey !== undefined && (currentKey === pendingKey || settled);
  const asked = useRef(new Set<string>());
  useEffect(() => {
    asked.current = new Set();
  }, [searchKey]);
  useEffect(() => {
    const source = indexNow.current;
    if (!open || !pending || !pendingKey || !loadable || !source || asked.current.has(pendingKey)) return;
    asked.current.add(pendingKey);
    setLoading(pendingKey);
    void source
      .load(pending)
      .catch(() => false)
      .finally(() => setLoading((now) => (now === pendingKey ? undefined : now)));
    // eslint-disable-next-line react-hooks/exhaustive-deps -- one load per hit
  }, [open, pendingKey, loadable]);
  const busy = phase === "searching" || phase === "window" || (loading !== undefined && loading === pendingKey);
  const total = steps.length;
  const active = current?.match ? current.matchIndex : current ? -1 : 0;
  const stepsNow = useRef({ steps, position });
  useLayoutEffect(() => {
    stepsNow.current = { steps, position };
  }, [steps, position]);
  // Where focus was when the bar opened, so closing it puts the reader back there.
  const opener = useRef<HTMLElement | null>(null);
  const show = useCallback((text?: string) => {
    const focused = document.activeElement;
    if (focused instanceof HTMLElement && !focused.closest(".acpmux-find")) opener.current = focused;
    setOpen(true);
    if (text) {
      setQueryState(text);
      setCurrentStep(undefined);
      setNear(undefined);
    }
    setFocusRequest((request) => request + 1);
  }, []);
  const reveal = useCallback(
    (find: FindRevealValue) => {
      show(find.query);
      setNear(find.atMs);
    },
    [show],
  );
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
    setCurrentStep(undefined);
    setNear(undefined);
  }, []);
  // From the steps of this render (a ref), so the callbacks keep their identity as rows stream in.
  const step = useCallback((by: number) => {
    const { steps: all, position: at } = stepsNow.current;
    if (!all.length) return;
    setOpen(true);
    const to = all[(Math.min(at, all.length - 1) + by + all.length) % all.length]!;
    // A hit a bounded load stopped short of is asked for again when the reader steps to it again.
    asked.current.delete(to.key);
    setCurrentStep(stepIdentity(to));
  }, []);
  const next = useCallback(() => step(1), [step]);
  const previous = useCallback(() => step(-1), [step]);
  const shownPosition = total ? position : 0;
  return useMemo(
    () => ({
      open,
      query,
      matches,
      active,
      position: shownPosition,
      total,
      busy,
      ...(pending && { pending }),
      index: phase,
      show,
      reveal,
      hide,
      setQuery,
      next,
      previous,
      focusRequest,
    }),
    [
      open,
      query,
      matches,
      active,
      shownPosition,
      total,
      busy,
      pending,
      phase,
      show,
      reveal,
      hide,
      setQuery,
      next,
      previous,
      focusRequest,
    ],
  );
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
 * that absorbed it (turns.ts `mergeShortNotes`). A closed fold's line with only the step's calls
 * (`partial`) does not: the match may be in an edit it leaves to the edited-files card. */
export const isFindRow = (row: AcpmuxRow, rowId: string) =>
  (!row.ended && (row.id === rowId || Boolean(row.joined?.includes(rowId)))) ||
  (row.id === `${rowId}:fold` && !row.partial);

/** Whether `row` is the edited-files card (turns.ts) that merges edit `rowId`. */
const isCardOf = (row: AcpmuxRow, rowId: string) => Boolean(row.ended) && (row.merged ?? [row.id]).includes(rowId);

/** Whether `row` is the one `reveal` names. */
export const isRevealRow = (row: AcpmuxRow, reveal: Pick<FindRevealTarget, "rowId" | "card">) =>
  (row.id === reveal.rowId || Boolean(row.joined?.includes(reveal.rowId))) && Boolean(row.ended) === reveal.card;

/// The id suffix of the part of a run that ended after a prompt the person sent (turns.ts
/// `afterSends`): what was still going left its run for one under the prompt, which names the rows
/// it came from in `joined`.
export const AFTER_SEND = ":after:";

/** Where the transcript draws match row `rowId`: the row or its fold copy (isFindRow), else the
 * edited-files card that holds it (an edit after the answer is only there); -1 while hidden. A row a
 * prompt sent mid-turn split (AFTER_SEND) draws in two places: `holds` picks the one with the match.
 * Any other row draws in one place, the first, as before. */
export function findRowIndex(rows: readonly AcpmuxRow[], rowId: string, holds?: (row: AcpmuxRow) => boolean): number {
  const at = rows.findIndex((row) => isFindRow(row, rowId));
  if (at < 0) return rows.findIndex((row) => isCardOf(row, rowId));
  if (!holds || holds(rows[at]!)) return at;
  for (let next = at + 1; next < rows.length; next += 1)
    if (rows[next]!.id.includes(AFTER_SEND) && isFindRow(rows[next]!, rowId) && holds(rows[next]!)) return next;
  return at;
}

/** Whether `row`'s work holds `needle` (folded as Find folds it) or call `toolId`: the part of a
 * split row a match or a count's reveal goes to (findRowIndex). */
export const rowHolds =
  (target: { needle?: string; toolId?: string }) =>
  (row: AcpmuxRow): boolean =>
    target.toolId !== undefined
      ? Boolean(row.items?.some((item) => item.tool?.id === target.toolId))
      : target.needle
        ? Boolean(row.items?.some((item) => searchableActivityText(item).includes(foldFind(target.needle!))))
        : true;

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
  clearAdaptiveFind(FIND_HIGHLIGHT);
}

/**
 * Highlights `query` in the rows mounted under `root` (elements with `data-row-id`), and `active`
 * apart from the rest. A match that spans formatting (a bold word inside it) is not drawn. Returns
 * the active match's range when its row is mounted (its last match when the drawn text has fewer
 * than the row's text, such as a link's hidden address).
 */
/// Whether text in `element` is outside Find: under a `data-find-skip`, unless a `data-find-keep`
/// nearer to it brings it back (a tool's notice's title on its line, whose line is a summary that
/// Find skips: IncomingMessageCard.tsx).
export function findSkipped(element: Element | null | undefined): boolean {
  const skip = element?.closest("[data-find-skip]");
  if (!skip) return false;
  const keep = element?.closest("[data-find-keep]");
  return !keep || !skip.contains(keep);
}

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
        findSkipped(node.parentElement) ||
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
  paintAdaptiveFind(root.ownerDocument, FIND_HIGHLIGHT, CHAT_FIND_COLORS, all, current ? [current] : []);
  return current;
}
