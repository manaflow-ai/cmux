// The thread minimap's model: one tick per user message at the pane's left edge
// (the Codex desktop app's prompt rail). Pure functions, so geometry and previews need no DOM.
import { transcriptColumn, type AcpmuxRow } from "../model";
import { opensTurn } from "../turnStart";
import { MOTION_MS } from "../../../motion/scale.generated";

export type ReplySpan = { text: string; bold: boolean; code?: true };
export type ReplyBlock = { kind: "paragraph" | "item"; spans: ReplySpan[] };
export type MinimapTurnMetadata = {
  at: number;
  durationMs?: number;
  toolCount?: number;
  fileCount?: number;
  links: string[];
  failed?: boolean;
  failure?: string;
};
export type MinimapTurn = {
  /// The user row's index in the transcript rows (and in the layout's tops).
  index: number;
  id: string;
  /// The turn's stable key (turnKey): session id and the prompt's promptId, else its row id, since
  /// every session numbers its rows `user-<seq>` and a row's `at` is not stable across snapshots.
  /// Bookmarks use the row id's seq instead (bookmarks.ts), which acpmux checks against its log.
  key: string;
  /// The prompt, preserving its line breaks for the card's bounded three-line title.
  prompt: string;
  /// The start of the first reply after the prompt.
  reply: ReplyBlock[];
  metadata?: MinimapTurnMetadata;
};

