// The glyph in the composer's one send slot, and its morph when the slot turns from Send into Stop
// (a turn starts) or from Stop into Send (it ends, or the first letter is typed mid-turn). Leo,
// 2026-11-07: "At the very least, like the Enter to the Stop button, I like. I think it would be
// cool. You know, a fast animation that's just like, oh well, how delightful".
//
// Send and Stop are two buttons (Composer.tsx `key="send"` / `key="stop"`), so a change remounts
// the slot. The composer keeps one `SlotMemory` of the glyph drawn last; the glyph that mounts reads
// it and, on a real change, draws the old glyph as an inert copy that leaves while the new one comes
// in, both in the button's one grid cell: the 28 px box never moves or resizes. Which morph runs,
// for every pair of glyphs and states, is the table in sendSlotTransitions.ts (Leo, 2026-11-22:
// "idle to send to stop to whatever we need those to be like... known."; design/composer-send-slot.md).
// A glyph change inside one button (Stop to its stopping ring) remounts the glyph, so it morphs as a
// change of button does. Nothing animates on the composer's first draw, within SETTLE_MS of a chat
// switch or a chat read, under Reduce Motion or motion off, or on a hidden page. Every morph ends
// by its deadline and removes its copy.
import type React from "react";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { Icon } from "../icons/Icon";
import { Spinner } from "../conversation/icons";
import { ArrowUpIcon, ReturnIcon, StopIcon } from "../ComposerPickers";
import { RETURN_GLYPH_PATH } from "../composerPickerModel";
import { reducedMotion } from "../threadMinimap/scrollMotion";
import { sendStopMorph, type SendStopMorphArm } from "./sendStopMorph.experiment";
import { stopPresence } from "./stopPresence.experiment";
import {
  MORPH_MS,
  morphFrom,
  noteScope,
  now,
  type Morph,
  type SlotGlyph,
  type SlotMemory,
  LEAVE_MS,
  PULSE_MS,
  SETTLE_MS,
} from "./sendSlotGlyphModel";
import { SLOT_TRANSITIONS, type SlotMorphSet, type SlotState } from "./sendSlotTransitions";

function motionAllowed(): boolean {
  if (typeof document !== "undefined" && document.visibilityState === "hidden") return false;
  return !reducedMotion();
}

export function GlyphIcon({ glyph }: { glyph: SlotGlyph }) {
  // Resume's ▶ is the mic's kind of glyph, a line icon, never a solid one (cmux#51039).
  if (glyph === "play") return <Icon name="media.play" size={16} />;
  if (glyph === "stopping") return <Spinner loading size={14} />;
  if (glyph === "pending") return <Spinner loading look="track" size={14} />;
  if (glyph === "stop") return <StopIcon />;
  if (glyph === "return") return <ReturnIcon />;
  return <ArrowUpIcon />;
}

/// The slot's glyph. With `memory` it morphs from the glyph drawn before it, as `set` (the shipped
/// SLOT_TRANSITIONS unless a gallery passes another) says for the two glyphs and, when the button
/// names it, the two states; without (the Quick Composer, which can show Stop and Send at once) it
/// draws at once.
export function SendSlotGlyph(props: {
  glyph: SlotGlyph;
  memory?: SlotMemory | undefined;
  scope?: string | undefined;
  state?: SlotState | undefined;
  set?: SlotMorphSet | undefined;
}) {
  // Keyed by its glyph: a change inside one button mounts the new glyph, which reads the memory.
  return <SlotGlyphDrawn key={props.glyph} {...props} />;
}

