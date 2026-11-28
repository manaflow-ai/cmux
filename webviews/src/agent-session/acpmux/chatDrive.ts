// `cmux app chat drive`: what the composer does while a person's pointer rests on a thumbnail and
// the wheel scrolls, measured in the person's own app (Release too), through
// `window.cmuxAcpmuxBridge.drive`. A person saw the composer flicker with the pointer on a screenshot
// preview while they scrolled; the host holds a real hover at the point `begin` returns and sends
// real wheel ticks, and this page counts, per frame, the composer's renders and DOM changes, the
// hover, the card, the scroll and the focus.
//
// Nothing runs unless a drive does: the composer's renders call `composerProbe.render`, which is null
// at rest, and the frame loop, observers and listeners exist only between `begin` and `end`. A host
// that never calls `end` still leaves nothing: the page ends the run itself `seconds + 2` s in.
//
// `type` types into the composer the way a person's keys reach it as far as a page can: the editor
// (ProseMirror) focused, then `execCommand("insertText")`, which fires trusted beforeinput and input
// and changes the field's DOM, which ProseMirror reads into its state and the composer's. What it
// typed stays in the draft: nothing is restored, and the focus is left where typing put it.

import {
  browserEnv,
  type CaptureEnv,
  layoutShiftSummary,
  unmeasuredReason,
  visibilitySummary,
} from "./chatPerfCapture";
import { focusRoute } from "../../ui/focusRoute";
import { intl } from "../../ui/intl";
import { focusedArea } from "./composerFocus";
import { composerProbe, type ComposerPart } from "./composerProbe";
import { COMPOSER_EDITOR } from "./composerSelectors";
import { percentile, round2 } from "./perf";
import { SENT_IMAGE, TOOL_SCREENSHOT } from "./transcriptSelectors";

/** The longest drive the page runs, in seconds. */
export const MAX_DRIVE_SECONDS = 60;
/** The page ends a run itself this long past its `seconds`, so a host that died leaves nothing. */
export const BACKSTOP_EXTRA_SECONDS = 2;
/** The most frames the report lists; `totals` counts every frame. */
export const MAX_REPORT_FRAMES = 2000;
/** The most entries `input_sequence` keeps. */
const MAX_INPUT_SEQUENCE = 200;
/** A test id a target may name: nothing that could be read as another selector. */
const TEST_ID = /^[A-Za-z0-9_-]{1,80}$/;
/** A person's key in the composer this recently means they are typing: no drive types over them. */
export const PERSON_TYPING_MS = 2000;
/** The most UTF-16 units `type.text` may hold. */
export const MAX_TYPE_UNITS = 2000;
/** Text no person types key by key: C0 and C1 controls, DEL, and the line and paragraph separators. */
// oxlint-disable-next-line no-control-regex -- matching control characters is the point.
const UNTYPED = /[\u0000-\u001F\u007F-\u009F\u2028\u2029]/;
/** A pointer this far from the point the host holds is a person's, not the host's. */
const HOLD_SLOP_PX = 4;

const COMPOSER = ".acpmux-composer";
const SCROLLER = ".acpmux-scroll";
/** The pointer and wheel events the report counts, as the engine delivers them to the page. */
const INPUT_TYPES = [
  "pointerover",
  "pointermove",
  "pointerout",
  "mouseover",
  "mousemove",
  "mouseout",
  "wheel",
] as const;
/** The target's own enter and leave: they go to each element entered, never through the window. */
const TARGET_INPUT_TYPES = ["pointerenter", "pointerleave", "mouseenter", "mouseleave"] as const;

export type DriveOptions = {
  target?: { test_id?: unknown; sent_image?: unknown; tool_screenshot?: unknown };
  allow_busy?: unknown;
  type?: { text?: unknown; allow_draft?: unknown };
  seconds?: unknown;
};

/** What a drive reads from the pane (App.tsx): whether a turn runs, and the composer's draft. */
export type DriveHost = {
  busy(): boolean;
  /** Undefined when no composer shows. */
  draft(): { text: string; attachments: readonly unknown[] } | undefined;
};

