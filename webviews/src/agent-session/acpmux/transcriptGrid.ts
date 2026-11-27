// The virtual stack reads the same declarative lengths as the generated CSS grid tokens.
import grid from "../../../../schemas/layout-grid/layout-grid.json";

export const gridLength = (name: string): number => {
  const metric = grid.metrics.find((value) => value.name === name);
  // l10n-allow: a developer invariant on the bundled grid schema; it fails at load, never in front of a person.
  if (!metric) throw new Error(`Missing layout grid metric: ${name}`);
  return metric.pt;
};
export const TRANSCRIPT_BLOCK_GAP = gridLength("gap-block");
export const TRANSCRIPT_INNER_GAP = gridLength("gap-inner");
export const TRANSCRIPT_TURN_GAP = gridLength("gap-turn");
export const TRANSCRIPT_COMPOSER_GAP = gridLength("gap-composer");
/// Codex leaves 16px between transcript items, including prose adjacent to activity.
export const TRANSCRIPT_RUN_GAP = gridLength("gap-run");
/// A reply footer (design/transcript-spacing.md "Reply footer"; Leo, 2026-11-02: "didn't i always
/// say we can do it like chatgpt"): ChatGPT's 32 button around a 20 glyph, 8 under the reply's last
/// line, then the block gap to whatever comes next.
export const TRANSCRIPT_FOOTER_GAP = gridLength("gap-footer");
export const TRANSCRIPT_FOOTER_CONTROL = gridLength("transcript-footer-control");
/// The air a one-line row gets over its 22 line of words, split evenly above and below them: one token for every
/// activity, tool, notice and message row, so every row kind moves together (conversation.css `--cv-row-air`). Leo,
/// 2026-11-22 10:55Z, beside the newer ChatGPT's tool list (about 33 apart at our size, ours 22): "it's just too much
/// fucking text crammed together. let's just follow the newer chatgpt that his this sort of spacing ... just add some
/// more. our is too much of a dense eyesore right now." Gallery `agent-pane.row-air` shows the looks
/// (`<html data-row-air>`); `shipped` is the default.
export const ROW_AIR_LOOKS = {
  /// Before: the 22 pitch (#29965), rows flush.
  before: 0,
  /// Candidate A: a 28 pitch.
  a: 6,
  /// Candidate C: a 34 pitch, ChatGPT's 33.
  c: 12,
  /// The pick: a 32 pitch.
  shipped: 10,
} as const;
export type RowAirLook = keyof typeof ROW_AIR_LOOKS;
export function rowAirLook(): RowAirLook {
  const set = typeof document === "undefined" ? undefined : document.documentElement?.dataset?.rowAir;
  return set !== undefined && set in ROW_AIR_LOOKS ? (set as RowAirLook) : "shipped";
}
/// A one-line row's words: the 22 line they had before any air (#29965).
export const TRANSCRIPT_LINE_WORDS = 22;
/// A one-line row's height: a step row, a status row, the live line in a run (conversation.css
/// `--cv-tool-row-height` at the default density, "One-line row pitch", #29965): its words' line and the row air.
export const TRANSCRIPT_LINE_ROW = TRANSCRIPT_LINE_WORDS + ROW_AIR_LOOKS.shipped;
/// The same for the look in force (`rowAirLook`), read per layout.
export const transcriptLineRow = (): number => TRANSCRIPT_LINE_WORDS + ROW_AIR_LOOKS[rowAirLook()];

