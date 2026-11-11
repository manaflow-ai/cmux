// "Thinking 4s": a running turn before its first output, with the time since the prompt (`since`),
// ticking each second, so a long first think never reads as a stuck label. No mark blinks before it
// (Leo, 2026-10-20: "wtf have we removed this yet"); the word itself carries the motion, as the Codex
// and ChatGPT apps draw it: a light band in the theme accent sweeps across it (`is-shimmer`,
// conversation.css), still under Reduce Motion and the static status look. Before the turn, while
// the prompt waits for its agent to start, the same line already reads "Thinking", with no start
// status and no Cancel (Leo, 2026-11-01), so the line keeps one place and one look from send to
// the first output (cx-ncc.58). Only the status is the live region. While the chat waits on the person (an
// ask above the composer, waitingOn.ts), the line says that instead, with no time and no sweep:
// never "Thinking" while the agent is blocked on them. It reads as Claude desktop's "Needs your input"
// pill: the attention dot and the words on a tinted pill. Once answered, the dot shrinks into the
// Thinking line that takes its place (Leo, 2026-11-05: "there's a little animation that plays. It,
// like, shrinks the thing, the circle into the Thinking... portion afterwards which is cute"), and
// when an ask opens under a line already drawn, the dot grows in the same way (Leo, 2026-11-08: "I
// mostly just meant the yellow circle thing. I thought that was cute").
import { type RefObject, useContext, useLayoutEffect, useMemo, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { usePaneLanguage, useT } from "../i18n";
import { agentStartLook } from "./agentStart.experiment";
import { liveLineTokens } from "./liveLineTokens.experiment";
import { compactingLine } from "./compactingLine.experiment";
import { liveLineTimes } from "./liveLineTimes.experiment";
import { oneRowPerCall } from "./oneRowPerCall.experiment";
import { Spinner } from "./icons";
import { BackgroundHint } from "./BackgroundHint";
import { useSubsessionInfo } from "../subagents/subsessions";
import { LiveShimmer } from "./LiveShimmer";
import { Slot } from "../../../slots/Slot";
import { slotVariant, useSlotVariant } from "../../../slots/registry";
import { thinkingIndicatorSlot, type ThinkingIndicatorProps } from "../../../slots/thinkingIndicator";
import { DefaultThinkingIndicator } from "../../../slots/thinkingIndicator/DefaultThinkingIndicator";
import { formatDuration, spanDuration } from "./turns";
import { WAITING_LABEL, type WaitingOn, WaitingOnContext } from "./waitingOn";
import { TurnTokens } from "./TurnTokens";
import { compactTokens, hasTokens, tokenDetail } from "./turnTokensModel";
import { usePageNow as useTicking } from "../../../ui/pageClock";
import { WorkingCountsContext, workingParts } from "./workingForModel";
import { motionAllowed } from "../subagents/trayMotionModel";
import { verbLeads } from "./toolVerbModel";
import { statusVerbAt, statusVerbLabels, useStatusVerbConfig } from "../statusVerbs";
import { thinkingVerb, ThinkingVerbsContext } from "./thinkingVerbs";
import type { AcpmuxCompaction, AcpmuxTurnRetry } from "../model";
import { retryParts, WRITING_MS, liveLead } from "./thinkingModel";
/// False while `key` changed in the last `ms`, true once it held still that long (or there is none).
/// `since`, when known, is when the key's text was written: a key that was already that old when the
/// line mounted (a chat opened long after its reply paused) is quiet from the first frame, instead
/// of counting `ms` from the mount as if it had just moved.
function useQuiet(key: string | undefined, ms: number, since?: number, now: () => number = Date.now): boolean {
  const age = () => (since === undefined ? 0 : Math.max(0, now() - since));
  const [quiet, setQuiet] = useState(() => key === undefined || age() >= ms);
  // The key the line mounted with: only that one is timed from `since`; a later key just moved.
  const mounted = useRef(key);
  // The first streamed assistant chunk inserts the answer and changes `key` in the same commit.
  // The line reads "Writing" before that commit paints; an effect would leave one frame of
  // "Thinking" under the first token. The timer remains an ordinary effect so it never blocks layout.
  useLayoutEffect(() => {
    if (key === undefined) {
      setQuiet(true);
      return;
    }
    const left = key === mounted.current ? ms - age() : ms;
    if (left <= 0) {
      setQuiet(true);
      return;
    }
    setQuiet(false);
    const timer = setTimeout(() => setQuiet(true), left);
    return () => clearTimeout(timer);
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `since` only seeds the mounted key
  }, [key, ms]);
  return quiet;
}

/// The words the live line said before its latest change, and how many changes it has rolled.
type Roll = {
  key?: string;
  label: string;
  lead?: { lead: string; rest: string };
  turns: number;
  out?: Roll;
  /// What followed the words when they rolled out: their time and counts ("1m · 1.7K tokens").
  tail?: string;
};

/// The live line rolls its words when they change (Leo, 2026-11-05, on another app's status line:
/// "this is quite good too how it animates the changing text!!! we need to have that!!! for
/// changing tool calls at the bottom"): the old words roll up and out of the line as the new roll in
/// from below, both opaque and clipped to the line (conversation.css `cv-roll-*`). `key` names what the line says; the playful verb's
/// own rotation keeps one key, so only a new call or state rolls. Undefined (the line waits on the
/// person, retries or shows a start look) rolls nothing, and neither do the first words after it.
///
/// The whole line rolls as one, its time and counts with its words (Leo, 2026-11-11, on "Thinking 1m
/// · 1.7K tokens" turning to "Sending a message 1m" and back to "Thinking 1m 5s · 2.5K tokens": "the
/// animation system is so borked and unintegrated"): the old line's tail as it was last drawn
/// (`drawn`, the last commit's) rolls out with its words, and the new tail rolls in with the new
/// words (`.cv-worked--live[data-roll]`), so no count pops off or on while the words roll.
function useRoll(key: string | undefined, label: string, lead: Roll["lead"], tail: string): Roll {
  const [roll, setRoll] = useState<Roll>({ key, label, lead, turns: 0 });
  // The tail as last committed: read only when the key changes, so a tick costs no second render.
  const drawn = useRef(tail);
  useLayoutEffect(() => {
    drawn.current = tail;
  });
  if (key !== roll.key) {
    const rolls = key !== undefined && roll.key !== undefined;
    setRoll({
      key,
      label,
      lead,
      // Away clears the count too: the words that come back draw no roll in.
      turns: key === undefined ? 0 : roll.turns + (rolls ? 1 : 0),
      out: rolls ? { ...roll, out: undefined, tail: drawn.current } : undefined,
    });
  } else if (label !== roll.label) setRoll({ ...roll, label, lead });
  return roll;
}

/// The line's counts glide to where their words leave them (Leo, 2026-11-11: "the animation system
/// is so borked and unintegrated"): a count that moves sideways while the line does not roll (its
/// time grows a digit, its words change width under one key) slides from where it was drawn on the
/// arrival step, transform only, so it never jumps a frame. A roll moves it with the words instead
/// (`useRoll`), and the gates that stop the roll stop this too.
function useCountGlide(line: RefObject<HTMLDivElement | null>, turns: number) {
  const drawn = useRef<{ turns: number; lefts: number[] }>({ turns, lefts: [] });
  useLayoutEffect(() => {
    const node = line.current;
    if (!node) return;
    const counts = [...node.querySelectorAll<HTMLElement>(":scope > .cv-worked__count")];
    const lefts = counts.map((count) => count.offsetLeft);
    const before = drawn.current;
    drawn.current = { turns, lefts };
    if (before.turns !== turns || !motionAllowed(node) || !countsMove(node)) return;
    counts.forEach((count, index) => {
      const from = before.lefts[index];
      const dx = from === undefined ? 0 : from - lefts[index]!;
      if (Math.abs(dx) < 0.5) return;
      count.animate([{ translate: `${dx}px 0` }, { translate: "0 0" }], {
        duration: arriveMs(node),
        easing: "cubic-bezier(0.2, 0, 0, 1)",
      });
    });
  });
}

/// The same gates as the roll (conversation.css `cv-roll-*`).
function countsMove(node: Element): boolean {
  const root = node.ownerDocument.documentElement;
  const cmux = root.getAttribute("data-cmux-motion");
  return (
    cmux !== "off" &&
    cmux !== "reduced" &&
    root.getAttribute("data-agent-motion") !== "off" &&
    root.getAttribute("data-status-indicators") !== "static"
  );
}

/// The arrival step (`--agent-motion-arrive`), in ms.
function arriveMs(node: Element): number {
  const value = node.ownerDocument.defaultView?.getComputedStyle(node).getPropertyValue("--agent-motion-arrive").trim();
  const ms = value?.endsWith("ms")
    ? Number.parseFloat(value)
    : value?.endsWith("s")
      ? Number.parseFloat(value) * 1000
      : NaN;
  return Number.isFinite(ms) ? ms : 120;
}

/// `doing`, `doingAt`, `doingShell`, `draft`, `untimed`, `quietKey`: the Codex-style live line at the
/// bottom of a running turn (conversation/turns.ts `codexLiveTurn`), the turn's one live block, which
/// each step replaces in place: "Thinking 18s" (the turn's time, and its tokens when the harness
/// reports them), the call in flight ("Running bun test 13s", or what it says it does, "Run the
/// web tests 13s"), the latest finished step until the next starts (`done`, "Ran grep … 15s"), or
/// "Writing a command 9s" while the agent still writes the command (`draft`). With no call it names
/// what the turn does instead: "Waiting on 2 subagents", "Writing", else "Thinking" (`liveState`).
/// One clock and one token count for all of them, the turn's, so the line just keeps going: "Using
/// repo: repo grep 3m 2s · 47.4K tokens", as Claude Code desktop's live line reads, with no mark
/// before it: the shimmer is its only working sign (Leo, 2026-11-03: "we don't want the claude
/// symbol ellipsis thing btw we just keep the shimmer ONLY"). Past the turn's first step
/// (`turnTotal`) that clock follows a finished step's own time after a dot ("2s · 4m"), so a long
/// wait never reads as that long a think or call. All shimmer. While text streams (`quietKey` moves) the
/// line stays where it is and reads "Writing": it never leaves and comes back mid-turn (Leo,
/// 2026-11-04: "it appears and disappears????").
/// The longest the dot's grow or shrink lasts, should it never end (motion off draws no animation).
const SETTLE_MS = 400;

/// True from the render the chat stops waiting on the person until the dot's shrink ends (`done`)
/// or SETTLE_MS passes: the line draws the shrinking dot before its words for that long.
function useAnswered(waiting: WaitingOn | undefined): [boolean, () => void] {
  const [answered, setAnswered] = useState(false);
  const was = useRef(waiting);
  useLayoutEffect(() => {
    const before = was.current;
    was.current = waiting;
    if (waiting || !before) {
      setAnswered(false);
      return;
    }
    setAnswered(true);
    const timer = setTimeout(() => setAnswered(false), SETTLE_MS);
    return () => clearTimeout(timer);
  }, [waiting]);
  return [answered, () => setAnswered(false)];
}

/// True from the render the chat starts waiting on the person, under a line already drawn, until the
/// dot's grow ends (`done`) or SETTLE_MS passes. A line that mounts waiting (a chat opened mid-ask)
/// draws the dot still: only an ask that opens while the person watches grows in.
function useAsked(waiting: WaitingOn | undefined): [boolean, () => void] {
  const [asked, setAsked] = useState(false);
  const was = useRef(waiting);
  useLayoutEffect(() => {
    const before = was.current;
    was.current = waiting;
    if (!waiting || before) {
      setAsked(false);
      return;
    }
    setAsked(true);
    const timer = setTimeout(() => setAsked(false), SETTLE_MS);
    return () => clearTimeout(timer);
  }, [waiting]);
  return [asked, () => setAsked(false)];
}

/// The words inside the live line's `<output>`. The thinking indicator is a theme slot
/// (schemas/theme/slots.json `chat.thinkingIndicator`); a named step is the line's own. While the slot
/// draws cmux's default variant, both are ONE `LiveShimmer` here, so the shimmer band is one element
/// from "Thinking" through each step and back (test/transcript-live-line-continuous-browser.test.ts:
/// "one shimmer band from the first frame to the last"). `<Slot>` for the default at this place made
/// React mount a new band at each change between the two. A theme's own variant draws through `<Slot>`
/// (its error boundary, its own mark) and a step then mounts the line's shimmer in its place.
function LiveWords({
  decorative,
  lead,
  ...indicator
}: ThinkingIndicatorProps & { decorative: boolean; lead: Roll["lead"] }) {
  const selected = useSlotVariant(thinkingIndicatorSlot);
  const builtIn = slotVariant(thinkingIndicatorSlot, selected)?.component === DefaultThinkingIndicator;
  if (decorative && !builtIn) return <Slot slot={thinkingIndicatorSlot} props={indicator} />;
  return (
    <LiveShimmer
      label={indicator.label}
      verbs={decorative ? indicator.verbs : undefined}
      lead={lead}
      elapsed={indicator.elapsed}
    />
  );
}

export function Thinking({
  starting = false,
  since,
  now = Date.now,
  doing,
  doingAt,
  doingShell = false,
  sendTo,
  sendSession,
  draft = false,
  done = false,
  call,
  doneMs,
  liveState,
  liveAgents = 0,
  liveCompaction,
  thoughtMs,
  turnTotal = false,
  untimed = false,
  verbKey,
  quietKey,
  quietAt,
  below = false,
  command = false,
  retry,
}: {
  /// The prompt waits for its agent to start (harnessSwitch.ts): the start look's arm draws it.
  starting?: boolean;
  since?: number;
  now?: () => number;
  doing?: string;
  doingAt?: number;
  doingShell?: boolean;
  /// The call in flight sends a message to `sendTo` (the sub-session `sendSession`, by its name
  /// once the list has it): "Sending message to tests".
  sendTo?: string;
  sendSession?: string;
  draft?: boolean;
  /// `doing` is a finished step ("Ran grep …"). The transcript's live line no longer holds one
  /// (turns.ts `codexLiveTurn` reads "Thinking" the moment a call completes); a host may still.
  done?: boolean;
  /// The id of the call `doing` names (turns.ts `codexLiveTurn`): while it stays the same, its words
  /// change in place ("Writing a file", "Writing gen.py", "Wrote gen.py"), one row from pending to
  /// done; only the next call rolls in (oneRowPerCall.experiment.ts).
  call?: string;
  /// How long that finished step took: the time beside it with `turnTotal`.
  doneMs?: number;
  /// With no call named: the agent waits on `liveAgents` foreground subagents, or writes its reply
  /// (turns.ts `codexLiveTurn`), or compacts the conversation (`compacting`: `liveCompaction`
  /// running, timed from `doingAt`). Otherwise it reads "Thinking".
  liveState?: "subagents" | "writing" | "compacting";
  liveAgents?: number;
  liveCompaction?: AcpmuxCompaction;
  /// "Thinking" past the first step: the turn's summed thinking time, shown beside the word.
  thoughtMs?: number;
  /// Past the turn's first step the clock reads as the turn's whole time ("2s · 4m"), after the
  /// finished step's own time when it has one, so no wait reads as that long a think or call.
  turnTotal?: boolean;
  untimed?: boolean;
  /// The turn's prompt id, used to keep one playful verb for the whole turn when Rotate is on.
  verbKey?: string;
  quietKey?: string;
  /// When the reply `quietKey` names was written (turns.ts `codexLiveTurn`): a reply already
  /// still past WRITING_MS when the line mounts reads "Thinking" at once.
  quietAt?: number;
  /// The turn's last row (conversation/turns.ts): as tall as the footer that replaces it.
  below?: boolean;
  /// The call in flight is a command: the line offers ⌃B, as the command's own row does
  /// (BackgroundHint.tsx), since the row is not drawn while it runs.
  command?: boolean;
  /// The harness retries a failed model request (acpmux `turn_retrying`): the line says that,
  /// never "Thinking" (`retryParts`).
  retry?: AcpmuxTurnRetry;
} = {}) {
  const t = useT();
  const language = usePaneLanguage();
  const waiting = useContext(WaitingOnContext);
  const [answered, settled] = useAnswered(waiting);
  const [asked, grown] = useAsked(waiting);
  const startLook = starting && !waiting ? experimentArm(agentStartLook) : "thinking";
  // The turn's time, from the prompt, whatever the line names: it keeps counting across steps and
  // never starts again at a call (Leo, 2026-11-01: "it should just keep going").
  const from = untimed ? undefined : since;
  const timed = !waiting && from !== undefined;
  const time = useTicking(timed, now);
  const statusVerbConfig = useStatusVerbConfig();
  const thinkingVerbs = useContext(ThinkingVerbsContext);
  const verbs = useMemo(
    () => thinkingVerbs ?? statusVerbLabels(t, statusVerbConfig),
    [t, statusVerbConfig, thinkingVerbs],
  );
  // A reply that paused only a moment is still being written; one silent for longer is the agent
  // thinking before its next step, which reads "Thinking" (Leo, 2026-11-03).
  const stillWriting = !useQuiet(liveState === "writing" ? quietKey : undefined, WRITING_MS, quietAt, now);
  const sendName = useSubsessionInfo(sendSession)?.name ?? sendTo;
  const waitsOnAgents = liveState === "subagents" && liveAgents > 0;
  const writing = liveState === "writing" && stillWriting;
  // A compaction says so with its own clock: no model thinks or writes then, so never "Thinking"
  // and no token count (Leo, 2026-11-07: "You're not thinking during this time. So it shouldn't be
  // labeled as thinking"). The look's arm sets its clock (compactingLine.experiment.ts).
  const compacting = doing === undefined && liveState === "compacting";
  const compactLook = compacting ? experimentArm(compactingLine) : undefined;
  const elapsedMs = timed ? Math.max(0, time - from) : 0;
  const turnVerb = thinkingVerb(thinkingVerbs, verbKey);
  const decorative = doing === undefined && !waitsOnAgents && !writing && !compacting;
  const label =
    doing === undefined
      ? compacting
        ? t(liveCompaction?.reason === "account_switch" ? "compaction.runningAccountSwitch" : "turn.live.compacting")
        : waitsOnAgents
          ? t("turn.live.waitingOnSubagents", { n: liveAgents })
          : writing
            ? t("turn.live.writing")
            : (turnVerb ??
              (statusVerbConfig.mode === "custom" ? statusVerbAt(elapsedMs, { mode: "custom", verbs }) : t("thinking")))
      : sendName !== undefined
        ? t("send.sending", { target: sendName })
        : doingShell
          ? doing
            ? t(done ? "tools.ranCommand" : "tools.runningCommand", { command: doing })
            : draft
              ? t("tools.writingCommand")
              : t(done ? "tools.ranUnnamed" : "tools.runningUnnamed")
          : doing;
  const lead = doing === undefined ? undefined : liveLead(label, verbLeads(t), !doingShell && sendName === undefined);
  // A retry or a start look draws other words in place of the line: coming back rolls nothing.
  const away = waiting !== undefined || retry !== undefined || startLook !== "thinking";
  const sameCall = call !== undefined && doing !== undefined && experimentArm(oneRowPerCall) === "morph";
  const turnTime = timed ? formatDuration(Math.max(0, time - from)) : undefined;
  // Past the first step a finished step's own time stands beside the label, and the turn's clock
  // follows it after a dot: "Ran grep -n x 2s · 15s" (Leo, 2026-11-03: "i think the "thinking"
  // accounting is also off pretty frequently"). With no own time the turn's clock stands beside the
  // label alone, "Waiting on 2 subagents 1h 24m", never after a dot, and no line says "total" (Leo,
  // 2026-11-04: "the total is redundant", "there's no point to say total", and on the dot's gap:
  // "same here it's annoying to look at"). The turn's clock stays its own element (`cv-worked__time`)
  // that keeps ticking from the prompt.
  const total = turnTotal && turnTime !== undefined;
  // What stands beside the label then, never a clock that starts again at a call (Leo, 2026-11-01:
  // "it should just keep going"): a finished step's own start to end, or the turn's summed thinking.
  const compactMs = compacting && timed && doingAt !== undefined ? Math.max(0, time - doingAt) : undefined;
  const ownMs = compacting
    ? compactLook === "turn"
      ? compactMs
      : undefined
    : doing === undefined
      ? waitsOnAgents || writing
        ? undefined
        : thoughtMs
      : done
        ? doneMs
        : undefined;
  // Under a second it says its milliseconds, as the step's own row does ("856ms"), never "0s".
  // Two bare durations never stand side by side: each is named, "step 3s · turn 21s" (Leo's capture,
  // 2026-11-07, of "python3 - <<'EOF' 3s · 21s · 549 tokens"; liveLineTimes.experiment.ts).
  const timesLook = experimentArm(liveLineTimes);
  const ownTime =
    timesLook !== "turn" && total && ownMs !== undefined
      ? compacting
        ? formatDuration(ownMs)
        : spanDuration(t, ownMs)
      : undefined;
  // Only a finished step's time is named "step": the summed thinking beside "Thinking" (or a
  // compaction's clock beside its words) already reads as that word's.
  const own =
    ownTime && timesLook === "labelled" && doing !== undefined ? t("turn.live.stepTime", { time: ownTime }) : ownTime;
  // "Thinking" with no own time stands beside the turn's clock alone, unnamed: "Thinking 1m 24s", never
  // "Thinking · turn 1m 24s" (Leo, 2026-11-09: "when thinking dont add the turn ... jsut remove the turn").
  // The turn's clock after an own time: named when labelled, only in the step time's tooltip on hover.
  const turnClock =
    own && turnTime && timesLook === "labelled" ? t("turn.live.turnTime", { time: turnTime }) : turnTime;
  const turnTitle = own && turnTime && timesLook === "hover" ? t("turn.live.turnTime", { time: turnTime }) : undefined;
  // The compaction's own clock alone (`own` arm), never the turn's: the turn did not think that long.
  const elapsed = compacting
    ? compactLook === "own" && compactMs !== undefined
      ? formatDuration(compactMs)
      : compactLook === "turn"
        ? (own ?? turnTime)
        : undefined
    : (own ?? turnTime);
  // The turn's generated output tokens so far (WorkingFor.tsx), on the line while it times the turn; and, with the
  // running tray off, the work still going in the background, each count opening what it counts
  // (App.tsx counts nothing while the tray lists it).
  const counts = useContext(WorkingCountsContext);
  const tokens = counts?.tokens;
  // A send's line names who it goes to and for how long; the turn's token counts there are noise
  // (Leo, 2026-11-02, on "Sending message to … 3m 56s · ↓1.4K out ↑819.5K in" among the message
  // rows: "i also think this is quite weird looking").
  const sending = doing !== undefined && sendName !== undefined;
  const showTokens = Boolean(tokens) && timed && !sending && !compacting;
  // One count, as Claude Code's live line says it ("47.4K tokens"): the turn's output, with the
  // split on hover (liveLineTokens.experiment.ts). Never "↓ out ↑ in" in the line's words (the
  // coordinator, relaying Leo's capture of "Thinking 7m 34s · ↓ 4.5K out ↑ 1.4M in").
  const oneCount = experimentArm(liveLineTokens) === "total";
  // The label already names the subagents it waits on: no second count of them.
  const parts = (counts && !waiting ? workingParts(t, counts) : []).filter(
    (part) => !(liveState === "subagents" && part.key === "agents"),
  );
  // What follows the words, as text: their time, the turn's clock and counts, for the old line's copy
  // to roll out with them (`useRoll`).
  const tokenText =
    showTokens && tokens
      ? oneCount
        ? t("turn.working.tokens", { n: tokens, tokens: compactTokens(language, tokens) })
        : compactTokens(language, tokens)
      : undefined;
  const tail = [
    elapsed,
    own && !waiting && timesLook !== "hover" ? turnClock : undefined,
    tokenText,
    ...parts.map((part) => part.label),
  ]
    .filter(Boolean)
    .join(" · ");
  const roll = useRoll(away ? undefined : decorative ? "" : sameCall ? `\u0000${call}` : label, label, lead, tail);
  const lineRef = useRef<HTMLDivElement>(null);
  useCountGlide(lineRef, roll.turns);
  // A model the harness cannot reach: said calmly in the line's own box, so nothing moves when it
  // starts or ends (Leo, 2026-11-03). What the chat waits on the person for still comes first.
  if (retry && !waiting) {
    const parts = retryParts(t, retry);
    return (
      <div
        className={`cv-worked cv-worked--live${below ? " is-below" : ""}`}
        data-find-skip
        data-lead-slot
        data-retrying=""
      >
        <output className="cv-thinking cv-retrying">{parts.label}</output>
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          {parts.count}
        </span>
        {parts.error && (
          <span className="cv-worked__count cv-retrying__error" title={parts.error}>
            <span className="cv-worked__sep" aria-hidden="true">
              ·
            </span>
            <span className="cv-retrying__words">{parts.error}</span>
          </span>
        )}
      </div>
    );
  }
  // The `silent` and `spinner` start looks keep the line's box (`.cv-worked`'s height) with no words.
  if (startLook !== "thinking")
    return (
      <div
        className={`cv-worked${below ? " is-below" : ""}${startLook === "silent" ? " is-quiet" : ""}`}
        data-find-skip
      >
        {startLook === "spinner" && <Spinner size={14} loading />}
      </div>
    );
  return (
    // `cv-worked--live`: its words start on the icon column, with no icon slot (conversation.css).
    <div
      ref={lineRef}
      className={`cv-worked cv-worked--live${below ? " is-below" : ""}`}
      data-find-skip
      data-compacting={compacting && !waiting ? "" : undefined}
      // The line's tail rolls in with its words (conversation.css `cv-roll-*`).
      data-roll={waiting || roll.turns === 0 ? undefined : roll.turns % 2 ? "odd" : "even"}
    >
      {waiting ? (
        <output className="cv-thinking cv-waiting" data-waiting={waiting}>
          <span
            className={`cv-needs-input-glyph${asked ? " is-asked" : ""}`}
            aria-hidden="true"
            onAnimationEnd={asked ? grown : undefined}
          />
          <span className="cv-waiting__pill">{t(WAITING_LABEL[waiting])}</span>
        </output>
      ) : (
        <span className="cv-shimmer__row">
          {answered && (
            <span className="cv-needs-input-glyph is-answered" aria-hidden="true" onAnimationEnd={settled} />
          )}
          {/* The words before, rolling out above: drawn from attributes, so no reader, Find or copy
              meets them twice (conversation.css `cv-roll-out`); keyed by the change, so each rolls. */}
          {roll.out && (
            <span
              key={roll.turns}
              className="cv-roll-out"
              aria-hidden="true"
              inert
              data-lead={roll.out.lead?.lead}
              data-text={roll.out.lead ? roll.out.lead.rest : roll.out.label}
              data-tail={roll.out.tail ? `\u2002${roll.out.tail}` : undefined}
            />
          )}
          <output
            className={`cv-thinking${compactLook === "calm" ? "" : " is-shimmer"}`}
            data-roll={roll.turns === 0 ? undefined : roll.turns % 2 ? "odd" : "even"}
            aria-label={decorative ? t("thinking") : undefined}
            aria-live={decorative ? "off" : undefined}
          >
            {compactLook === "calm" ? (
              label
            ) : (
              <LiveWords
                decorative={decorative}
                label={label}
                lead={lead}
                verbs={verbs}
                elapsed={elapsed}
                elapsedMs={elapsedMs}
              />
            )}
          </output>
          {elapsed && (
            <span className={own ? "cv-worked__own" : "cv-worked__time"} title={turnTitle}>
              {elapsed}
            </span>
          )}
        </span>
      )}
      {own && !waiting && timesLook !== "hover" && (
        <span className="cv-worked__count cv-worked__total">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <span className="cv-worked__time">{turnClock}</span>
        </span>
      )}
      {showTokens && (
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          {oneCount && tokens ? (
            <span
              className="cv-worked__tokens"
              title={hasTokens(counts?.split) ? tokenDetail(t, language, counts.split) : undefined}
            >
              {t("turn.working.tokens", { n: tokens, tokens: compactTokens(language, tokens) })}
            </span>
          ) : (
            <TurnTokens total={tokens} split={counts?.split} />
          )}
        </span>
      )}
      {parts.map((part) => (
        <span key={part.key} className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <button type="button" className="cv-worked__open" onClick={part.open}>
            {part.label}
          </button>
        </span>
      ))}
      {/* Keyed by the call, so each command's hint waits its moment again. */}
      {command && !done && !waiting && doing !== undefined && <BackgroundHint key={doingAt} />}
    </div>
  );
}