/** What a drive needs from the page beyond the DOM; tests pass fakes. */
export type DriveEnv = Pick<
  CaptureEnv,
  | "now"
  | "requestFrame"
  | "cancelFrame"
  | "setTimer"
  | "clearTimer"
  | "visibility"
  | "onVisibilityChange"
  | "observe"
  | "supportedEntryTypes"
>;

type Frame = {
  t_ms: number;
  dt_ms: number;
  composer_renders: number;
  composer_mutations: number;
  hovered: boolean | null;
  card_open: boolean | null;
  scroll_top: number | null;
  focus_changed: boolean;
  focus_within_changed: boolean;
  page_inactive_changed: boolean;
  layout_shift: number | null;
  wheel_events: number;
};

type Run = {
  seconds: number;
  start: number;
  env: DriveEnv;
  target: Element | undefined;
  composer: Element;
  frames: Frame[];
  intervals: number[];
  frameCount: number;
  lastFrame: number | undefined;
  /// Counts since the last frame, and over the run.
  now: { renders: number; mutations: number; wheels: number; shift: number };
  totals: {
    renders: Record<ComposerPart, number>;
    mutations: number;
    wheels: number;
    wheelTrusted: number;
    focusFlips: number;
    focusWithinFlips: number;
    inactiveFlips: number;
    focusEvents: number;
  };
  mutatedNodes: WeakSet<Node>;
  mutationNodes: number;
  shifts: { value: number; hadRecentInput?: boolean }[] | null;
  visibility: { at: number; state: string }[];
  inputs: Record<string, { count: number; trusted: number }>;
  sequence: { type: string; trusted: boolean; count: number }[];
  last: { active: Element | null; within: boolean; inactive: boolean };
  focusBefore: { area: string; within: boolean };
  inactiveBefore: boolean;
  type: { text: string[]; asked: number; typed: string; count: number; stopped: string | null } | undefined;
  /// Our own execCommand is running: its trusted input events are not the person's.
  typingNow: boolean;
  personTypedAt: number | undefined;
  /// A person's own input showed up during the run (`state().person_active`), and which first: a key,
  /// a press, or a pointer that left the point the host holds.
  personActive: "key" | "press" | "pointer" | null;
  /// The point the host holds, and whether its pointer has reached it yet.
  hold: { x: number; y: number; reached: boolean } | undefined;
  scrolledIntoView: { from: number; to: number } | null;
  /// Takes the composer's DOM changes still queued for the observer's callback.
  flushMutations: () => void;
  cleanups: (() => void)[];
};

const pageInactive = () => document.documentElement.hasAttribute("data-page-inactive");
const within = (composer: Element) => composer.matches(":focus-within");

/// The `n`th (1-based) element matching `selector`, in document order.
function nth(selector: string, n: unknown): Element | undefined {
  if (typeof n !== "number" || !Number.isInteger(n) || n < 1) return undefined;
  return document.querySelectorAll(selector)[n - 1] ?? undefined;
}

/**
 * The element a target names, undefined when none matches. `sent_image`: the nth sent image thumbnail
 * (SENT_IMAGE) among those the transcript has mounted; `tool_screenshot`: the nth image a tool result
 * shows (TOOL_SCREENSHOT: a closed row's preview at its edge, an opened row's strip image).
 */
export function driveTarget(target: NonNullable<DriveOptions["target"]>): Element | undefined {
  if (target.test_id !== undefined) {
    if (typeof target.test_id !== "string" || !TEST_ID.test(target.test_id)) return undefined;
    return document.querySelector(`[data-testid="${target.test_id}"]`) ?? undefined;
  }
  if (target.sent_image !== undefined) return nth(SENT_IMAGE, target.sent_image);
  if (target.tool_screenshot !== undefined) return nth(TOOL_SCREENSHOT, target.tool_screenshot);
  return undefined;
}

