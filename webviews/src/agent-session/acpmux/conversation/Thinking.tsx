// "Thinking 4s": a running turn before its first output, with the time since the prompt (`since`),
// ticking each second, so a long first think never reads as a stuck label. No mark blinks before it
// (Leo, 2026-10-20: "wtf have we removed this yet"); the word itself carries the motion, as the Codex
// and ChatGPT apps draw it: a light band in the theme accent sweeps across it (`is-shimmer`,
// conversation.css), still under Reduce Motion and the static status look. Before the turn, while
// the prompt waits for its agent to start, the same line already reads "Thinking", with no start
// status and no Cancel (Leo, 2026-11-01), so the line keeps one place and one look from send to
// the first output (cx-ncc.58). Only the status is the live region. While the chat waits on the person (an
// ask above the composer, waitingOn.ts), the line says that instead, with no time, under the same sweep (Leo, 2026-11-22: all in the thinking spot glimmers):
// never "Thinking" while the agent is blocked on them. It reads as Claude desktop's "Needs your input"
// pill: the attention dot and the words on a tinted pill. Once answered, the dot shrinks into the
// Thinking line that takes its place (Leo, 2026-11-05: "there's a little animation that plays. It,
// like, shrinks the thing, the circle into the Thinking... portion afterwards which is cute"), and
// when an ask opens under a line already drawn, the dot grows in the same way (Leo, 2026-11-08: "I
// mostly just meant the yellow circle thing. I thought that was cute").
import { type RefObject, useContext, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { useT } from "../i18n";
import { agentStartLook } from "./agentStart.experiment";
import { compactingLine } from "./compactingLine.experiment";
import { liveLineTimes } from "./liveLineTimes.experiment";
import { oneRowPerCall } from "./oneRowPerCall.experiment";
import { Spinner } from "./icons";
import { RunningTime } from "./RunningTime";
import { BackgroundHint } from "./BackgroundHint";
import { useSubsessionInfo } from "../subagents/subsessions";
import { LiveShimmer } from "./LiveShimmer";
import { JumpDots } from "./JumpDots";
import { useThinkingLook } from "./thinkingLook";
import { Slot } from "../../../slots/Slot";
import { slotVariant, useSlotVariant } from "../../../slots/registry";
import { thinkingIndicatorSlot, type ThinkingIndicatorProps } from "../../../slots/thinkingIndicator";
import { DefaultThinkingIndicator } from "../../../slots/thinkingIndicator/DefaultThinkingIndicator";
import { formatDuration, spanDuration } from "./turns";
import { WAITING_LABEL, type WaitingOn, WaitingOnContext } from "./waitingOn";
import { usePageNow as useTicking } from "../../../ui/pageClock";
import { WorkingCountsContext, workingParts } from "./workingForModel";
import { motionAllowed } from "../subagents/trayMotionModel";
import { verbLeads } from "./toolVerbModel";
import { statusVerbAt, statusVerbLabels, useStatusVerbConfig } from "../statusVerbs";
import { thinkingVerb, ThinkingVerbsContext } from "./thinkingVerbs";
import type { AcpmuxCompaction, AcpmuxTurnRetry } from "../model";
import { retryParts, SILENT_MS, WRITING_MS, liveLead } from "./thinkingModel";
import { CACHE_EXPIRY_REASON } from "./cacheCompaction";
import type { LiveLinePulse } from "./liveLinePulse";
import { type LiveWait, subagentsLabel, waitingLabel } from "./liveWait";
/// False while `key` changed in the last `ms`, true once it held still that long (or there is none).
/// `since`, when known, is when the key's text was written: a key that was already that old when the
/// line mounted (a chat opened long after its reply paused) is quiet from the first frame, instead
/// of counting `ms` from the mount as if it had just moved.
/// `pulse`, on the transcript's live line, moves the key on each chunk without a draw (liveLinePulse.ts):
/// the line draws only when it turns quiet or a chunk ends its quiet.
function useQuiet(
  key: string | undefined,
  ms: number,
  since?: number,
  now: () => number = Date.now,
  pulse?: LiveLinePulse,
): boolean {
  const age = () => (since === undefined ? 0 : Math.max(0, now() - since));
  const [quiet, setQuiet] = useState(() => key === undefined || age() >= ms);
  // The key the line mounted with: only that one is timed from `since`; a later key just moved.
  const mounted = useRef(key);
  // The newest key the line has heard, from its props or the pulse, and when its window ends. A draw
  // that brings a key the pulse already brought (the frame drew for its place, long after the chunk)
  // keeps that window: it is no new chunk.
  const latest = useRef<{ key: string; until: number } | undefined>(undefined);
  // The first streamed assistant chunk inserts the answer and changes `key` in the same commit.
  // The line reads "Writing" before that commit paints; an effect would leave one frame of
  // "Thinking" under the first token. The timer remains an ordinary effect so it never blocks layout.
  useLayoutEffect(() => {
    if (key === undefined) {
      latest.current = undefined;
      setQuiet(true);
      return;
    }
    // When the window ends: `ms` after the key last moved. The timer looks again when it fires, so a
    // chunk heard in between only moves this, never a timer.
    if (latest.current?.key !== key)
      latest.current = { key, until: now() + (key === mounted.current ? ms - age() : ms) };
    const span = latest.current;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const settle = () => {
      const left = span.until - now();
      timer = undefined;
      if (left > 0) timer = setTimeout(settle, left);
      else setQuiet(true);
    };
    if (span.until <= now()) setQuiet(true);
    else {
      setQuiet(false);
      timer = setTimeout(settle, span.until - now());
    }
    const off = pulse?.subscribe(() => {
      const moved = pulse.line()?.quietKey;
      if (moved === undefined || moved === span.key) return;
      span.key = moved;
      span.until = now() + ms;
      setQuiet(false);
      if (timer === undefined) settle();
    });
    return () => {
      off?.();
      if (timer !== undefined) clearTimeout(timer);
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `since` only seeds the mounted key
  }, [key, ms, pulse]);
  return quiet;
}

/// When the transcript's live line last heard anything, to the next whole second, for one heard
/// without a draw (liveLinePulse.ts `heard`); undefined off the transcript. It draws the line at most
/// once a second while events stream, as its clock does, and at once when a silent line hears one.
function useHeardPulse(pulse: LiveLinePulse | undefined): number | undefined {
  const heard = () => pulse?.heard();
  return useSyncExternalStore(pulse?.subscribe ?? noSubscription, heard, heard);
}
const noSubscription = () => () => {};

/// When `key` last changed while the line was mounted (on `now`'s clock), or undefined while it is
/// still the key the line mounted with: the moment the line saw a new event or a new state, for
/// what carries no time of its own (a streamed reply's chunks, a state the line itself derives).
/// `earlier` says when a key was already heard without a draw (the live line's pulse): a draw that
/// brings it late takes that time, or none, never the draw's.
function useChangedAt(
  key: string | undefined,
  now: () => number,
  earlier?: (key: string | undefined) => number | null | undefined,
): number | undefined {
  const [seen, setSeen] = useState<{ key: string | undefined; at?: number }>({ key });
  if (seen.key === key) return seen.at;
  const before = earlier?.(key);
  const next = { key, at: before === undefined ? now() : (before ?? undefined) };
  setSeen(next);
  return next.at;
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
  // `drawn`: the tail these words were last drawn with, kept with them in the render that draws it,
  // so a new roll takes the old words' tail in the render that rolls them. Filled in by a layout
  // effect, each tool call's start or end cost the transcript a second commit (and the line its
  // layout reads again) before the frame painted.
  const [roll, setRoll] = useState<Roll & { drawn: string }>({ key, label, lead, turns: 0, drawn: tail });
  if (key !== roll.key) {
    const rolls = key !== undefined && roll.key !== undefined;
    const next = {
      key,
      label,
      lead,
      // Away clears the count too: the words that come back draw no roll in.
      turns: key === undefined ? 0 : roll.turns + (rolls ? 1 : 0),
      // The old words roll out with the tail they were last drawn with.
      out: rolls
        ? { key: roll.key, label: roll.label, lead: roll.lead, turns: roll.turns, tail: roll.drawn }
        : undefined,
      drawn: tail,
    };
    setRoll(next);
    return next;
  }
  if (label !== roll.label || tail !== roll.drawn) {
    const next = { ...roll, label, lead, drawn: tail };
    setRoll(next);
    return next;
  }
  return roll;
}

/// Whether the live line's boxes may have moved since its last commit: the two hooks below read
/// layout (a forced layout when the commit wrote the DOM) only then, never on a commit that changed
/// nothing drawn, as each streamed chunk does (its new `quietKey` and `heardKey`). They move when
/// what the line draws changes (`drawn`: its words, time, counts and look, compared as effect deps
/// are) or its node is new, both known in the commit itself; or when a box resizes with no commit
/// of the line (the pane's width, a font, a theme's slot), which a ResizeObserver on the line and
/// its boxes marks for the next commit. Read in layout effects only, after this hook's own.
/// The line's boxes as last observed (`useLineMoved`): one ResizeObserver from `connect` to its
/// cleanup, which disconnects it, and the boxes it watches, kept to the line's current ones.
class LineBoxes {
  /// Whether the last commit's `check` found the boxes may have moved. Read in layout effects only.
  moved = true;
  private node: HTMLDivElement | undefined;
  private drawn: readonly unknown[] | undefined;
  private resized = false;
  private observer: ResizeObserver | undefined;
  private boxes = new Map<Element, string>();

  /// One observer for the line's life; the returned cleanup disconnects it.
  connect(): () => void {
    if (typeof ResizeObserver === "undefined") return () => {};
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const box = entry.borderBoxSize?.[0];
        const size = box
          ? `${box.inlineSize}x${box.blockSize}`
          : `${entry.contentRect.width}x${entry.contentRect.height}`;
        const before = this.boxes.get(entry.target);
        this.boxes.set(entry.target, size);
        // A box's first report is its size when observed, already read in that commit.
        if (before !== undefined && before !== size) this.resized = true;
      }
    });
    this.observer = observer;
    return () => {
      observer.disconnect();
      if (this.observer === observer) this.observer = undefined;
      this.boxes = new Map();
      // A remount (Strict Mode's second pass) reads and observes again.
      this.drawn = undefined;
    };
  }

  /// This commit's check: sets `moved`, and observes the line's boxes again when what it draws changed.
  check(node: HTMLDivElement | undefined, drawn: readonly unknown[]) {
    const was = this.drawn;
    const changed =
      node !== this.node ||
      was === undefined ||
      was.length !== drawn.length ||
      drawn.some((value, index) => !Object.is(value, was[index]));
    this.moved = changed || this.resized;
    this.resized = false;
    this.node = node;
    this.drawn = drawn;
    if (changed) this.track(node);
  }

  /// Observe the line, its direct boxes (whose sizes place the counts) and the words' own box; let go
  /// of those gone. Only while connected: the observer's cleanup lets go of every box.
  private track(node: HTMLDivElement | undefined) {
    const observer = this.observer;
    if (!observer) return;
    const boxes = new Set<Element>();
    if (node) {
      boxes.add(node);
      for (const child of node.children) boxes.add(child);
      const words = node.querySelector("output.cv-thinking");
      if (words) boxes.add(words);
    }
    for (const box of this.boxes.keys())
      if (!boxes.has(box)) {
        observer.unobserve(box);
        this.boxes.delete(box);
      }
    for (const box of boxes) if (!this.boxes.has(box)) observer.observe(box);
  }
}