/// The rail's geometry and timing, measured from 60 Hz recordings of the Codex desktop app's prompt
/// rail (lane notes: minimap-ref/SPEC.md). CSS px and ms; the drawn sizes live in threadMinimap.css.
/// The rail shows from this many prompts...
export const MIN_PROMPTS = 4;
/// One row per prompt: a fixed 10 px pitch (not proportional to the thread), 36 px wide to hit.
export const ROW_PITCH = 10;
export const ROW_WIDTH = 36;
/// The tick's line box; a tick draws `tickLength(progress)` of it from the left.
export const TICK_BOX = 26;
/// Pure pane-edge geometry. CSS spacing tokens are read by useRailPlacement, once per layout change.
/// The inset is the widest spacing step whenever the pane's own gutter leaves the full rail room for
/// it, so a pane that only grows or shrinks (the sidebar toggle) never moves the rail; it shrinks
/// toward the narrowest step only once that gutter runs short (Leo, 2026-11-01: "the left side scroll
/// rail needs to not really get affected by most other layout things it shouldn't really shift much
/// at all"). It reads the pane's width, never the chat column's (`textInset`), so Session Info pushing
/// the column does not move it either; the column only compresses or occludes the rail.
export function railPlacement(
  paneWidth: number,
  textInset = transcriptColumn(paneWidth).inset,
  spacing: { min: number; max: number; compact: number; narrowest?: number } = { min: 8, max: 16, compact: 12 },
): { left: number; width: number; overlapsText: boolean; gutter: number } {
  const paneInset = transcriptColumn(paneWidth).inset;
  const left = Math.min(spacing.max, Math.max(spacing.min, Math.floor(paneInset - ROW_WIDTH)));
  // The narrowest hit width: the compact step for the tight gutter (gutter.experiment.ts), so the
  // resting rail fits the page edge; the inset plus that step for the edge strip.
  const minimumWidth = spacing.narrowest ?? spacing.min + spacing.compact;
  const width = Math.min(ROW_WIDTH, Math.max(minimumWidth, textInset - left));
  // `gutter` is the text's own inset, so the occluded rail's hover strip can stop at the text edge.
  return { left, width, overlapsText: left + width > textInset, gutter: Math.max(0, textInset) };
}
/// Height choices for the compact rail. The initial height keeps a short thread from looking like a
/// transcript slice; the share and row cap let a long thread grow toward the pane's full height before
/// its own list scrolls. The gallery compares these arms; the selected default is the middle ground.
export type RailHeightConfig = { initial: number; maxRows: number; maxShare: number };
export const RAIL_HEIGHTS = {
  "initial-240-max-80": { initial: 240, maxRows: 96, maxShare: 0.8 },
  "initial-320-max-92": { initial: 320, maxRows: 128, maxShare: 0.92 },
  "initial-400-max-96": { initial: 400, maxRows: 160, maxShare: 0.96 },
  "initial-480-max-full": { initial: 480, maxRows: 200, maxShare: 1 },
} as const satisfies Record<string, RailHeightConfig>;
export type RailHeightArm = keyof typeof RAIL_HEIGHTS;
export const DEFAULT_RAIL_HEIGHT: RailHeightArm = "initial-320-max-92";
/// The fisheye by row distance from the hovered (or scrubbed) row: 26, 20, 14, 10, then 6 px.
const PROGRESS = [1, 0.7, 0.4, 0.2] as const;
/// Space kept free above and below the card inside the transcript's viewport.
export const EDGE_MARGIN = 8;
/// A jump lands the top of the prompt's row (its sent images, else its bubble) this far below the
/// top of the transcript's viewport.
export const LANDING_OFFSET = 35;
/// The transcript thread's top padding (.acpmux-thread): row tops start this far down the scroller.
export const THREAD_PADDING_TOP = 16;
/// A bookmark jump's smooth scroll (Codex's Chromium smooth scroll, fitted), and a Previous or Next
/// Turn step's. A click on the rail lands at once (ThreadMinimap.tsx `jump`).
export const JUMP_CURVE = [0.35, 0.05, 0, 1] as const;
export const STEP_CURVE = [0.3, 0.2, 0, 1] as const;
export const STEP_MS = MOTION_MS.standard;
/// The preview card opens on the frame the pointer reaches the rail, with no dwell and no fade (Leo,
/// 2026-10-29: "giving it faster scrttoll/hover over"; rulebook: the rail is "ultra fast ultra
/// responsive"). The rail is a deliberate target at the pane's edge, and the card is the point of
/// hovering it; it was Codex's 250 ms `delayOpen`. The app's other hover cards keep their dwell
/// (ui/hoverIntent.ts).
export const CARD_DELAY = 0;
/// When older turns load above the rail's rows and move them, the rail glides back over this long.
export const SHIFT_MS = MOTION_MS.standard;
/// A jump keeps correcting its landing for up to this many frames while the rows it crossed measure.
export const SETTLE_FRAMES = 45;
/// The landing highlight on the prompt's bubble.
export const HIGHLIGHT_MS = 1400;
export const HIGHLIGHT_EASING = "cubic-bezier(0.23, 1, 0.32, 1)";
/// Blocks of a reply the preview keeps (the card clamps to four lines).
const PREVIEW_BLOCKS = 4;
const PREVIEW_CHARS = 360;
const METADATA_TEXT_LIMIT = 1024;
const PR_LINK = /https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+(?:#[\w.-]+)?/g;

/// How magnified a row is (0 to 1) at `distance` rows from the hovered one; undefined is no hover.
export function tickProgress(distance: number | undefined): number {
  if (distance === undefined) return 0;
  return PROGRESS[Math.abs(distance)] ?? 0;
}

/// The drawn length of a tick at `progress`: 6 px at rest, 26 px hovered.
export const tickLength = (progress: number) => TICK_BOX * (0.2308 + 0.7692 * progress);

/// The transcript's soft edges (conversation.css `.acpmux-scroll[data-fade-*]`): its mask fades
/// rows out over this many px under the top once scrolled from the start, and above the view's foot
/// (the bottom stack's top) while more lies below. The composer edge is always 18 px, including
/// while Jump to latest shows: that control keeps its own glass and does not widen the transcript mask.
/// The rail is inside the scroller, so the mask fades it too: its rows stay clear of both bands, at
/// the widest they get, so the rail never moves as the bands come and go. A test reads the CSS.
export const TRANSCRIPT_FADE_TOP = 18;
export const TRANSCRIPT_FADE_BOTTOM = 18;
/// Where the rail's rows may sit, in px down the transcript's viewport: clear of the mask's bands by
/// EDGE_MARGIN's half. `foot` is where the mask's view ends (the bottom stack's top), when it is
/// above `viewportHeight` (a composer grown while the view follows the latest row).
export function railRoom(viewportHeight: number, foot = viewportHeight): { top: number; bottom: number } {
  const clear = EDGE_MARGIN / 2;
  return {
    top: TRANSCRIPT_FADE_TOP + clear,
    bottom: Math.min(viewportHeight, foot) - TRANSCRIPT_FADE_BOTTOM - clear,
  };
}

/// The rail's height for `count` rows in a window `windowHeight` tall: every row up to 64 rows or
/// 70% of the window, after which the rows scroll. It fits the room the transcript gives it
/// (railRoom: its viewport less the mask's bands), so a short pane's rows all scroll into view and no
/// tick sits under the transcript's fades (Leo 2026-10-22: "it wouldn't show the highlighted bottom
/// ... it just didn't go to the bottom"). It is never shorter than the band, the `band` prompts on
/// screen: in a pane too short for both, the mask's clearance gives way first, up to the whole view.
export function railHeight(
  count: number,
  windowHeight: number,
  viewportHeight = windowHeight,
  foot = viewportHeight,
  band = 1,
  config: RailHeightConfig = RAIL_HEIGHTS[DEFAULT_RAIL_HEIGHT],
): number {
  if (count <= 0) return 0;
  const room = railRoom(viewportHeight, foot);
  const height = Math.min(
    Math.max(count * ROW_PITCH, config.initial),
    config.maxRows * ROW_PITCH,
    Math.floor(windowHeight * config.maxShare),
    // A transcript not measured yet (0) does not cap it.
    viewportHeight > 0 ? Math.max(0, Math.floor(room.bottom - room.top)) : Infinity,
  );
  const need = Math.min(count, Math.max(1, band)) * ROW_PITCH;
  const view = viewportHeight > 0 ? Math.floor(Math.min(viewportHeight, foot)) : Infinity;
  return Math.max(0, height >= need ? height : Math.min(need, view));
}

/// The rail's top in the transcript's viewport: centered on it, as the Codex rail is, then moved as
/// little as it takes to keep the rail inside railRoom. A rail taller than that room (a tiny pane,
/// railHeight) centers on it, inside the view.
export function railTop(height: number, viewportHeight: number, foot = viewportHeight): number {
  const room = railRoom(viewportHeight, foot);
  const centered = Math.round((viewportHeight - height) / 2);
  if (viewportHeight <= 0) return centered;
  if (room.bottom - height >= room.top) return Math.max(room.top, Math.min(centered, Math.floor(room.bottom - height)));
  const view = Math.min(viewportHeight, foot);
  return Math.max(0, Math.min(Math.round((room.top + room.bottom - height) / 2), Math.floor(view - height)));
}

/// The fade a rail longer than its room draws at an edge with more rows past it: 2.5rem
/// (threadMinimap.css `.acpmux-minimap__list[data-fade-*]`), and at most a quarter of a short rail.
export const RAIL_FADE = 40;
export const railFade = (height: number) => Math.max(0, Math.min(RAIL_FADE, Math.floor(height / 4)));

/// Which of the list's edge fades draw at offset `top`: an edge with more rows past it fades, unless
/// the fade would lie over the band (the prompts on screen), which always draws in full ink.
export function railFades(
  band: { first: number; last: number },
  count: number,
  height: number,
  top: number,
): { top: boolean; bottom: boolean } {
  const fade = railFade(height);
  return {
    top: top > 0 && band.first * ROW_PITCH - top >= fade,
    bottom: count * ROW_PITCH - top - height > 1 && (band.last + 1) * ROW_PITCH - top <= height - fade,
  };
}

/// Where the rail's list scrolls (its `scrollTop`) so the band, the prompts on screen (`first` to
/// `last`), shows whole and clear of the fades: `current` while it already does; else the band's
/// first row a third of the way down, as the Codex rail puts it, moved as little as it takes to show
/// the whole band. In a rail too short for the band and the fades, the fades give way (railFades)
/// and the band still shows whole. A band taller than the rail shows its first row, or its last when
/// it holds the chat's last prompt. A band that holds the chat's last prompt scrolls the list to its
/// end, which draws no bottom fade, so at the bottom of the chat the bottom ticks show lit (Leo
/// 2026-10-22: "it wouldn't show the highlighted bottom ... it just didn't go to the bottom").
export function railScrollTop(
  band: { first: number; last: number },
  count: number,
  height: number,
  current: number,
): number {
  const room = Math.max(0, count * ROW_PITCH - height);
  if (room === 0) return 0;
  const clamp = (value: number) => Math.max(0, Math.min(room, value));
  // The offsets that show the band whole: with the fades clear of it (the inner pair), or at all.
  // An edge row of the list needs no clearance: the list at that end draws no fade there.
  const highest = band.first * ROW_PITCH;
  const lowest = (band.last + 1) * ROW_PITCH - height;
  if (lowest > highest) return clamp(band.last >= count - 1 ? room : highest);
  if (band.last >= count - 1) return room;
  const fade = railFade(height);
  const clearHighest = highest - (band.first > 0 ? fade : 0);
  const clearLowest = lowest + fade;
  const [low, high] = clearLowest <= clearHighest ? [clearLowest, clearHighest] : [lowest, highest];
  if (current >= low && current <= high) return clamp(current);
  return clamp(Math.min(high, Math.max(low, band.first * ROW_PITCH - height / 3)));
}

/// The card's top for a row centered at `center`: centered on it, kept inside the viewport.
export function cardOffset(center: number, cardHeight: number, viewportHeight: number): number {
  const top = center - cardHeight / 2;
  const max = viewportHeight - EDGE_MARGIN - cardHeight;
  return Math.max(EDGE_MARGIN, Math.min(top, max));
}

/// How long a bookmark jump's smooth scroll takes for `distance` px: about 200 ms for 150 px up to 400 ms
/// for 650 px and more, as the recorded Chromium scrolls took.
export function jumpDuration(distance: number): number {
  const share = Math.min(1, Math.max(0, (Math.abs(distance) - 150) / 500));
  return Math.round(200 + 200 * share);
}

/// Each prompt's turn and the reply it previews, by row object: rows are immutable, so a long
/// chat's snapshot hashes and previews only the turns that changed.
const turnsByPrompt = new WeakMap<AcpmuxRow, { turn: MinimapTurn; sessionId: string; reply?: AcpmuxRow }>();

type CardState = { metadata: MinimapTurnMetadata; files: ReadonlySet<string> };
type CardContribution = {
  version: number;
  shape: string;
  before?: CardState;
  state: CardState;
  paths?: readonly string[];
};
// Contributions join during the existing row walk. An unchanged row and prefix reuse the whole
// state, including its sets. turnView recreates live activity wrappers: source id/version, rather
// than the wrapper's identity, keeps those contributions stable across reply tokens. Each prompt
// owns one entry per row, replaced on revision; releasing the prompt releases the cache.
const cardStates = new WeakMap<AcpmuxRow, Map<string, CardContribution>>();
const noFiles: ReadonlySet<string> = new Set();

function cardState(prompt: AcpmuxRow, row: AcpmuxRow, before?: CardState): CardState {
  let contributions = cardStates.get(prompt);
  if (!contributions) cardStates.set(prompt, (contributions = new Map()));
  const previous = contributions.get(row.id);
  // Live runs and an ended turn's merged edits use different version arithmetic; the same numeric
  // revision can name both. Their drawn shape separates those contributions without reading items.
  const shape = `${row.kind}:${row.ended ?? ""}:${row.foldRun ?? ""}:${row.settled ?? ""}`;
  const cached = previous?.version === row.version && previous.shape === shape ? previous : undefined;
  if (cached && cached.before === before) return cached.state;
  let state = before ?? { metadata: { at: row.at, links: [] }, files: noFiles };
  let metadata = state.metadata;
  let files = state.files;
  // A link discovered in a still-streaming reply is not stable yet. Read only its bounded prefix
  // once it finishes; prompts are immutable and the row cache reads their links once.
  if (!before || (row.kind === "assistant" && !row.streaming)) {
    const links = [...(row.text ?? "").slice(0, METADATA_TEXT_LIMIT).matchAll(PR_LINK)].map((match) => match[0]);
    const added = links.filter((link) => !metadata.links.includes(link));
    if (added.length) metadata = { ...metadata, links: [...metadata.links, ...new Set(added)] };
  }
  let paths = cached?.paths;
  if (row.kind === "activity") {
    if (!paths) {
      paths = (row.items ?? []).flatMap((item) => item.tool?.diffs?.map((diff) => diff.canonical ?? diff.path) ?? []);
    }
    if (paths.some((path) => !files.has(path))) {
      files = new Set([...files, ...paths]);
      metadata = { ...metadata, fileCount: files.size };
    }
  }
  const failure = row.error || row.delivery?.error || row.delivery?.reason;
  const failed =
    row.failed ||
    row.delivery?.state === "failed" ||
    (row.kind === "turnSummary" && (row.status === "failed" || row.status === "error"));
  if (row.kind === "turnSummary" || (!before && (failure || failed)))
    metadata = {
      ...metadata,
      ...(row.durationMs !== undefined && { durationMs: row.durationMs }),
      ...(row.toolCount !== undefined && { toolCount: row.toolCount }),
      ...(failed && { failed: true }),
      ...(failure && { failure }),
    };
  if (metadata !== state.metadata || files !== state.files) state = { metadata, files };
  contributions.set(row.id, { version: row.version, shape, before, state, paths });
  return state;
}

/// What a turn's tick on the rail shows: its prompt, by key. A tick changes only when its prompt
/// does, not when the reply it previews streams on.
export type MinimapTick = Pick<MinimapTurn, "key" | "id" | "prompt">;

/// The turns of `rows`, the ticks they draw, and the rows they were read from.
export type MinimapTurns = {
  rows: readonly AcpmuxRow[];
  sessionId: string;
  turns: readonly MinimapTurn[];
  ticks: readonly MinimapTick[];
  /// Prompts indexed by the rail but not materialized in the transcript yet.
  earlierRows?: readonly AcpmuxRow[];
  /// The loaded portion is kept separately so prepending indexed prompts never changes the
  /// incremental O(changed rows) work for a streamed reply.
  loadedTurns?: readonly MinimapTurn[];
  loadedTicks?: readonly MinimapTick[];
  loadedStart?: number;
  earlierTurns?: readonly MinimapTurn[];
  /// The list the next changed turns are written into (the one before `turns`), never `turns`.
  spare?: MinimapTurn[];
};

/// For a list the next turns are written into, the list whose first `same` turns it holds.
const agreed = new WeakMap<readonly MinimapTurn[], { list: readonly MinimapTurn[]; same: number }>();

/// Where a rows snapshot first differs (by object) from the one before it, as the transcript finds
/// it once per snapshot for everything that reads the rows (VirtualTranscript's arriving rows): the
/// rows before `from` in `rows` are the rows of `base`.
export type RowsChange = { base: readonly AcpmuxRow[]; rows: readonly AcpmuxRow[]; from: number };
const EMPTY_EARLIER_ROWS: readonly AcpmuxRow[] = [];

/// The transcript's turns. A turn that ends before the first row that differs from
/// `previous.rows` (by object) is kept, and `turns` stays `previous.turns` when every turn is.
/// `ticks` stays `previous.ticks` while the prompts are the same, so a token streaming into a reply
/// leaves the rail's ticks alone (ThreadMinimap draws them from `ticks`). Only the turns from the
/// first changed one on are read and compared: the ones before it are the previous ones.
///
/// `change`, when it is the step from `previous.rows` to `rows`, gives where they first differ, so a
/// streamed token reads only the live turn's rows, however long the chat (#24058 review round 4).
/// Without it (another session, a first read, a step the transcript did not see) the rows are
/// compared from the start.
///
/// `previous` is left as it was: React can render with the next rows and drop that render, and the
/// committed result must still be the rows it shows (#24058 review round 6). Changed turns go into
/// `previous.spare`, the list before `previous.turns`, which holds every turn up to where the two
/// last differed, so a streamed token writes the live turn alone and copies none of the others. The
/// result before `previous` is spent: pass the committed result, or one read from it.
export function minimapTurns(
  rows: readonly AcpmuxRow[],
  sessionId = "",
  previous?: MinimapTurns,
  change?: RowsChange,
  earlierRows: readonly AcpmuxRow[] = EMPTY_EARLIER_ROWS,
): MinimapTurns {
  const prior = previous?.sessionId === sessionId ? previous : undefined;
  const reuse = prior
    ? {
        ...prior,
        turns: prior.loadedTurns ?? prior.turns.filter((turn) => turn.index >= 0),
        ticks: prior.loadedTicks ?? prior.ticks.filter((_, index) => prior.turns[index]?.index >= 0),
      }
    : undefined;
  let from = 0;
  if (reuse && change && change.base === reuse.rows && change.rows === rows) from = change.from;
  else if (reuse) while (from < rows.length && from < reuse.rows.length && rows[from] === reuse.rows[from]) from += 1;
  // A kept turn's rows all come before `from`: the next turn's prompt is before it (a row
  // inserted at that prompt's index joins the turn before). The turns are in row order: the last
  // turn that starts before `from` is the first one read again.
  let keep = 0;
  if (reuse) {
    let low = 0;
    let high = reuse.turns.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (reuse.turns[middle]!.index < from) low = middle + 1;
      else high = middle;
    }
    keep = Math.max(0, Math.min(reuse.turns.length - 1, low - 1));
  }
  // The turns read again, from `keep` on. The ones before are `reuse.turns`' own, never copied.
  const tail: MinimapTurn[] = [];
  let user: AcpmuxRow | undefined;
  let userIndex = 0;
  let reply: AcpmuxRow | undefined;
  let details: CardState | undefined;
  const close = () => {
    if (!user) return;
    const kept = turnsByPrompt.get(user);
    const same = kept && kept.sessionId === sessionId && kept.turn.index === userIndex;
    const nextMetadata = details?.metadata;
    const sameReply =
      same &&
      (kept.reply === reply ||
        (reply?.text && kept.reply?.text && samePreview(kept.turn.reply, replyPreview(reply.text))));
    if (sameReply && kept.turn.metadata === nextMetadata) {
      // A reply streamed on past its preview (replyPreview stops once the preview is full): the
      // turn is the same, so the list of turns can be too.
      kept.reply = reply;
      tail.push(kept.turn);
    } else {
      const turn: MinimapTurn = {
        index: userIndex,
        id: user.id,
        key: turnKey(sessionId, user),
        // Keep explicit prompt line breaks for the hover card; its CSS clamps the title without
        // changing what the person wrote. Spaces are normalized by white-space: pre-line there.
        prompt: (user.text ?? "").trim(),
        reply: sameReply ? kept.turn.reply : reply?.text ? replyPreview(reply.text) : [],
        metadata: nextMetadata,
      };
      turnsByPrompt.set(user, { turn, sessionId, reply });
      tail.push(turn);
    }
    user = undefined;
    reply = undefined;
    details = undefined;
  };
  const start = keep < (reuse?.turns.length ?? 0) ? reuse!.turns[keep]!.index : 0;
  for (let index = reuse && keep > 0 ? start : 0; index < rows.length; index += 1) {
    const row = rows[index]!;
    // A steer goes on with its turn (turnStart.ts): it starts no minimap turn.
    if (opensTurn(row)) {
      close();
      user = row;
      userIndex = index;
      details = cardState(row, row);
    } else if (user) {
      if (!reply && row.kind === "assistant" && row.text) {
        reply = row;
        details = cardState(user, row, details);
      }
      if (row.kind === "activity" || row.kind === "turnSummary") details = cardState(user, row, details);
    }
  }
  close();
  const old = reuse?.turns;
  const oldTicks = reuse?.ticks;
  const length = keep + tail.length;
  let sameTurns = old !== undefined && old.length === length;
  let sameTicks = oldTicks !== undefined && oldTicks.length === length;
  for (let at = 0; at < tail.length && (sameTurns || sameTicks); at += 1) {
    const turn = tail[at]!;
    if (old?.[keep + at] !== turn) sameTurns = false;
    const tick = oldTicks?.[keep + at];
    // A tick keeps its key (its turn's, or that and its row: ticksOf) while its turn does.
    if ((tick?.key !== turn.key && tick?.key !== repeatKey(turn)) || tick.prompt !== turn.prompt || tick.id !== turn.id)
      sameTicks = false;
  }
  // Changed turns go into the spare list, never into `old`: it holds `old`'s turns up to where the
  // two last differed, so a streamed token whose reply preview is still filling writes the live turn
  // alone, not a copy of every turn (#24058 review round 5), and `previous` stays the committed rows'
  // (round 6). A dropped render wrote only the spare, and its agreement says how far it still holds.
  // The indexed prompts older than the held rows go first, as turns with no row (index -1), so the
  // rail lays out every turn from the first frame. The combined list is a new array whenever the
  // earlier or the loaded turns change, never one a committed result still holds: the loaded turns'
  // own lists stay `spare`'s alone. With no earlier prompts the loaded lists are the result's.
  const withEarlier = (
    loadedTurns: readonly MinimapTurn[],
    loadedTicks: readonly MinimapTick[],
    spare?: MinimapTurn[],
  ): MinimapTurns => {
    const base = { rows, sessionId, loadedTurns, loadedTicks, ...(spare ? { spare } : {}) };
    if (!earlierRows.length) return { ...base, turns: loadedTurns, ticks: loadedTicks, loadedStart: 0 };
    const sameEarlier = prior?.earlierRows === earlierRows && prior.earlierTurns !== undefined;
    if (sameEarlier && prior!.loadedTurns === loadedTurns && prior!.loadedTicks === loadedTicks)
      return { ...prior!, ...base };
    const earlier = sameEarlier
      ? prior!.earlierTurns!
      : earlierRows.map((row): MinimapTurn => ({
          index: -1,
          id: row.id,
          key: turnKey(sessionId, row),
          prompt: (row.text ?? "").trim(),
          reply: [],
        }));
    const turns = [...earlier, ...loadedTurns];
    return {
      ...base,
      turns,
      // A token streaming into a reply leaves the prompts, and so the ticks, as they were.
      ticks: sameEarlier && prior!.loadedTicks === loadedTicks ? prior!.ticks : ticksOf(turns, prior?.ticks),
      earlierRows,
      earlierTurns: earlier,
      loadedStart: earlier.length,
    };
  };
  if (!old) {
    const loaded = ticksOf(tail, oldTicks);
    return withEarlier(tail, loaded);
  }
  if (sameTurns) return withEarlier(old, sameTicks ? oldTicks! : ticksOf(old, oldTicks), reuse!.spare);
  const list = reuse!.spare ?? [];
  const agreement = agreed.get(list);
  for (let at = agreement?.list === old ? Math.min(agreement.same, keep) : 0; at < keep; at += 1) list[at] = old[at]!;
  list.length = keep;
  for (const turn of tail) list.push(turn);
  agreed.set(list, { list: old, same: keep });
  agreed.set(old, { list, same: keep });
  const loaded = sameTicks ? oldTicks! : ticksOf(list, oldTicks);
  return withEarlier(list, loaded, old as MinimapTurn[]);
}