function SlotGlyphDrawn({
  glyph,
  memory,
  scope,
  state,
  set = SLOT_TRANSITIONS,
}: {
  glyph: SlotGlyph;
  memory?: SlotMemory | undefined;
  scope?: string | undefined;
  state?: SlotState | undefined;
  set?: SlotMorphSet | undefined;
}) {
  const [morph, setMorph] = useState<Morph | undefined>(() => {
    if (!memory) return undefined;
    const found = morphFrom(memory, scope, glyph, now(), state, set);
    if (!found || !motionAllowed()) return undefined;
    const kind = found.transition.morph;
    const arm: SendStopMorphArm =
      kind === "path" ? "path" : kind === "crossfade" ? experimentArm(sendStopMorph) : "scale";
    return { ...found, arm };
  });
  useLayoutEffect(() => {
    if (!memory) return;
    noteScope(memory, scope);
    memory.glyph = glyph;
    if (state) memory.state = state;
    else delete memory.state;
    delete memory.left;
    delete memory.leftAt;
  }, [memory, scope, glyph, state]);
  useLayoutEffect(
    () => () => {
      if (!memory || memory.glyph !== glyph) return;
      delete memory.glyph;
      memory.left = glyph;
      delete memory.state;
      memory.leftAt = now();
    },
    [memory, glyph],
  );
  // The stop condition: the morph's copy goes at its deadline even when no animation ran (a page
  // hidden mid-morph). The in-layer's animationend usually ends it first.
  useEffect(() => {
    if (!morph) return;
    const timer = setTimeout(() => setMorph(undefined), MORPH_MS * 3);
    return () => clearTimeout(timer);
  }, [morph]);
  if (!morph) return <GlyphIcon glyph={glyph} />;
  return (
    <MorphFrame
      arm={morph.arm}
      from={morph.from}
      to={glyph}
      unpop={morph.transition.morph === "unpop"}
      onEnd={() => setMorph(undefined)}
    />
  );
}

/// One morph from `from` (absent: the slot was empty) to `to`, playing, or held at `progress`
/// (0 to 1) for the gallery's stills.
export function MorphFrame({
  arm,
  from,
  to,
  progress,
  unpop,
  onEnd,
}: {
  arm: SendStopMorphArm;
  from?: SlotGlyph | undefined;
  to: SlotGlyph;
  progress?: number;
  /// The un-pop (a queued prompt pulled back): the scale layers, marked for the composer-unpop
  /// lane's own keyframes (`[data-send-unpop]`) to take over.
  unpop?: boolean;
  onEnd?: () => void;
}) {
  // A path morph needs two drawn strokes; the spinner has none, so it crossfades instead.
  if (arm === "path" && from && PATHS[from] && PATHS[to])
    return (
      <PathMorph from={from} to={to} {...(progress !== undefined ? { progress } : {})} {...(onEnd ? { onEnd } : {})} />
    );
  const layerArm = arm === "path" ? "scale" : arm;
  // A still at `progress` is drawn from the keyframes' own values (composerStates.css), so it shows
  // the same frame with motion on or off.
  const held = (layer: "in" | "out") =>
    progress === undefined ? undefined : heldStyle(layerArm, layer, easeOut(Math.min(1, Math.max(0, progress))));
  return (
    <>
      {from && (
        <span
          className="acpmux-send-layer"
          data-send-layer="out"
          data-send-morph={layerArm}
          data-send-unpop={unpop ? "" : undefined}
          style={held("out")}
          aria-hidden="true"
        >
          <GlyphIcon glyph={from} />
        </span>
      )}
      <span
        className="acpmux-send-layer"
        data-send-layer="in"
        data-send-morph={layerArm}
        data-send-unpop={unpop ? "" : undefined}
        {...(progress !== undefined ? { "data-send-held": "" } : {})}
        style={held("in")}
        onAnimationEnd={(event) => {
          if (event.target === event.currentTarget) onEnd?.();
        }}
      >
        <GlyphIcon glyph={to} />
      </span>
    </>
  );
}