/// The running turn's live line as its last row (`below`): the gap over it right under a step or status row (model.ts
/// `isLiveStep`, MARK_LIVE_STEP), the room its row takes, and the box its words are drawn in, set here and nowhere
/// else. model.ts places it with these, conversation.css draws it through the custom properties `transcriptLiveVars`
/// puts on the transcript, and the spacing spec (transcriptSpacing.ts) and the tests derive their numbers from them,
/// so changing its box or its gap is one line here (Leo, 2026-11-15: "why do we have so many files that get affected
/// each time anyways").
///   `line`  one more one-line row of the run, TRANSCRIPT_LINE_ROW tall (#29965)
///   `slot`  the footer's TRANSCRIPT_FOOTER_CONTROL slot it has under a reply, so what lands over it moves nothing
///           (cmux#24569)
/// Since #41213 made live-turn-work `runs` the default, the row over the line keeps switching between a run and a
/// reply: with a `line` row under a run and a `slot` row under a reply, each switch moved the line 10 px in layout
/// (transcript_replay.live.cls about 1.1, cmux#47098), which is why the row stays the `slot` (#43627, #47111).
/// Its words are drawn in TRANSCRIPT_LIVE_LINE_BOX at the top of that row, the same box under a run, a reply or a
/// prompt, so the switch moves neither its top nor its words, and the footer that takes the slot when the turn ends
/// moves nothing under it. Leo, 2026-11-21 05:23Z: "see the space/gap between tool calls and the current shimmer?
/// this isnt great." The 16 gap over a 32 box put its words 43 under a step row's centre; the 8 over a 22 box puts
/// them 30 under, one row pitch and the 8 a footer stands under its reply (variant B).
/// `<html data-live-gap>` (gallery `agent-pane.chat-live-gap`) shows the looks side by side; `shipped` is the default.
export const LIVE_GAP_LOOKS = {
  /// Before: the run gap (16) over the 32 slot, its words centred in it.
  before: { gap: "gap-run", row: "slot", box: "slot" },
  /// The bare flip: the footer gap (8) over a 22 row under a run (the composer gap under it), the 32 slot under a
  /// reply, its words centred in each. It jumps.
  jumps: { gap: "gap-footer", row: "line", box: "slot" },
  /// The fallback: the footer gap (8) over the 32 slot, its words centred in it (35 under a step row's centre).
  slot8: { gap: "gap-footer", row: "slot", box: "slot" },
  /// Variant B: the footer gap (8) over a 22 box drawn at the top of the 32 slot, under every row.
  shipped: { gap: "gap-footer", row: "slot", box: "line" },
} as const satisfies Record<string, { gap: string; row: "line" | "slot"; box: "line" | "slot" }>;
export type LiveGapLook = keyof typeof LIVE_GAP_LOOKS;
export function liveGapLook(): (typeof LIVE_GAP_LOOKS)[LiveGapLook] {
  const set = typeof document === "undefined" ? undefined : document.documentElement.dataset.liveGap;
  return set !== undefined && set in LIVE_GAP_LOOKS ? LIVE_GAP_LOOKS[set as LiveGapLook] : LIVE_GAP_LOOKS.shipped;
}
const boxLength = (box: "line" | "slot", line = TRANSCRIPT_LINE_ROW) =>
  box === "slot" ? TRANSCRIPT_FOOTER_CONTROL : line;
const boxVar = (box: "line" | "slot") => (box === "slot" ? "var(--cv-footer-row)" : "var(--cv-tool-row-height)");
/// The room its row takes right under a step row.
export const TRANSCRIPT_LIVE_STEP_BOX = LIVE_GAP_LOOKS.shipped.row as "line" | "slot";
/// The grid token of the gap over it right under a step row: the footer gap, 8, as a footer stands under its reply.
export const TRANSCRIPT_LIVE_STEP_GAP_TOKEN = LIVE_GAP_LOOKS.shipped.gap as string;
export const TRANSCRIPT_LIVE_STEP_GAP = gridLength(TRANSCRIPT_LIVE_STEP_GAP_TOKEN);
/// Its row's height under a step row at Interface Size 1.
export const TRANSCRIPT_LIVE_STEP_HEIGHT = boxLength(TRANSCRIPT_LIVE_STEP_BOX);
/// The box its words are drawn in, at the top of its row, under any row: a one-line row's 22.
export const TRANSCRIPT_LIVE_LINE_BOX = Math.min(boxLength(LIVE_GAP_LOOKS.shipped.box), TRANSCRIPT_LIVE_STEP_HEIGHT);
/// The live gap and row height under a step row for the look in force (`liveGapLook`), read per layout.
export const liveStepGap = (): number => gridLength(liveGapLook().gap);
export const liveStepHeight = (): number => boxLength(liveGapLook().row, transcriptLineRow());
/// Its box and gap as CSS custom properties, set on the transcript's root (VirtualTranscript.tsx): conversation.css
/// sizes its row under a step with `--cv-live-step-height`, draws its words in `--cv-live-line-box` at the top of its
/// row, and the gallery's plays read `--cv-live-step-gap`, never a length of their own.
export function transcriptLiveVars(): Record<
  "--cv-live-step-height" | "--cv-live-step-gap" | "--cv-live-line-box",
  string