/// A turn's key: its prompt's promptId, which the row keeps from the moment this pane sends it
/// (`local-<promptId>`, its delivery's) through acpmux's echo (`user-<seq>`) and every later read of
/// the history (the `user_message` record's), else its row id. Never the prompt's text, which the
/// row can show differently once more is known (a sender's address line, incomingMessage.ts): the
/// tick stays one element and a jump or step that looks a turn up by key still finds it (Leo
/// 2026-10-25: "my latest prompt that I sent in ... should be able to go in at the bottom as well").
///
/// A send that failed keys on its row: acpmux may still have taken it (a send that timed out), and
/// the failed row stays beside acpmux's echo of it, anywhere in the list once the log is read again,
/// so only the echo holds the promptId and every tick's key is its own.
export function turnKey(sessionId: string, user: AcpmuxRow): string {
  const promptId = user.promptId ?? (user.delivery?.state === "failed" ? undefined : user.delivery?.promptId);
  return `${sessionId}#${promptId ? `prompt-${promptId}` : user.id}`;
}

/// Whether two reply previews are the same blocks and spans.
function samePreview(a: readonly ReplyBlock[], b: readonly ReplyBlock[]): boolean {
  if (a.length !== b.length) return false;
  return a.every((block, index) => {
    const other = b[index]!;
    return (
      block.kind === other.kind &&
      block.spans.length === other.spans.length &&
      block.spans.every(
        (span, at) =>
          span.text === other.spans[at]!.text &&
          !!span.bold === !!other.spans[at]!.bold &&
          !!span.code === !!other.spans[at]!.code,
      )
    );
  });
}