/// Whether the live line's boxes may have moved since its last commit: the two hooks below read
/// layout (a forced layout when the commit wrote the DOM) only then, never on a commit that changed
/// nothing drawn, as each streamed chunk does (its new `quietKey` and `heardKey`). They move when
/// what the line draws changes (`drawn`: its words, time, counts and look, compared as effect deps
/// are) or its node is new, both known in the commit itself; or when a box resizes with no commit
/// of the line (the pane's width, a font, a theme's slot), which a ResizeObserver on the line and
/// its boxes marks for the next commit. Read `moved` in layout effects only, after this hook's own.
function useLineMoved(line: RefObject<HTMLDivElement | null>, drawn: readonly unknown[]): LineBoxes {
  const [boxes] = useState(() => new LineBoxes());
  // One observer for the line's life, disconnected when it unmounts.
  useLayoutEffect(() => boxes.connect(), [boxes]);
  useLayoutEffect(() => {
    boxes.check(line.current ?? undefined, drawn);
  });
  return boxes;
}

/// The old words roll out as they were drawn (review of cmux#41078): cut at the width the words had
/// (ellipsis and all), their time and counts from where they sat, never the full words running their
/// tail on past it. The width as last committed, one read of the line's own box a commit that moved
/// it (`useLineMoved`), set on the roll's copies in the commit that makes them, before paint; refs
/// only in the effect.
function useRollOutWidth(line: RefObject<HTMLDivElement | null>, turns: number, moved: LineBoxes) {
  const drawn = useRef<{ turns: number; width?: number }>({ turns });
  useLayoutEffect(() => {
    const node = line.current;
    if (!node) return;
    const last = drawn.current;
    // Nothing drawn moved: the width read last still holds.
    if (turns === last.turns && !moved.moved) return;
    if (turns !== last.turns && last.width !== undefined) {
      const px = `${last.width}px`;
      const words = node.querySelector<HTMLElement>(":scope .cv-roll-out");
      const tail = node.querySelector<HTMLElement>(":scope .cv-roll-out__tail");
      if (words) words.style.width = px;
      if (tail) tail.style.left = px;
    }
    const width = node.querySelector<HTMLElement>("output.cv-thinking")?.getBoundingClientRect().width;
    drawn.current = { turns, width: width && width > 0 ? width : undefined };
  });
}