/**
 * Whether `target`'s hover card is open: the card of the hover-card trigger the target is or holds
 * (`data-cmux-hover-card`, its card's bridge id: a tool screenshot's preview, ToolVisualPreview.tsx)
 * is mounted, open (Base UI's `data-open`) and not closing (`data-ending-style`). Null when the target
 * has no hover card: a sent image thumbnail has none on the page (its name is the native `title`
 * tooltip, which the page cannot see), nor has an opened tool row's strip image.
 */
export function cardOpen(target: Element | undefined): boolean | null {
  if (!target) return null;
  const trigger = target.closest("[data-cmux-hover-card]") ?? target.querySelector("[data-cmux-hover-card]");
  const id = trigger?.getAttribute("data-cmux-hover-card");
  if (!id) return null;
  const card = document.querySelector(`.ui-tooltip[data-cmux-hover-bridge="${id}"]`);
  return card !== null && card.hasAttribute("data-open") && !card.hasAttribute("data-ending-style");
}

function rectOf(element: Element) {
  const box = element.getBoundingClientRect();
  return { x: round2(box.x), y: round2(box.y), width: round2(box.width), height: round2(box.height) };
}

/** The transcript's offset and size, and its box in the viewport (where a host wheels with no target). */
function scrollerBox(scroller: HTMLElement) {
  const { x, y, width } = rectOf(scroller);
  return {
    top: round2(scroller.scrollTop),
    height: scroller.clientHeight,
    scroll_height: scroller.scrollHeight,
    x,
    y,
    width,
  };
}

const IDLE_COST =
  "At rest the composer's render pays one null check (composerProbe.render) and nothing else runs; the frame loop, observers and listeners exist only between begin and end, or until the page's own end seconds + 2 s in.";

/** The page's one drive. */
export class ChatDrive {
  private run: Run | undefined;
  /// The last run's target, so `state()` still reads it after `end()` (the host releases its hover
  /// after the run and asks whether the card went away).
  private lastTarget: Element | undefined;
  private lastRun: Run | undefined;
  /// The report of a run the page ended itself, for the `end()` that comes late.
  private backstopReport: Record<string, unknown> | undefined;

  get active(): boolean {
    return this.run !== undefined;
  }