/// A tick's key when its turn's key is already taken: the turn's key and its row id.
const repeatKey = (turn: Pick<MinimapTurn, "key" | "id">) => `${turn.key}#${turn.id}`;

/// Each turn's tick, the previous one where its prompt is the same. Every tick's key is its own (the
/// list's key, and the rail's focus, hover and card maps), and a tick keeps the key it had: two turns
/// can share a key (a retried send beside acpmux's echo of it, one promptId), and the one that had it
/// first keeps it wherever the other arrives (an older echo read in above it); the other keys on its
/// row too. Built when the ticks change (a new prompt, older turns), never per token.
function ticksOf(turns: readonly MinimapTurn[], previous: readonly MinimapTick[] = []): MinimapTick[] {
  const had = new Map(previous.map((tick) => [tick.id, tick.key]));
  const keys: (string | undefined)[] = [];
  const taken = new Set<string>();
  // The keys the ticks already had, first.
  turns.forEach((turn, index) => {
    const key = had.get(turn.id);
    if (key === undefined || (key !== turn.key && key !== repeatKey(turn)) || taken.has(key)) return;
    keys[index] = key;
    taken.add(key);
  });
  return turns.map((turn, index) => {
    let key = keys[index];
    if (key === undefined) {
      key = taken.has(turn.key) ? repeatKey(turn) : turn.key;
      taken.add(key);
    }
    const tick = previous[index];
    return tick && tick.key === key && tick.prompt === turn.prompt && tick.id === turn.id
      ? tick
      : { key, id: turn.id, prompt: turn.prompt };
  });
}