> {
  const look = liveGapLook();
  return {
    "--cv-live-step-height": boxVar(look.row),
    "--cv-live-step-gap": `var(--grid-${look.gap})`,
    "--cv-live-line-box": boxVar(look.box),
  };
}
/// The spacing spec's distance from a one-line row's centre to the centre of the live line under it, its words
/// centred in their box (transcriptSpacing.ts "step-to-live" and the "...-to-live" status rows).
export const TRANSCRIPT_LINE_TO_LIVE_STEP =
  TRANSCRIPT_LINE_ROW / 2 + TRANSCRIPT_LIVE_STEP_GAP + TRANSCRIPT_LIVE_LINE_BOX / 2;

/// The interface scale the CSS grid tokens multiply by (desktop.css: `calc(24px *
/// var(--cmux-interface-scale, 1))`). The virtual stack places its gaps with the same factor, so
/// placed gaps match the drawn ones and the overlays laid in them at any Interface Size. Read once
/// per layout pass, and in the transcript's render (model.ts `transcriptColumn`).
///
/// The app writes the scale inline on <html> (DesignSettings.interfaceScaleScript), so it is read
/// from that declaration: `getComputedStyle(...).getPropertyValue` in render made the browser
/// recalculate the style of a page whose rows a streamed record had just changed, before React
/// changed them again, 3.8-5.1 ms of each reply token's 8-11 ms (bench/transcript-replay.bench.ts
/// PROFILE=1, long log). With no inline value (a page no app hosts) the computed one is read once
/// and kept until <html>'s attributes change or the app says the scale changed.
export function gridScale(): number {
  if (typeof document === "undefined" || typeof getComputedStyle !== "function") return 1;
  const root = document.documentElement;
  const inline = (root as Partial<HTMLElement>).style?.getPropertyValue?.(INTERFACE_SCALE_VAR);
  const raw = parseFloat(inline || computedScale(root));
  return Number.isFinite(raw) && raw > 0 ? raw : 1;
}

const INTERFACE_SCALE_VAR = "--cmux-interface-scale";
/// The computed `--cmux-interface-scale` of a page with no inline one, while <html> holds still.
let computed: { root: Element; value: string } | undefined;
const computedScale = (root: Element): string => {
  // A stand-in root (a test's plain object) has no attributes to watch: read it every time.
  if (typeof MutationObserver !== "function" || typeof Node === "undefined" || !(root instanceof Node))
    return getComputedStyle(root).getPropertyValue(INTERFACE_SCALE_VAR);
  if (computed?.root === root) return computed.value;
  const value = getComputedStyle(root).getPropertyValue(INTERFACE_SCALE_VAR);
  const kept = { root, value };
  computed = kept;
  const forget = () => {
    if (computed === kept) computed = undefined;
    watch.disconnect();
    root.ownerDocument.defaultView?.removeEventListener("cmux-ui-scale-change", forget);
  };
  const watch = new MutationObserver(forget);
  watch.observe(root, { attributes: true });
  root.ownerDocument.defaultView?.addEventListener("cmux-ui-scale-change", forget);
  return value;
};