/// One layer's look `eased` (0 to 1) of the way through its keyframes (composerStates.css).
function heldStyle(arm: "scale" | "rotate" | "blur", layer: "in" | "out", eased: number): React.CSSProperties {
  // How far the layer is from its resting state: 1 at the in-layer's start and the out-layer's end.
  const away = layer === "in" ? 1 - eased : eased;
  const style: React.CSSProperties = { animation: "none", opacity: 1 - away };
  if (arm === "scale") style.transform = `scale(${1 - 0.3 * away})`;
  if (arm === "rotate") style.transform = `rotate(${(layer === "in" ? -90 : 90) * away}deg) scale(${1 - 0.3 * away})`;
  if (arm === "blur") style.filter = `blur(${3 * away}px)`;
  return style;
}

// Each drawn glyph as two open strokes, so one stroke can bend into the other: Stop's square as
// its left and right halves, ↵ as its bar and arrowhead, ↑ as its stem and head.
const PATHS: Partial<Record<SlotGlyph, readonly [string, string]>> = {
  stop: [
    "M8 3.5H5A1.5 1.5 0 0 0 3.5 5v6A1.5 1.5 0 0 0 5 12.5h3",
    "M8 3.5h3A1.5 1.5 0 0 1 12.5 5v6a1.5 1.5 0 0 1-1.5 1.5H8",
  ],
  return: RETURN_GLYPH_PATH.split(/(?=M)/).reverse() as unknown as readonly [string, string],
  arrow: ["M3.9 7.5 8 3.4l4.1 4.1", "M8 12.9V3.4"],
};
const SAMPLES = 24;
const sampled = new Map<string, Array<[number, number]>>();

function samples(d: string): Array<[number, number]> {
  const known = sampled.get(d);
  if (known) return known;
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("style", "position:absolute;width:0;height:0;visibility:hidden");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", d);
  svg.append(path);
  document.body.append(svg);
  const length = path.getTotalLength();
  const points: Array<[number, number]> = [];
  for (let index = 0; index < SAMPLES; index += 1) {
    const point = path.getPointAtLength((length * index) / (SAMPLES - 1));
    points.push([point.x, point.y]);
  }
  svg.remove();
  sampled.set(d, points);
  return points;
}

/// Core Animation's easeOut (--cmux-ease-out, cubic-bezier(0, 0, 0.58, 1)), solved for x.
function easeOut(x: number): number {
  let low = 0;
  let high = 1;
  for (let step = 0; step < 20; step += 1) {
    const t = (low + high) / 2;
    const at = 3 * (1 - t) * t * t * 0.58 + t * t * t;
    if (at < x) low = t;
    else high = t;
  }
  const t = (low + high) / 2;
  return 3 * (1 - t) * t * t + t * t * t;
}

function morphPath(from: SlotGlyph, to: SlotGlyph, progress: number): string {
  const p = easeOut(Math.min(1, Math.max(0, progress)));
  const a = PATHS[from]!;
  const b = PATHS[to]!;
  return [0, 1]
    .map((stroke) => {
      const start = samples(a[stroke]!);
      const end = samples(b[stroke]!);
      return start
        .map(([x, y], index) => {
          const [ex, ey] = end[index]!;
          return `${index === 0 ? "M" : "L"}${(x + (ex - x) * p).toFixed(2)} ${(y + (ey - y) * p).toFixed(2)}`;
        })
        .join("");
    })
    .join("");
}

function PathMorph({
  from,
  to,
  progress,
  onEnd,
}: {
  from: SlotGlyph;
  to: SlotGlyph;
  progress?: number;
  onEnd?: () => void;
}) {
  const stroke = useRef<SVGPathElement>(null);
  const end = useRef(onEnd);
  end.current = onEnd;
  useLayoutEffect(() => {
    const node = stroke.current;
    if (!node) return;
    if (progress !== undefined) {
      node.setAttribute("d", morphPath(from, to, progress));
      return;
    }
    // One frame loop, ended by its deadline (or the unmount).
    const start = now();
    let frame = 0;
    const tick = () => {
      const elapsed = now() - start;
      node.setAttribute("d", morphPath(from, to, elapsed / MORPH_MS));
      if (elapsed >= MORPH_MS) end.current?.();
      else frame = requestAnimationFrame(tick);
    };
    tick();
    return () => cancelAnimationFrame(frame);
  }, [from, to, progress]);
  return (
    // icon-scale-allow: the composer's own 18 glyph set (design/grid.md), as ComposerPickers' Icon.
    <svg
      className="acpmux-icon"
      width={18}
      height={18}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      data-send-morph="path"
    >
      <path ref={stroke} />
    </svg>
  );
}