  async begin(options: DriveOptions, host: DriveHost, env: DriveEnv = browserEnv()): Promise<Record<string, unknown>> {
    if (this.run) return { error: "running" };
    if (host.busy() && options.allow_busy !== true) return { error: "busy" };
    const composer = document.querySelector(COMPOSER);
    const draft = host.draft();
    if (!composer || !draft) return { error: "no_composer" };
    const typing = options.type;
    // One person's key per character as they see it: an emoji with its modifiers is one.
    const text =
      typeof typing?.text === "string"
        ? Array.from(
            intl.Segmenter(undefined, { granularity: "grapheme" }).segment(typing.text),
            (part) => part.segment,
          )
        : [];
    if (typing && !document.querySelector(COMPOSER_EDITOR)) return { error: "no_composer" };
    if (typing && (typeof typing.text !== "string" || typing.text.length > MAX_TYPE_UNITS || UNTYPED.test(typing.text)))
      return { error: "bad_text" };
    // `!` typed first into an empty prompt switches the composer to shell mode (Composer.tsx promptBeforeInput).
    if (typing && draft.text === "" && (typing.text as string).startsWith("!")) return { error: "shell_prefix" };
    if (typing && (draft.text.trim() || draft.attachments.length) && typing.allow_draft !== true)
      return { error: "draft_not_empty" };
    // The page keeps no time of a person's last key in the composer (Composer.tsx's `typedAt` resets
    // after each change), so a key before `begin` is not seen; `personActive` reports those after it.
    let target: Element | undefined;
    let point: Record<string, number> | undefined;
    // The target comes into view by moving the person's transcript: the move is reported.
    let scrolledIntoView: { from: number; to: number } | null = null;
    if (options.target) {
      target = driveTarget(options.target);
      if (!target) return { error: "no_target" };
      const moved = document.querySelector<HTMLElement>(SCROLLER);
      const from = moved ? round2(moved.scrollTop) : null;
      target.scrollIntoView({ behavior: "instant", block: "nearest" });
      if (moved && from !== null) scrolledIntoView = { from, to: round2(moved.scrollTop) };
      const box = rectOf(target);
      const [x, y] = [round2(box.x + box.width / 2), round2(box.y + box.height / 2)];
      const hit = document.elementFromPoint(x, y);
      if (!hit || !target.contains(hit)) return { error: "target_covered" };
      point = { x, y, width: box.width, height: box.height };
    }
    const requested = Number(options.seconds);
    const seconds = Number.isFinite(requested) ? Math.min(MAX_DRIVE_SECONDS, Math.max(1, requested)) : 5;
    const scroller = document.querySelector<HTMLElement>(SCROLLER);
    const start = env.now();
    const run: Run = {
      seconds,
      start,
      env,
      target,
      composer,
      frames: [],
      intervals: [],
      frameCount: 0,
      lastFrame: undefined,
      now: { renders: 0, mutations: 0, wheels: 0, shift: 0 },
      totals: {
        renders: { composer: 0, box: 0 },
        mutations: 0,
        wheels: 0,
        wheelTrusted: 0,
        focusFlips: 0,
        focusWithinFlips: 0,
        inactiveFlips: 0,
        focusEvents: 0,
      },
      mutatedNodes: new WeakSet(),
      mutationNodes: 0,
      shifts: null,
      visibility: [{ at: start, state: env.visibility() }],
      inputs: {},
      sequence: [],
      last: { active: document.activeElement, within: within(composer), inactive: pageInactive() },
      focusBefore: { area: focusedArea(document.activeElement), within: within(composer) },
      inactiveBefore: pageInactive(),
      type: typing ? { text, asked: text.length, typed: "", count: 0, stopped: null } : undefined,
      typingNow: false,
      personTypedAt: undefined,
      personActive: null,
      hold: point ? { x: point.x, y: point.y, reached: false } : undefined,
      scrolledIntoView,
      flushMutations: () => {},
      cleanups: [],
    };
    this.run = run;
    this.lastTarget = target;
    this.lastRun = run;
    this.backstopReport = undefined;
    const cleanups = run.cleanups;
    composerProbe.render = (part) => {
      run.now.renders += 1;
      run.totals.renders[part] += 1;
    };
    cleanups.push(() => {
      composerProbe.render = null;
    });
    const mutations = new MutationObserver((records) => this.mutated(run, records));
    mutations.observe(composer, { subtree: true, attributes: true, childList: true, characterData: true });
    run.flushMutations = () => this.mutated(run, mutations.takeRecords());
    cleanups.push(() => {
      run.flushMutations();
      mutations.disconnect();
    });
    const listen = (type: string, listener: (event: Event) => void) => {
      window.addEventListener(type, listener, { capture: true, passive: true });
      cleanups.push(() => window.removeEventListener(type, listener, { capture: true }));
    };
    for (const type of INPUT_TYPES) listen(type, (event) => this.input(run, event));
    for (const type of target ? TARGET_INPUT_TYPES : []) {
      const listener = (event: Event) => this.input(run, event);
      target!.addEventListener(type, listener, { passive: true });
      cleanups.push(() => target!.removeEventListener(type, listener));
    }
    listen("focusin", () => (run.totals.focusEvents += 1));
    listen("focusout", () => (run.totals.focusEvents += 1));
    // A person's own key or text (`personActive`, `state().person_active`); our own typing's are not
    // theirs. The host never presses a key or a button, so any is a person's.
    const typed = (event: Event) => {
      if (run.typingNow || !event.isTrusted) return;
      run.personActive ??= "key";
      if (event.target instanceof Node && composer.contains(event.target)) run.personTypedAt = env.now();
    };
    listen("keydown", typed);
    listen("beforeinput", typed);
    listen("pointerdown", (event) => {
      if (event.isTrusted) run.personActive ??= "press";
    });
    cleanups.push(env.onVisibilityChange(() => run.visibility.push({ at: env.now(), state: env.visibility() })));
    if (env.supportedEntryTypes().includes("layout-shift")) {
      const shifts: { value: number; hadRecentInput?: boolean }[] = [];
      const observer = env.observe("layout-shift", (entries) => {
        for (const entry of entries as { value: number; hadRecentInput?: boolean }[]) {
          shifts.push(entry);
          if (!entry.hadRecentInput) run.now.shift += entry.value;
        }
      });
      if (observer) {
        run.shifts = shifts;
        cleanups.push(() => observer.disconnect());
      }
    }
    let frame = env.requestFrame((time) => onFrame(time));
    const onFrame = (time: number) => {
      this.frame(run, time);
      frame = env.requestFrame(onFrame);
    };
    cleanups.push(() => env.cancelFrame(frame));
    const backstop = env.setTimer(
      () => {
        if (this.run === run) this.backstopReport = { ...this.finish(run), ended_by: "backstop" };
      },
      (seconds + BACKSTOP_EXTRA_SECONDS) * 1000,
    );
    cleanups.push(() => env.clearTimer(backstop));
    return {
      ok: true,
      ...(point ? { point } : {}),
      device_pixel_ratio: window.devicePixelRatio,
      scroller: scroller ? scrollerBox(scroller) : null,
      scrolled_into_view: scrolledIntoView,
    };
  }