/// The turn the reader is in: the last prompt above a third of the way down the viewport.
export function currentTurn(
  turns: readonly MinimapTurn[],
  tops: Float64Array,
  scrollTop: number,
  viewportHeight: number,
  firstLoaded = 0,
): number {
  if (firstLoaded >= turns.length) return 0;
  const anchor = scrollTop + viewportHeight / 3;
  let low = 0;
  let high = turns.length;
  low = firstLoaded;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if ((tops[turns[middle].index] ?? 0) <= anchor) low = middle + 1;
    else high = middle;
  }
  return Math.max(firstLoaded, low - 1);
}

/// The turns on screen, first to last, as the Codex rail's IntersectionObserver sees them. Codex
/// observes each turn's block, which starts LANDING_OFFSET (35 px) above its prompt's bubble (a jump
/// puts the block's top at the view's top and the bubble 35 px down), with a -16 px top margin. So a
/// turn stops counting once the next prompt's bubble is within 35 + 16 px of the top: a prompt just
/// jumped to is the first lit turn, not the one above it. A bubble draws THREAD_PADDING_TOP below its
/// layout top, so that is a layout top at or above `scrollTop + LANDING_OFFSET`. At the bottom a turn
/// counts once its bubble is on screen: our turns have no block above the bubble to show first.
export function visibleTurns(
  turns: readonly MinimapTurn[],
  tops: Float64Array,
  totalHeight: number,
  scrollTop: number,
  viewportHeight: number,
  firstLoaded = 0,
): { first: number; last: number } {
  if (firstLoaded >= turns.length) return { first: 0, last: 0 };
  const bottom = scrollTop + viewportHeight - THREAD_PADDING_TOP;
  const first = currentTurn(turns, tops, scrollTop + LANDING_OFFSET, 0, firstLoaded);
  let last = first;
  while (last + 1 < turns.length && (tops[turns[last + 1].index] ?? totalHeight) < bottom) last += 1;
  return { first, last };
}