/// The pulse Stop draws when a turn starts again while it lingers after the last one's end
/// (turnPresence.ts; Leo, 2026-11-22: "maybe a pulse when you for some reason start stop quick"):
/// in place of Stop going and coming back. One run per pulse (`pulses` counts them), none on the
/// first draw, under Reduce Motion or motion off, or on a hidden page; it removes itself at its end
/// or its deadline. The arm (experiment stop-presence) picks its look.
export function StopPulse({ pulses }: { pulses: number }) {
  const [seen, setSeen] = useState(pulses);
  const [playing, setPlaying] = useState<number | undefined>(undefined);
  if (pulses !== seen) {
    setSeen(pulses);
    setPlaying(pulses > seen && motionAllowed() ? pulses : undefined);
  }
  useEffect(() => {
    if (playing === undefined) return undefined;
    const timer = setTimeout(() => setPlaying(undefined), PULSE_MS * 2);
    return () => clearTimeout(timer);
  }, [playing]);
  const arm = experimentArm(stopPresence);
  if (playing === undefined || arm === "fade") return null;
  return (
    <span
      key={playing}
      className="acpmux-stop-pulse"
      data-stop-pulse={arm}
      aria-hidden="true"
      onAnimationEnd={(event) => {
        if (event.target === event.currentTarget) setPlaying(undefined);
      }}
    />
  );
}

/// The send slot's box: one reserved cell the composer's Send, Stop or nothing stand in, so a turn's
/// Stop coming and going never moves or refits the row around it (composerRowFit.ts counts the
/// cell, not what is in it). What leaves the slot with nothing in its place (Stop at a turn's end in
/// Claude's look) stays as an inert copy that fades out on the motion scale's leaving step; a Stop
/// that arrives in an empty slot fades in (sendSlotGlyphModel.ts morphFrom). Neither plays on a
/// chat switch, within SETTLE_MS of one, under Reduce Motion or motion off, or on a hidden page.
export function SendSlot({
  children,
  memory,
  scope,
}: {
  children: React.ReactNode;
  memory?: SlotMemory | undefined;
  scope?: string | undefined;
}) {
  const empty = children === null || children === undefined || children === false;
  const [leaving, setLeaving] = useState<SlotGlyph | undefined>(undefined);
  const [wasEmpty, setWasEmpty] = useState(empty);
  if (wasEmpty !== empty) {
    setWasEmpty(empty);
    // The glyph drawn last committed is the one leaving now; another chat's never is.
    const left = memory?.glyph;
    setLeaving(
      empty && left && memory?.scope === scope && now() - (memory?.since ?? 0) >= SETTLE_MS && motionAllowed()
        ? left
        : undefined,
    );
  }
  useEffect(() => {
    if (leaving === undefined) return undefined;
    const timer = setTimeout(() => setLeaving(undefined), LEAVE_MS * 3);
    return () => clearTimeout(timer);
  }, [leaving]);
  return (
    <span className="acpmux-send-slot" data-send-slot={empty ? "empty" : "filled"}>
      {children}
      {empty && leaving && (
        <span
          className="acpmux-send-leaving"
          data-send-leaving={leaving === "stop" || leaving === "stopping" ? "stop" : "send"}
          aria-hidden="true"
          onAnimationEnd={(event) => {
            if (event.target === event.currentTarget) setLeaving(undefined);
          }}
        >
          <GlyphIcon glyph={leaving} />
        </span>
      )}
    </span>
  );
}