  /** The target's hover and card and the transcript's offset now; callable after `end` too. */
  state(): Record<string, unknown> {
    const target = this.run?.target ?? this.lastTarget;
    const scroller = document.querySelector<HTMLElement>(SCROLLER);
    return {
      hovered: target ? target.matches(":hover") : null,
      card_open: cardOpen(target),
      scroll_top: scroller ? round2(scroller.scrollTop) : null,
      running: this.run !== undefined,
      // A person's key, press or pointer showed up during the current (or last) run.
      person_active: (this.run ?? this.lastRun)?.personActive != null,
    };
  }

  /**
   * Whether a person is at the page during the run: `typing_ms_ago` since their last trusted key or
   * text in the composer (null: none since `begin`), and `pointer_inside`, the engine's own `:hover` on
   * the page's root (the pointer is over the page).
   */
  personActive(): Record<string, unknown> {
    const run = this.run;
    const at = run?.personTypedAt;
    return {
      typing_ms_ago: run && at !== undefined ? round2(run.env.now() - at) : null,
      pointer_inside: document.documentElement.matches(":hover"),
    };
  }

  /** Ends the run and returns its report; removes every observer, listener and the probe. */
  async end(): Promise<Record<string, unknown>> {
    const run = this.run;
    if (run) return { ...this.finish(run), ended_by: "end" };
    const late = this.backstopReport;
    this.backstopReport = undefined;
    return late ?? { error: "not_running" };
  }

  private mutated(run: Run, records: MutationRecord[]): void {
    run.now.mutations += records.length;
    run.totals.mutations += records.length;
    for (const record of records) {
      if (run.mutatedNodes.has(record.target)) continue;
      run.mutatedNodes.add(record.target);
      run.mutationNodes += 1;
    }
  }

  private input(run: Run, event: Event): void {
    // The host's pointer goes to the point it holds and stays: one that moves off it after is a person's.
    const hold = run.hold;
    if (hold && event.isTrusted && event.type === "pointermove") {
      const { clientX, clientY } = event as PointerEvent;
      const near = Math.hypot(clientX - hold.x, clientY - hold.y) <= HOLD_SLOP_PX;
      if (near) hold.reached = true;
      else if (hold.reached) run.personActive ??= "pointer";
    }
    const seen = (run.inputs[event.type] ??= { count: 0, trusted: 0 });
    seen.count += 1;
    if (event.isTrusted) seen.trusted += 1;
    if (event.type === "wheel") {
      run.now.wheels += 1;
      run.totals.wheels += 1;
      if (event.isTrusted) run.totals.wheelTrusted += 1;
    }
    // A run of one type (moves, an enter on each element the pointer entered) is one entry.
    const last = run.sequence.at(-1);
    if (last && last.type === event.type && last.trusted === event.isTrusted) last.count += 1;
    else if (run.sequence.length < MAX_INPUT_SEQUENCE)
      run.sequence.push({ type: event.type, trusted: event.isTrusted, count: 1 });
  }