/// The scroll offset that lands a turn's prompt row (its images, else its bubble) LANDING_OFFSET
/// below the viewport's top.
export function turnScrollTop(turn: MinimapTurn, tops: Float64Array): number {
  return Math.max(0, THREAD_PADDING_TOP + (tops[turn.index] ?? 0) - LANDING_OFFSET);
}

/// The start of a reply as blocks with bold/code spans; fenced code, heading marks and link targets drop.
export function replyPreview(markdown: string): ReplyBlock[] {
  const blocks: ReplyBlock[] = [];
  let chars = 0;
  let fenced = false;
  let paragraph: string[] = [];
  const push = (kind: ReplyBlock["kind"], text: string) => {
    if (blocks.length >= PREVIEW_BLOCKS || chars >= PREVIEW_CHARS) return;
    const spans = inlineSpans(text.slice(0, PREVIEW_CHARS - chars));
    if (!spans.length) return;
    chars += spans.reduce((sum, span) => sum + span.text.length, 0);
    blocks.push({ kind, spans });
  };
  const flush = () => {
    if (paragraph.length) push("paragraph", paragraph.join(" "));
    paragraph = [];
  };
  // A streaming reply previews again on every token: stop reading once the preview is full, and
  // read line by line instead of splitting the whole reply.
  for (let start = 0; start <= markdown.length;) {
    if (blocks.length >= PREVIEW_BLOCKS || chars >= PREVIEW_CHARS) break;
    const newline = markdown.indexOf("\n", start);
    const end = newline < 0 ? markdown.length : newline;
    const line = markdown.slice(start, end).trim();
    start = end + 1;
    if (/^(```|~~~)/.test(line)) {
      flush();
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    if (!line || /^([-*_])\1{2,}$/.test(line) || line.startsWith("|")) {
      flush();
      continue;
    }
    const item = /^(?:[-*+]|\d+[.)])\s+(.*)$/.exec(line);
    if (item) {
      flush();
      push("item", item[1]);
      continue;
    }
    const heading = /^#{1,6}\s+(.*)$/.exec(line);
    if (heading) {
      flush();
      push("paragraph", heading[1]);
      continue;
    }
    paragraph.push(line.replace(/^>\s?/, ""));
  }
  flush();
  return blocks;
}

function inlineSpans(text: string): ReplySpan[] {
  const plain = (value: string) =>
    value.replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/(^|[^\w*])[*_]([^*_\s][^*_]*?)[*_](?=[^\w*]|$)/g, "$1$2");
  const spans: ReplySpan[] = [];
  const add = (value: string, bold: boolean, code = false) => {
    const clean = code ? value : plain(value);
    if (!clean) return;
    const last = spans.at(-1);
    if (last && last.bold === bold && !!last.code === code) last.text += clean;
    else spans.push({ text: clean, bold, ...(code && { code: true }) });
  };
  const tokens = /(`+)(.*?)\1|(\*\*|__)(.+?)\3/g;
  let at = 0;
  for (let match = tokens.exec(text); match; match = tokens.exec(text)) {
    add(text.slice(at, match.index), false);
    add(match[1] ? match[2] : match[4], !match[1], !!match[1]);
    at = match.index + match[0].length;
  }
  add(text.slice(at), false);
  return spans;
}