/// What a row is for the gap rules (grid.md 5.5). Kept per row in the layout, so a placement that
/// skips DOM-empty rows still picks the gap from the neighbours that draw.
export const MARK_OTHER = 0;
export const MARK_PROMPT = 1;
export const MARK_MESSAGE = 2;
export const MARK_INDICATOR = 3;
/// A settled turn's footer with nothing to show at rest (turns.ts isEmptyFooter): no height of its
/// own, its hover controls laid over the gap under the row above. A failed or stopped turn's footer
/// (its card, Continue) is content with this mark too.
export const MARK_FOOTER = 4;
/// A step row: a tool run or a one-line activity row (model.ts `isLineRow`). Consecutive step rows
/// sit flush, one 22px line apart top to top (design/chat-transcript.md "One-line row pitch", #29965);
/// the block gap is around a run of them only.
export const MARK_STEP = 5;
/// A finished reply's footer row (its buttons, then its time): ChatGPT's 32 line, 8 under the reply.
export const MARK_FOOTER_ROW = 6;
/// The running turn's line drawn as its last row (`below`): the slot its footer takes when the turn
/// ends, at the footer's place and height, so the end moves nothing (chat-transcript.md "A turn that
/// ends moves nothing").
export const MARK_FOOTER_SLOT = 7;
/// A status row that is not a step row (model.ts `isStatusRow`: a background task's or a subagent's
/// end, a background turn's line, a compaction, a failover, ...): one quiet line that sits flush with
/// the step and status rows beside it, as far from the prose around it as a run is (row-alignment.test.ts: every status row between two replies has
/// one gap above and one below).
export const MARK_STATUS = 8;
/// A finished turn's "Worked for" line (model.ts `WORKED`). Its rule sits between its words
/// and the next row, so the room under the rule is the row's own (conversation.css
/// `.cv-worked.has-divider.is-toggle`) and no stack gap follows it inside the turn (Lucas,
/// 2026-11-07, Codex parity). Toward the rows above it, it is a step row.
export const MARK_WORKED = 9;
/// An edited-files card (turnChanges/sessionRows.ts `isEditRow`): a bordered card, not a line. It
/// stands the run gap from the one-line rows and the prose around it, the room it has under a reply,
/// so under "Subagent finished" or a tool run it is never flush (Lucas, 2026-11-08). Toward a footer
/// row, a prompt or the live line it is a step row.
export const MARK_CARD = 10;
/// The running turn's line as its last row right under a step or status row (model.ts `isLiveStep`): its box and
/// the gap over it are TRANSCRIPT_LIVE_STEP_BOX and TRANSCRIPT_LIVE_STEP_GAP; under it, the room a row of that box
/// has (tailGap). Not another step, which would sit flush.
export const MARK_LIVE_STEP = 12;
/// The same line right under a step row whose last item is a thought (model.ts `isLiveThought`): it stands the run
/// gap a reply has under that thought (TRANSCRIPT_RUN_GAP), not the live step's 8, so the reply that takes its place
/// lands at its top and the thought's gap is its final 16 from the thought's first frame. Under the 8 the reply came
/// 8 lower than the line and everything over it moved up 8 more than the reply's own line, the reply overlapping the
/// line's words while the follow caught up (Leo, 2026-11-24: "the extra spacing after thinking added more layout
/// shifts"; test/agent-pane-thinking-cls.test.ts). Its box and the room under it are MARK_LIVE_STEP's.
export const MARK_LIVE_THOUGHT = 13;
/// Added to a row's mark (a reply or a tool run) when it opens a turn the agent ran on its own that
/// draws as its own turn, with no line of its own over it (model.ts `opensBackgroundTurn`): a task
/// notification started it, not a prompt. It stands the turn gap from the row over it, as a prompt
/// does, so it never reads as the tail of the subagent or tool row above (Leo, 2026-11-08: "the
/// text in this situation isn't from the subagent?"). Toward the rows after it, it is its own mark.
export const MARK_OPENS_TURN = 64;
/// Added to a row that heads a turn another agent's line opened (model.ts `gridMark`): the running
/// turn's live line ("Thinking", "Working") right under that notice or message, which heads the turn's
/// work as "Working for" does; or the notice or message itself right under the turn before's "Worked
/// for" line when that turn's footer draws nothing (no stack gap follows "Worked for" inside its turn,
/// so it stood flush, as that turn's last step). Either stands the "Working for" head gap over it
/// (`workedHeadGap`), not none. Toward the rows after it, it is its own
/// mark.
export const MARK_HEADS_TURN = 128;
/// Added to the top row of a turn another agent's line opened (model.ts `topsIncomingTurn`): that notice or
/// message, or the turn's "Working for" / "Worked for" line over it, right under the turn before's last reply
/// when that turn draws no footer (a turn the agent ran on its own, one whose footer folded). It stands the
/// block gap (under a footer it stands the run gap, FOOTER_WORKING_GAP_LOOKS), not the 16 a status line
/// has under prose of its own turn: there the new turn read as the reply's tail (Leo, 2026-11-21: "it is
/// noticeably bad when you start a new working for whatever and there is no space before"; found by
/// replaying recorded chats through the chat simulator, sim/README.md). Toward the rows after it, it is
/// its own mark. (Bit 32: every mark fits the layout's Uint8Array.)
export const MARK_TOPS_TURN = 32;
/// A mark without its MARK_OPENS_TURN, MARK_HEADS_TURN and MARK_TOPS_TURN bits.
export const baseMark = (mark: number): number => mark & ~(MARK_OPENS_TURN | MARK_HEADS_TURN | MARK_TOPS_TURN);