  /// One display frame: what changed since the last, then the next typed character.
  private frame(run: Run, time: number): void {
    // MutationObserver delivers in a microtask: records still queued belong to this frame.
    run.flushMutations();
    const active = document.activeElement;
    const focusWithin = within(run.composer);
    const inactive = pageInactive();
    const changed = {
      focus: active !== run.last.active,
      within: focusWithin !== run.last.within,
      inactive: inactive !== run.last.inactive,
    };
    if (changed.focus) run.totals.focusFlips += 1;
    if (changed.within) run.totals.focusWithinFlips += 1;
    if (changed.inactive) run.totals.inactiveFlips += 1;
    run.last = { active, within: focusWithin, inactive };
    const dt = run.lastFrame === undefined ? 0 : time - run.lastFrame;
    if (run.lastFrame !== undefined) run.intervals.push(dt);
    run.lastFrame = time;
    run.frameCount += 1;
    if (run.frames.length < MAX_REPORT_FRAMES) {
      const scroller = document.querySelector<HTMLElement>(SCROLLER);
      run.frames.push({
        t_ms: round2(time - run.start),
        dt_ms: round2(dt),
        composer_renders: run.now.renders,
        composer_mutations: run.now.mutations,
        hovered: run.target ? run.target.matches(":hover") : null,
        card_open: cardOpen(run.target),
        scroll_top: scroller ? round2(scroller.scrollTop) : null,
        focus_changed: changed.focus,
        focus_within_changed: changed.within,
        page_inactive_changed: changed.inactive,
        layout_shift: run.shifts ? Math.round(run.now.shift * 10_000) / 10_000 : null,
        wheel_events: run.now.wheels,
      });
    }
    run.now = { renders: 0, mutations: 0, wheels: 0, shift: 0 };
    this.typeNext(run);
  }

  /// One character into the composer, as a key's text reaches it: the editor focused, then the
  /// browser's own text insertion. Focus that left the composer stops the typing (a person's keys
  /// would have gone there too), and is never put back.
  private typeNext(run: Run): void {
    const typing = run.type;
    if (!typing || typing.stopped || typing.text.length === 0) return;
    // A person typed during the run: their keys go first, and the drive types no more over them.
    if (run.personTypedAt !== undefined) {
      typing.stopped = "person";
      return;
    }
    const editor = document.querySelector<HTMLElement>(COMPOSER_EDITOR);
    if (!editor) {
      typing.stopped = "no_composer";
      return;
    }
    const focused = editor.contains(document.activeElement);
    if (!focused && typing.typed) {
      typing.stopped = "focus_left";
      return;
    }
    // The caller named this chat and asked to type: a system move, which the route refuses while
    // the person types into another input.
    if (!focused && !focusRoute(editor, "system", "cmux app chat drive --type into this chat's composer")) {
      typing.stopped = "focus_refused";
      return;
    }
    // The first character goes after the draft, never over a selection in it: an insert replaces what
    // is selected, and with allow_draft that is the person's text.
    if (typing.count === 0) {
      const selection = document.getSelection();
      if (selection) {
        const end = document.createRange();
        end.selectNodeContents(editor);
        end.collapse(false);
        selection.removeAllRanges();
        selection.addRange(end);
      }
    }
    const char = typing.text.shift()!;
    run.typingNow = true;
    try {
      if (document.execCommand("insertText", false, char)) {
        typing.typed += char;
        typing.count += 1;
      } else typing.stopped = "insert_refused";
    } finally {
      run.typingNow = false;
    }
  }