/// The line's counts glide to where their words leave them (Leo, 2026-11-11: "the animation system
/// is so borked and unintegrated"): a count that moves sideways while the line does not roll (its
/// time grows a digit, its words change width under one key) slides from where it was drawn on the
/// arrival step, transform only, so it never jumps a frame. A roll moves it with the words instead
/// (`useRoll`), and the gates that stop the roll stop this too.
function useCountGlide(line: RefObject<HTMLDivElement | null>, turns: number, moved: LineBoxes) {
  const drawn = useRef<{ turns: number; lefts: number[] }>({ turns, lefts: [] });
  useLayoutEffect(() => {
    const node = line.current;
    if (!node) return;
    // Nothing drawn moved: the counts sit where they were read last, so none glides.
    if (turns === drawn.current.turns && !moved.moved) return;
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
/// each step replaces in place: "Thinking 18s" (the turn's time), the call in flight ("bun test 13s", or what it says it does, "Run the
/// web tests 13s"), the latest finished step until the next starts (`done`, "Ran grep … 15s"), or
/// "Writing a command 9s" while the agent still writes the command (`draft`). With no call it names
/// what the turn does instead: "Waiting on 2 subagents", "Writing", else "Thinking" (`liveState`).
/// One turn clock follows every phase: "Using repo: repo grep 3m 2s", with no token count or mark
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

/// The one shimmer every status in the live spot draws with (conversation.css `.cv-thinking.is-shimmer`):
/// "Thinking", a step, "Sending message to …", "Waiting", "Writing", a compaction, a retry and a wait
/// on the person alike.
export const SHIMMER_CLASS = "is-shimmer";

export function Thinking({
  starting = false,
  since,
  now = Date.now,
  doing,
  activityDots = false,
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
  liveAgentNames,
  liveCompaction,
  phaseAt,
  heardAt,
  heardKey,
  liveWait,
  waitAt,
  turnTotal = false,
  untimed = false,
  verbKey,
  quietKey,
  quietAt,
  below = false,
  command = false,
  retry,
  pulse,
}: {
  /// The prompt waits for its agent to start (harnessSwitch.ts): the start look's arm draws it.
  starting?: boolean;
  since?: number;
  now?: () => number;
  doing?: string;
  /// The live line draws a look's working dots before its words (thinkingLook.ts `jumpButton: "dots"`).
  activityDots?: boolean;
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
  /// The subagents' names (turns.ts `foregroundAgentNames`): "Waiting on subagent Explore auth".
  liveAgentNames?: readonly string[];
  liveCompaction?: AcpmuxCompaction;
  /// "Thinking" past the first step: when this stretch of thinking began (turns.ts `liveClock`), the
  /// time beside the word ticking from it; and when the turn last heard anything (`heardAt`, and
  /// `heardKey`, which changes with every event), after which SILENT_MS of nothing reads "Waiting".
  phaseAt?: number;
  heardAt?: number;
  heardKey?: string;
  /// What a silent line waits on (liveWait.ts): "Waiting on the model after Read App.tsx", never a
  /// bare "Waiting" (Leo, 2026-11-22: "everything that goes in there write more detailed things than
  /// just waiting").
  liveWait?: LiveWait;
  /// "Waiting on N subagents": when that wait began (turns.ts `codexLiveTurn`), the time beside the
  /// words ticking from it, or from when the line itself turned to the wait, whichever is later.
  waitAt?: number;
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
  /// The transcript's live line hears its chunks and events here without a draw (liveLinePulse.ts).
  pulse?: LiveLinePulse;
} = {}) {
  const t = useT();
  const waiting = useContext(WaitingOnContext);
  const { jumpButton } = useThinkingLook();
  const [answered, settled] = useAnswered(waiting);
  const [asked, grown] = useAsked(waiting);
  const startLook = starting && !waiting ? experimentArm(agentStartLook) : "thinking";
  // A reply that paused only a moment is still being written; one silent for longer is the agent
  // thinking before its next step, which reads "Thinking" (Leo, 2026-11-03).
  const stillWriting = !useQuiet(liveState === "writing" ? quietKey : undefined, WRITING_MS, quietAt, now, pulse);
  // Once the reply has stopped, nothing the agent does is timed until its next step: the line says
  // "Thinking" with no clock or token count, which until the turn's end ticked on under the reply as if
  // the agent still worked (Leo, 2026-11-12: "the thinking timer is overstaying its welome after you
  // just replied!"). The next call, thought or reply brings the turn's clock back.
  const replied = liveState === "writing" && !stillWriting;
  // The turn's time, from the prompt, whatever the line names: it keeps counting across steps and
  // never starts again at a call (Leo, 2026-11-01: "it should just keep going").
  const from = untimed || replied ? undefined : since;
  const timed = !waiting && from !== undefined;
  // The clock also runs on a line with no time of its own (the turn's clock over the work,
  // liveTurnClock.experiment.ts `top`) while it could fall silent, so it can say "Waiting".
  const listening = !waiting && turnTotal && heardAt !== undefined && doing === undefined;
  const time = useTicking(timed || listening, now);
  // The countdown to the harness's next try ticks each second while a deadline is announced.
  const retryNow = useTicking(retry?.retryAt !== undefined, now);
  const statusVerbConfig = useStatusVerbConfig();
  const thinkingVerbs = useContext(ThinkingVerbsContext);
  const verbs = useMemo(
    () => thinkingVerbs ?? statusVerbLabels(t, statusVerbConfig),
    [t, statusVerbConfig, thinkingVerbs],
  );
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
  // The line's state is the live one, read on the page's clock each second, never the last event's
  // kind: a turn past its first step that has heard nothing for SILENT_MS is not seen thinking, so
  // it says "Waiting" with the time since it last heard, never a stale "Thinking 683ms" (Leo,
  // 2026-11-12: "the whatever ms gets stuck and becomes false really quickly.... or else gets
  // stale?"). It last heard at the rows' latest dated moment, or when a new event reached the line.
  const heardChanged = useChangedAt(
    heardKey,
    now,
    pulse && ((key) => (key !== undefined && pulse.line()?.heardKey === key ? (pulse.heard() ?? null) : undefined)),
  );
  const heardPulse = useHeardPulse(pulse);
  const heard = heardAt === undefined ? undefined : Math.max(heardAt, heardChanged ?? heardAt, heardPulse ?? heardAt);
  const thinkingNow = doing === undefined && !waitsOnAgents && !writing && !compacting;
  const silent = thinkingNow && listening && heard !== undefined && time - heard >= SILENT_MS;
  // How long it has heard nothing: the one time on a waiting line, whichever clock the turn shows.
  const silentFor = silent && heard !== undefined ? formatDuration(Math.max(0, time - heard)) : undefined;
  // This stretch of thinking began when the turn's rows say (`phaseAt`), or later, when the line
  // itself turned to Thinking (a reply gone quiet, a silence that ended).
  const stateChanged = useChangedAt(
    silent ? "waiting" : thinkingNow ? "thinking" : waitsOnAgents ? "subagents" : "other",
    now,
  );
  const thinkingFrom = phaseAt === undefined ? stateChanged : Math.max(phaseAt, stateChanged ?? phaseAt);
  // The subagent wait's own start: the turn's rows say when it began (`waitAt`), or later, when the
  // line itself turned to the wait. Never the prompt: a turn that worked 5m before it waited 2m reads
  // "Waiting on 1 subagent 2m" (Leo, 2026-11-20, on "waiting on one sub-agent for seven minutes and
  // 39 seconds").
  const waitFrom = waitAt === undefined ? stateChanged : Math.max(waitAt, stateChanged ?? waitAt);
  const decorative = thinkingNow && !silent;
  const idleLabel = compacting
    ? t(
        liveCompaction?.reason === "account_switch"
          ? "compaction.runningAccountSwitch"
          : liveCompaction?.reason === CACHE_EXPIRY_REASON
            ? "compaction.runningCacheExpiry"
            : "turn.live.compacting",
      )
    : waitsOnAgents
      ? subagentsLabel(t, liveAgents, liveAgentNames)
      : writing
        ? t("turn.live.writing")
        : silent
          ? waitingLabel(t, liveWait)
          : (turnVerb ??
            (statusVerbConfig.mode === "custom" ? statusVerbAt(elapsedMs, { mode: "custom", verbs }) : t("thinking")));
  const label =
    doing === undefined
      ? idleLabel
      : sendName !== undefined
        ? t("send.sending", { target: sendName })
        : doingShell
          ? doing
            ? done
              ? t("tools.ranCommand", { command: doing })
              : doing
            : draft
              ? t("tools.writingCommand")
              : done
                ? t("tools.ranUnnamed")
                : idleLabel
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
  // "it should just keep going"): a finished step's own start to end, the time since this stretch of thinking began, or since a
  // silent turn last heard anything ("Waiting 12s").
  const compactMs = compacting && timed && doingAt !== undefined ? Math.max(0, time - doingAt) : undefined;
  const ownMs = compacting
    ? compactLook === "turn"
      ? compactMs
      : undefined
    : doing === undefined
      ? silent && heard !== undefined
        ? Math.max(0, time - heard)
        : waitsOnAgents
          ? // A wait from the turn's start has the turn's clock alone, which is already the wait's.
            from === undefined || waitFrom === undefined || waitFrom - from < 1_000
            ? undefined
            : Math.max(0, time - waitFrom)
          : writing ||
              from === undefined ||
              thinkingFrom === undefined ||
              thinkingFrom - from < 1_000 ||
              time - thinkingFrom < 1_000
            ? undefined
            : time - thinkingFrom
      : done
        ? doneMs
        : undefined;
  // A finished step's time under a second says its milliseconds, as the step's own row does
  // ("856ms"), never "0s"; a live clock ticks in whole seconds, like the turn's beside it.
  // Two bare durations never stand side by side: each is named, "step 3s · turn 21s" (Leo's capture,
  // 2026-11-07, of "python3 - <<'EOF' 3s · 21s · 549 tokens"; liveLineTimes.experiment.ts).
  const timesLook = experimentArm(liveLineTimes);
  const ownTime =
    timesLook !== "turn" && total && ownMs !== undefined
      ? compacting || doing === undefined
        ? formatDuration(ownMs)
        : spanDuration(t, ownMs)
      : undefined;
  // Only a finished step's time is named "step": the thinking time beside "Thinking" (or a
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
    : silentFor !== undefined && own === undefined
      ? silentFor
      : waitsOnAgents && own === undefined && ownMs !== undefined
        ? // One clock (the `turn` look): beside "Waiting on 1 subagent" it is the wait's, never the
          // turn's, which read 7m 39s for a two-minute wait (Leo, 2026-11-20).
          formatDuration(ownMs)
        : (own ?? turnTime);
  // What follows the time (the page a background command serves); the tray counts the running work.
  const counts = useContext(WorkingCountsContext);
  const parts = counts && !waiting ? workingParts(counts) : [];
  // What follows the words, as text: their time, the turn's clock and counts, for the old line's copy
  // to roll out with them (`useRoll`).
  const tail = [
    elapsed,
    own && !waiting && timesLook !== "hover" ? turnClock : undefined,
    ...parts.map((part) => part.label),
  ]
    .filter(Boolean)
    .join(" · ");
  const roll = useRoll(away ? undefined : decorative ? "" : sameCall ? `\u0000${call}` : label, label, lead, tail);
  const lineRef = useRef<HTMLDivElement>(null);
  // Every status in this spot shimmers as "Thinking" does, a wait and each compaction look too: one
  // look for the live spot, no plain or white special case (Leo, 2026-11-22: "the "waiting" also
  // shouldnt be special cased as white. all in the "thinking" spot should glimmer like that").
  // Everything the line draws that sizes or places its words and counts; a streamed chunk changes
  // none of it (its `quietKey` and `heardKey` only time the line).
  const moved = useLineMoved(lineRef, [
    below,
    waiting,
    asked,
    answered,
    decorative,
    compacting,
    label,
    lead?.lead,
    lead?.rest,
    verbs,
    elapsed,
    own,
    turnClock,
    timesLook,
    tail,
    roll.out?.tail,
    command && !done && doing !== undefined ? doingAt : undefined,
  ]);
  useRollOutWidth(lineRef, roll.turns, moved);
  useCountGlide(lineRef, roll.turns, moved);
  // The question card already asks for an answer above the composer.
  if (waiting === "question") return null;
  // A model the harness cannot reach: said calmly in the line's own box, so nothing moves when it
  // starts or ends (Leo, 2026-11-03). What the chat waits on the person for still comes first.
  if (retry && !waiting) {
    const parts = retryParts(t, retry, retryNow);
    return (
      <div
        className={`cv-worked cv-worked--live${below ? " is-below" : ""}`}
        data-find-skip
        data-lead-slot
        data-retrying=""
      >
        <output className={`cv-thinking ${SHIMMER_CLASS} cv-retrying`}>
          <span className="cv-shimmer__row">
            <LiveShimmer label={parts.label} />
          </span>
        </output>
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          {parts.count}
        </span>
        {parts.countdown && (
          <span className="cv-worked__count" data-retry-countdown="">
            <span className="cv-worked__sep" aria-hidden="true">
              ·
            </span>
            {parts.countdown}
          </span>
        )}
        {parts.error && (
          <span className="cv-worked__count cv-retrying__error">
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
        <output className={`cv-thinking ${SHIMMER_CLASS} cv-waiting`} data-waiting={waiting}>
          <span
            className={`cv-needs-input-glyph${asked ? " is-asked" : ""}`}
            aria-hidden="true"
            onAnimationEnd={asked ? grown : undefined}
          />
          <span className="cv-waiting__pill">
            <span className="cv-shimmer__row">
              <LiveShimmer label={t(WAITING_LABEL[waiting])} />
            </span>
          </span>
        </output>
      ) : (
        <span className="cv-shimmer__row">
          {activityDots && jumpButton === "dots" && !done && !answered && <JumpDots inline />}
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
              // Marks a copy whose time and counts roll out beside it (`cv-roll-out__tail`).
              data-tail={roll.out.tail ? `\u2002${roll.out.tail}` : undefined}
            />
          )}
          {roll.out?.tail && (
            // The old line's time and counts, from where they sat after its words (their drawn width).
            <span
              key={`tail-${roll.turns}`}
              className="cv-roll-out__tail"
              aria-hidden="true"
              inert
              data-tail={`\u2002${roll.out.tail}`}
            />
          )}
          <output
            className={`cv-thinking ${SHIMMER_CLASS}`}
            data-roll={roll.turns === 0 ? undefined : roll.turns % 2 ? "odd" : "even"}
            aria-label={decorative ? t("thinking") : undefined}
            aria-live={decorative ? "off" : undefined}
          >
            <LiveWords
              decorative={decorative}
              label={label}
              lead={lead}
              verbs={verbs}
              elapsed={elapsed}
              elapsedMs={elapsedMs}
            />
          </output>
          {elapsed && (
            // tooltip-allow: a time; the tooltip is the one place the whole turn's time shows.
            <span className={own ? "cv-worked__own" : "cv-worked__time"} title={turnTitle}>
              {elapsed}
            </span>
          )}
          {/* With the turn's clock over the work ("Working for"), the line has no time of its own: a
              call running there counts how long it has run, from a few seconds on (RunningTime.tsx). */}
          {untimed && !elapsed && !done && !waiting && doing !== undefined && <RunningTime startedAt={doingAt} local />}
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