type MarkedRow = {
  kind: string;
  incoming?: unknown;
  received?: unknown;
  text?: string;
  status?: string;
  resumable?: boolean;
  below?: boolean;
  turnCopy?: readonly unknown[];
  turnPhase?: string;
  /// A footer's Connect GitHub card (conversation/githubConnect.ts): content, as a failure card is.
  githubConnect?: unknown;
};
export function rowMark(row: MarkedRow): number {
  if (row.kind === "user" && !row.incoming && !row.received) return MARK_PROMPT;
  if (row.kind === "assistant" && (row.text?.length ?? 0) > 0) return MARK_MESSAGE;
  // The live line in the footer's slot (turns.ts WORKING and THINKING, by value).
  if ((row.kind === "working" || row.kind === "thinking") && row.below === true) return MARK_FOOTER_SLOT;
  // The live line (turns.ts WORKING and THINKING, by value: this module stays import-free).
  // The turn's header in its running phase is that clock too (turns.ts `turnHeaderId`).
  if (row.kind === "working" || row.kind === "thinking" || (row.kind === "worked" && row.turnPhase === "running"))
    return MARK_INDICATOR;
  if (row.kind === "turnSummary")
    // turns.ts isEmptyFooter's inverse, inline so this module stays import-free.
    return row.status !== "failed" &&
      row.status !== "error" &&
      !row.githubConnect &&
      ((row.text?.length ?? 0) > 0 || (row.turnCopy?.length ?? 0) > 0)
      ? MARK_FOOTER_ROW
      : MARK_FOOTER;
  return MARK_OTHER;
}

/// The gap over a turn's "Working for"/"Worked for" line right under a one-line row (transcriptGap), and over a
/// MARK_HEADS_TURN row: `row` (shipped), the gap `<html data-row-gap>` gives "Worked for" under a line (rowGapLook
/// `workedAfterLine`, the run gap 16 by default, #48591); `run`, 16; `block`, 24; `turn`, the 32 under a person's
/// prompt; `flush`, the 0 it stood before (gallery `agent-pane.working-turn-gap`, `<html data-worked-head-gap>`).
/// Read only for such a pair.
export type WorkedHeadGapLook = "row" | "flush" | "run" | "block" | "turn";
export function workedHeadGapLook(): WorkedHeadGapLook {
  const set = typeof document === "undefined" ? undefined : document.documentElement?.dataset.workedHeadGap;
  return set === "flush" || set === "run" || set === "block" || set === "turn" ? set : "row";
}
const workedHeadGap = (): number => {
  const look = workedHeadGapLook();
  return look === "flush"
    ? 0
    : look === "run"
      ? TRANSCRIPT_RUN_GAP
      : look === "block"
        ? TRANSCRIPT_BLOCK_GAP
        : look === "turn"
          ? TRANSCRIPT_TURN_GAP
          : rowGapLook().workedAfterLine;
};