  private finish(run: Run): Record<string, unknown> {
    for (const cleanup of run.cleanups.reverse()) cleanup();
    this.run = undefined;
    const end = run.env.now();
    run.visibility.push({ at: end, state: run.env.visibility() });
    const elapsed = (end - run.start) / 1000;
    const visibility = visibilitySummary(run.visibility, end);
    const reason = unmeasuredReason(elapsed, run.frameCount, visibility);
    const intervals = [...run.intervals].sort((a, b) => a - b);
    const typing = run.type;
    const shown = run.frames;
    return {
      measured: reason === null,
      ...(reason ? { unmeasured_reason: reason } : {}),
      visibility,
      seconds: run.seconds,
      seconds_elapsed: round2(elapsed),
      frames: shown,
      frames_truncated: run.frameCount - shown.length,
      totals: {
        frames: run.frameCount,
        composer_renders: run.totals.renders.composer + run.totals.renders.box,
        composer_renders_by: { ...run.totals.renders },
        composer_mutations: run.totals.mutations,
        mutation_nodes: run.mutationNodes,
        focus_flips: run.totals.focusFlips,
        focus_within_flips: run.totals.focusWithinFlips,
        focus_events: run.totals.focusEvents,
        page_inactive_flips: run.totals.inactiveFlips,
        wheel_events: run.totals.wheels,
        wheel_trusted: run.totals.wheelTrusted,
        layout_shift: run.shifts ? layoutShiftSummary(run.shifts).sum : null,
        hovered_frames: run.target ? shown.filter((frame) => frame.hovered).length : null,
        card_open_frames: cardOpen(run.target) === null ? null : shown.filter((frame) => frame.card_open).length,
        frame_p50_ms: round2(percentile(intervals, 0.5)),
        frame_p95_ms: round2(percentile(intervals, 0.95)),
        frame_max_ms: round2(intervals.at(-1) ?? 0),
        over_33_ms: intervals.filter((interval) => interval > 33).length,
      },
      ...(run.shifts ? {} : { layout_shift_unavailable: "the engine has no layout-shift entries (WebKit)" }),
      input_events: run.inputs,
      input_sequence: run.sequence,
      focus: {
        before: run.focusBefore.area,
        after: focusedArea(document.activeElement),
        composer_focus_within_before: run.focusBefore.within,
        composer_focus_within_after: within(run.composer),
      },
      page_inactive: { before: run.inactiveBefore, after: pageInactive() },
      // How many characters (graphemes) the run typed; they stay in the draft, nothing is restored.
      // A count, never the text: the report goes to the CLI's output and to logs.
      typed: typing ? typing.count : null,
      // How many were asked for: with `typed`, a caller tells a run that typed it all from one cut off.
      type_asked: typing ? typing.asked : null,
      draft_left: typing ? typing.typed.length > 0 : false,
      // A person's key the run ended on, before a frame's typing acted on it, is theirs all the same; other
      // text left when the run ended (its `seconds`, a throttled display's slow frames) was cut off.
      ...(typing?.stopped
        ? { type_stopped: typing.stopped }
        : typing && typing.text.length > 0
          ? { type_stopped: run.personTypedAt !== undefined ? "person" : "time_up" }
          : {}),
      // The hover and card as the run ended; the host's own release comes after (`state()`).
      card_open: cardOpen(run.target),
      scrolled_into_view: run.scrolledIntoView,
      person_active: run.personActive !== null,
      ...(run.personActive ? { person_active_by: run.personActive } : {}),
      layouts: null,
      layouts_unavailable:
        "a page has no count of the engine's layouts per frame (only tracing and the Web Inspector do)",
      paints: null,
      paints_unavailable:
        "a page has no count of the engine's paints per frame (only tracing and the Web Inspector do)",
      idle_cost: IDLE_COST,
    };
  }
}

export const chatDrive = new ChatDrive();