const isLineMark = (mark: number): boolean => mark === MARK_STEP || mark === MARK_STATUS || mark === MARK_WORKED;

/// The two gaps a one-line row stands over a turn boundary, in px at Interface Size 1 (design/chat-surfaces.md
/// "Row rhythm"). Gallery `agent-pane.chat-row-spacing` compares the looks (`<html data-row-gap>`); `shipped` is the
/// default. `opensAfterLine`: a background turn's first row under a one-line row (it stood the turn gap, 32, a blank
/// band). `workedAfterLine`: "Worked for" under a one-line row (it stood flush, 0).
export const ROW_GAP_LOOKS = {
  before: { opensAfterLine: TRANSCRIPT_TURN_GAP, workedAfterLine: 0 },
  tight: { opensAfterLine: 0, workedAfterLine: 8 },
  shipped: { opensAfterLine: 0, workedAfterLine: TRANSCRIPT_RUN_GAP },
  roomy: { opensAfterLine: 0, workedAfterLine: TRANSCRIPT_BLOCK_GAP },
} as const;
export type RowGapLook = keyof typeof ROW_GAP_LOOKS;
export function rowGapLook(): (typeof ROW_GAP_LOOKS)[RowGapLook] {
  const set = typeof document === "undefined" ? undefined : document.documentElement.dataset.rowGap;
  return set !== undefined && set in ROW_GAP_LOOKS ? ROW_GAP_LOOKS[set as RowGapLook] : ROW_GAP_LOOKS.shipped;
}

/// The gap from a reply's footer row (Copy, Branch, ...) to the next turn's "Working for" / "Worked for" line, the
/// waiting indicator or a step row (a woken turn's first tool row, another agent's line), in px at Interface Size 1. It matched no rule and stood the block gap (24): the 24 buttons sit
/// centred in their 32 row and the 20 line in its 32 row, so it read as ~38 from the icons to the words (Leo,
/// 2026-11-25: "did we identify the cause between the gap here? betwen the copy branch etc buttons and the next
/// working for?"). Not flush either: "it is noticeably bad when you start a new working for whatever and there is no
/// space before" (Leo, 2026-11-21). It ships the run gap (16), the gap "Worked for" stands under any one-line row
/// (ROW_GAP_LOOKS `shipped`), so a new turn's line reads as a new run, not the footer's tail (8) nor a block away.
/// Gallery `agent-pane.woken-turn-gap` compares the looks (`<html data-footer-working-gap>`): `block` (24, before)
/// and `footer` (8). Read only for such a pair.
export const FOOTER_WORKING_GAP_LOOKS = {
  block: TRANSCRIPT_BLOCK_GAP,
  run: TRANSCRIPT_RUN_GAP,
  footer: TRANSCRIPT_FOOTER_GAP,
} as const;
export type FooterWorkingGapLook = keyof typeof FOOTER_WORKING_GAP_LOOKS;
export function footerWorkingGapLook(): FooterWorkingGapLook {
  const set = typeof document === "undefined" ? undefined : document.documentElement?.dataset.footerWorkingGap;
  return set === "block" || set === "footer" ? set : "run";
}

/// One gap per adjacent pair, the most specific first: the waiting rule, then turn, then block.
/// (The composer gap is the stack's, tailGap below.) Gaps never add.
export function transcriptGap(previous: number, next: number): number {
  previous = baseMark(previous);
  if ((next & MARK_OPENS_TURN) !== 0) {
    // Under a one-line row (a step, a status line, "Worked for", a group's head) the turn's first row is one more
    // line of the run: the turn gap there left a blank band inside an opened group, above its first child and between
    // children (Leo, 2026-11-21, on the video of a "Sent 3 messages, used a tool, ..." group opened: "spacing is off").
    // Prose opening a turn under a line keeps the turn gap; only a line under a line joins the run.
    if (!isLineMark(previous) || !isLineMark(baseMark(next))) return TRANSCRIPT_TURN_GAP;
    const gap = rowGapLook().opensAfterLine;
    if (gap > 0) return gap;
    next = baseMark(next);
  }
  // A turn another agent's line opened, under the turn before's last reply (MARK_TOPS_TURN).
  if ((next & MARK_TOPS_TURN) !== 0 && previous === MARK_MESSAGE) return TRANSCRIPT_BLOCK_GAP;
  // The live line under the notice or message that opened its turn, or that notice right under the turn
  // before's "Worked for" (it sat flush): the same gap as the "Worked for" rule below.
  if ((next & MARK_HEADS_TURN) !== 0) return workedHeadGap();
  next = baseMark(next);
  if (previous === MARK_WORKED && next !== MARK_PROMPT) return 0;
  if (previous === MARK_WORKED) previous = MARK_STEP;
  // A turn's "Working for" or "Worked for" line opens that turn's work. Right under a one-line row
  // (the notice or another agent's line that opened the turn, or the turn before's last run when the
  // prompt draws nothing) it stood flush as one more step, and the new turn read as the old one's
  // tail (Leo, 2026-11-21: "it is noticeably bad when you start a new working for whatever and there
  // is no space before"). The "Working for" and the "Worked for" that replaces it stand the same gap.
  // (The "Working for" and the "Worked for" that replaces it stand the same gap, workedHeadGap.)
  // "Worked for" opens a finished turn's work: right under another turn's last one-line row it stood flush with it,
  // so "Sent to", another agent's line and "Worked for" read as one run (Leo, 2026-11-21: "way too close. no way.").
  if (next === MARK_WORKED && (previous === MARK_STEP || previous === MARK_STATUS)) return workedHeadGap();
  // The next turn's first row under a reply's footer row: its "Working for" / "Worked for" line, the waiting
  // indicator, or a step (a woken turn's first tool row, another agent's line). A status line there keeps the
  // footer gap (8), below.
  if (previous === MARK_FOOTER_ROW && (next === MARK_WORKED || next === MARK_INDICATOR || next === MARK_STEP))
    return FOOTER_WORKING_GAP_LOOKS[footerWorkingGapLook()];
  if (next === MARK_WORKED) next = MARK_STEP;
  const near = (mark: number) =>
    mark === MARK_STEP || mark === MARK_STATUS || mark === MARK_MESSAGE || mark === MARK_CARD;
  if ((previous === MARK_CARD && near(next)) || (next === MARK_CARD && near(previous))) return TRANSCRIPT_RUN_GAP;
  if (previous === MARK_CARD) previous = MARK_STEP;
  if (next === MARK_CARD) next = MARK_STEP;
  // A reply's footer sits 8 under its last line (Claude's placement, ChatGPT's 5); 24 or a prompt's
  // turn gap follows it, by the rules below.
  if ((next === MARK_FOOTER_ROW || next === MARK_FOOTER_SLOT) && previous === MARK_MESSAGE)
    return TRANSCRIPT_FOOTER_GAP;
  // A turn that ended on work (turns.ts endsOnWork): its footer row sits the same 8 under
  // the run's last line, never a block gap away (Leo, 2026-11-02: "this spacing would be good", on
  // ChatGPT's row right under the turn's last line).
  if (next === MARK_FOOTER_ROW && (previous === MARK_STEP || previous === MARK_STATUS)) return TRANSCRIPT_FOOTER_GAP;
  // A status line right under a reply's footer row ("Background update", "Background task
  // finished", "Subagent finished", "4 background tasks finished": the agent's own work that came in
  // after the turn ended) is the tail of that turn: 8 under the footer, as the footer is under the
  // reply, never a block gap away with the turn gap under it, a lone line in the middle of the band
  // (Leo, 2026-11-04: "this bare background update tool call floating in teh air is so weird loking
  // proportionally"; design/transcript-spacing.md "Lone system rows"). Another agent's line or a
  // tool run there is a step row and opens the next turn: the run gap, above (footer-to-received).
  if (previous === MARK_FOOTER_ROW && next === MARK_STATUS) return TRANSCRIPT_FOOTER_GAP;
  // Waiting for the first output: the indicator right under its prompt takes the block gap.
  if ((next === MARK_INDICATOR || next === MARK_FOOTER_SLOT) && previous === MARK_PROMPT) return TRANSCRIPT_BLOCK_GAP;
  if (previous === MARK_PROMPT || next === MARK_PROMPT) return TRANSCRIPT_TURN_GAP;
  // Any two one-line rows in a row, a status line among them ("Scheduled check", "Compacting the
  // conversation…", a background task's end), sit flush on the 22 pitch: one row height and no gap
  // (design/transcript-spacing.md rule 3; Leo, 2026-11-02, on a Claude chat where they stood a
  // block apart: "these are all so stupid looking").
  const line = (mark: number) => mark === MARK_STEP || mark === MARK_STATUS;
  if (line(previous) && line(next)) return 0;
  // The live state is separate from completed activity. Leo, 2026-11-04: "the gap between tool
  // calls and thinking needs to be bigger". Use the same scaled run gap as activity to prose.
  if (line(previous) && (next === MARK_INDICATOR || next === MARK_FOOTER_SLOT)) return TRANSCRIPT_RUN_GAP;
  if (next === MARK_LIVE_STEP) return liveStepGap();
  if (next === MARK_LIVE_THOUGHT) return TRANSCRIPT_RUN_GAP;
  // A run, or any status line, and the reply's prose around it sit 16 apart, either way.
  if ((line(previous) && next === MARK_MESSAGE) || (previous === MARK_MESSAGE && line(next))) return TRANSCRIPT_RUN_GAP;
  return TRANSCRIPT_BLOCK_GAP;
}

/// The gap between the last drawn row and the top of the bottom stack. The waiting indicator sits
/// centred between its prompt and the stack (block gap on both sides); a message and a reply's
/// footer row keep the block gap under them, as does any element whose empty turn footer (no height,
/// its hover controls in the gap) follows it; anything else takes the composer gap.
export function tailGap(last: number, beforeLast: number, footerAfter = false): number {
  last = baseMark(last);
  // The live line in a run has the room under it that a row of its box has: an indicator's, or the footer slot's.
  if (last === MARK_LIVE_STEP || last === MARK_LIVE_THOUGHT)
    last = liveGapLook().row === "slot" ? MARK_FOOTER_SLOT : MARK_INDICATOR;
  beforeLast = baseMark(beforeLast);
  if (footerAfter) return TRANSCRIPT_BLOCK_GAP;
  if (last === MARK_INDICATOR && beforeLast === MARK_PROMPT) return TRANSCRIPT_BLOCK_GAP;
  if (last === MARK_PROMPT || last === MARK_MESSAGE || last === MARK_FOOTER_ROW || last === MARK_FOOTER_SLOT)
    return TRANSCRIPT_BLOCK_GAP;
  return TRANSCRIPT_COMPOSER_GAP;
}

/// Over a floating stack (model.ts `REST_GAP`), the band under the last drawn row that comes before
/// the rest gap: a trailing turn footer's action row is laid centred in the block gap under its reply
/// (conversation.css `.cv-turn-actions`), so the rest gap starts at that row's bottom edge; with no
/// footer the rest gap starts at the row itself (a live line, a streaming reply).
export function restBand(footerAfter: boolean): number {
  return footerAfter ? (TRANSCRIPT_BLOCK_GAP + gridLength("transcript-action-control")) / 2 : 0;
}

/// Whether a turn footer follows the last drawn row: only the trailing rows that draw nothing.
export function footerAfter(marks: Uint8Array | undefined, heights: Float64Array): boolean {
  if (!marks) return false;
  for (let index = heights.length - 1; index >= 0 && heights[index] === 0; index -= 1)
    if (marks[index] === MARK_FOOTER) return true;
  return false;
}
