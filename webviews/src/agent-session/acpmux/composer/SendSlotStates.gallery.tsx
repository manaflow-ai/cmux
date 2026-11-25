// l10n-allow-file: gallery labels, not shipped UI.
// The composer's send slot as one known state machine (composer/sendSlotTransitions.ts; Leo,
// 2026-11-22: "transitions from send to stop to start to whatever need better morphing, maybe. it's
// ok now but maybe it could be better? we can hill climb that too. idle to send to stop to whatever
// we need those to be like... known."). Each variant is one whole morph set (sendSlotVariants.ts)
// for the coordinator to choose between; only `scale` ships. A variant shows:
// - a filmstrip of the journey's steps in Claude's look and Codex's, each held at rest, half way
//   through its morph, and at its end;
// - two live slots its play drives through idle -> send-ready -> sending -> stop -> stopping ->
//   idle, sampling every frame: the button's box never moves or resizes, and each glyph change
//   runs exactly as many morphs as the table says (one, or none for an instant row), never two
//   (test/send-slot-states.browser.test.ts reads the report the play writes).
import { useEffect, useRef, useState, type ReactNode } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { MOTION_MS } from "../../../motion/scale.generated";
import { reducedMotion } from "../threadMinimap/scrollMotion";
import { GAP_MS, newSlotMemory, SETTLE_MS, type SlotMemory } from "./sendSlotGlyphModel";
import {
  animates,
  SLOT_LOOKS,
  slotTransition,
  type SlotDrawn,
  type SlotLook,
  type SlotMorphSet,
  type SlotState,
} from "./sendSlotTransitions";
import { SLOT_VARIANT_IDS, SLOT_VARIANTS, type SlotVariantId } from "./sendSlotVariants";

type Props = { variant: SlotVariantId };

/// The live journey: each state and how long it holds. `sending` holds less than GAP_MS, as a
/// host's round trip does, so Claude's look grows the turn's Stop in as the send's.
export const SLOT_JOURNEY: ReadonlyArray<readonly [SlotState, number]> = [
  ["idle", 0],
  ["send-ready", 420],
  ["sending", Math.round(GAP_MS / 4)],
  ["stop", 420],
  ["stopping", 420],
  ["idle", 420],
];

/// The filmstrip's steps: the journey, then the turns off it.
const STEPS: ReadonlyArray<readonly [SlotState, SlotState]> = [
  ["idle", "send-ready"],
  ["send-ready", "sending"],
  ["sending", "stop"],
  ["stop", "stopping"],
  ["stopping", "idle"],
  ["stop", "send-ready"],
  ["send-ready", "queued"],
  ["queued", "stop"],
  ["stop", "unsend"],
];
const POINTS = [0, 0.5, 1] as const;
const STATE_EVENT = "cmux-send-slot-state";

function buttonClass(state: SlotState): string {
  if (state === "stop" || state === "stopping") return "acpmux-send acpmux-cancel";
  if (state === "queued") return "acpmux-send acpmux-send-ready acpmux-resume";
  if (state === "send-ready" || state === "unsend") return "acpmux-send acpmux-send-ready";
  return "acpmux-send";
}
/// Which button the state is in the composer (Composer.tsx keys): a change of key remounts it.
const buttonKey = (state: SlotState) =>
  state === "stop" || state === "stopping" ? "stop" : state === "queued" ? "resume" : "send";

/// One 28 px cell; an empty slot keeps the cell, so the filmstrip and the live row never step.
function Cell({ children }: { children?: ReactNode }) {
  return (
    <span
      className="acpmux-composer-bar"
      data-slot-cell=""
      style={{ display: "grid", placeItems: "center", width: 28, height: 28 }}
    >
      {children}
    </span>
  );
}

/// The components, built once SendSlotGlyph loads (the entry's `load`).
function galleryOf({ MorphFrame, SendSlotGlyph }: typeof import("./SendSlotGlyph")) {
  /// One step held at `point`: 0 draws the old state, 1 the new; half way an animated row draws its
  /// morph at its midpoint, and an instant one is already at its end.
  function Still({
    set,
    look,
    from,
    to,
    point,
  }: {
    set: SlotMorphSet;
    look: SlotLook;
    from: SlotState;
    to: SlotState;
    point: number;
  }) {
    const a = set.glyphs[from][look];
    const b = set.glyphs[to][look];
    const transition = slotTransition(set, from, to, look);
    const animated = transition && animates(transition) && b !== "none" ? transition : undefined;
    const state = point === 0 ? from : to;
    const shown: SlotDrawn = point === 0 ? a : b;
    let glyph: ReactNode = null;
    if (animated && point === 0.5 && b !== "none")
      glyph = (
        <MorphFrame
          arm={animated.morph === "path" ? "path" : "scale"}
          from={animated.morph === "enter" || a === "none" ? undefined : a}
          to={b}
          progress={point}
          unpop={animated.morph === "unpop"}
        />
      );
    else if (shown !== "none") glyph = <SendSlotGlyph glyph={shown} />;
    return (
      <div className="acpmux-composer" data-composer-look={look === "codex" ? "codex" : undefined}>
        <Cell>
          {glyph && (
            <button type="button" tabIndex={-1} className={buttonClass(state)} aria-label={`${from} to ${to} ${point}`}>
              {glyph}
            </button>
          )}
        </Cell>
      </div>
    );
  }

  function Live({
    set,
    look,
    state,
    memory,
  }: {
    set: SlotMorphSet;
    look: SlotLook;
    state: SlotState;
    memory: SlotMemory;
  }) {
    const glyph = set.glyphs[state][look];
    return (
      <div
        className="acpmux-composer"
        data-composer-look={look === "codex" ? "codex" : undefined}
        data-slot-live={look}
        // The slot first: the label's width changes with its state, and must not move the button.
        style={{
          display: "grid",
          gridTemplateColumns: "28px auto",
          gap: "var(--ds-space-3)",
          alignItems: "center",
          width: 200,
        }}
      >
        <Cell>
          {glyph !== "none" && (
            <button
              key={buttonKey(state)}
              type="button"
              tabIndex={-1}
              className={buttonClass(state)}
              aria-label={state}
            >
              <SendSlotGlyph glyph={glyph} state={state} memory={memory} scope="gallery" set={set} />
            </button>
          )}
        </Cell>
        <span style={{ color: "var(--agent-muted)", fontSize: "var(--text-detail)" }}>
          {look === "codex" ? "Codex" : "Claude"} live: {state}
        </span>
      </div>
    );
  }

  function Gallery({ variant }: Props) {
    const { set } = SLOT_VARIANTS[variant];
    const [state, setState] = useState<SlotState>("idle");
    const [memories] = useState(() => ({ claude: newSlotMemory("gallery"), codex: newSlotMemory("gallery") }));
    const shell = useRef<HTMLDivElement>(null);
    useEffect(() => {
      const doc = shell.current?.ownerDocument;
      if (!doc) return;
      const onState = (event: Event) => setState((event as CustomEvent<SlotState>).detail);
      doc.addEventListener(STATE_EVENT, onState);
      return () => doc.removeEventListener(STATE_EVENT, onState);
    }, []);
    const label = (text: string) => (
      <div style={{ color: "var(--agent-muted)", fontSize: "var(--text-detail)", alignSelf: "center" }}>{text}</div>
    );
    return (
      <div
        ref={shell}
        className="acpmux-shell"
        style={{ display: "block", height: "auto", padding: "var(--ds-space-5)" }}
      >
        <div style={{ display: "flex", gap: "var(--ds-space-6)", marginBottom: "var(--ds-space-5)" }}>
          {SLOT_LOOKS.map((look) => (
            <Live key={look} set={set} look={look} state={state} memory={memories[look]} />
          ))}
        </div>
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "auto repeat(3, 36px) var(--ds-space-5) repeat(3, 36px)",
            gap: "var(--ds-space-2) var(--ds-space-3)",
            alignItems: "center",
            justifyItems: "center",
          }}
        >
          <div />
          {["Claude", "", "", "", "Codex", "", ""].map((text, index) => (
            <div key={index} style={{ color: "var(--agent-muted)", fontSize: "var(--text-caption)" }}>
              {text}
            </div>
          ))}
          {STEPS.map(([from, to]) => {
            const claude = slotTransition(set, from, to, "claude");
            const codex = slotTransition(set, from, to, "codex");
            const name = (transition: typeof claude) =>
              !transition
                ? "?"
                : animates(transition)
                  ? `${transition.morph} ${MOTION_MS[transition.step]}`
                  : transition.morph;
            return (
              <div key={`${from}-${to}`} style={{ display: "contents" }}>
                {label(`${from} → ${to} · ${name(claude)} / ${name(codex)}`)}
                {POINTS.map((point) => (
                  <Still key={`claude-${point}`} set={set} look="claude" from={from} to={to} point={point} />
                ))}
                <div />
                {POINTS.map((point) => (
                  <Still key={`codex-${point}`} set={set} look="codex" from={from} to={to} point={point} />
                ))}
              </div>
            );
          })}
        </div>
      </div>
    );
  }
  return Gallery;
}

type Swap = { look: SlotLook; from: SlotState; to: SlotState; expected: number; morphs: number };
type Report = { boxes: string[]; swaps: Swap[]; maxLayers: number; problems: string[] };

/// Plays the journey in both live slots, every frame read, and writes the report to
/// `data-send-slot-report`; it throws when a box moved or a swap ran a morph the table does not name.
const journey =
  (variant: SlotVariantId): Play =>
  async (ctx) => {
    const doc = ctx.document;
    const win = doc.defaultView!;
    const { set } = SLOT_VARIANTS[variant];
    await ctx.waitFor(() => doc.querySelectorAll("[data-slot-live]").length === 2);
    // Past the slots' settle window: from here a change is a change.
    await new Promise((resolve) => setTimeout(resolve, SETTLE_MS + 80));
    const still = reducedMotion();
    const report: Report = { boxes: [], swaps: [], maxLayers: 0, problems: [] };
    const boxes: Record<SlotLook, Set<string>> = { claude: new Set(), codex: new Set() };
    let mounts: Record<SlotLook, number> = { claude: 0, codex: 0 };
    const observer = new win.MutationObserver((records) => {
      for (const record of records)
        for (const node of record.addedNodes) {
          if (!(node instanceof win.Element)) continue;
          const live = node.closest("[data-slot-live]")?.getAttribute("data-slot-live") as SlotLook | null;
          if (!live) continue;
          // One morph: one in-layer, or one path stroke (inside a new button or on its own).
          const count = node.matches('[data-send-layer="in"], svg[data-send-morph="path"]')
            ? 1
            : node.querySelectorAll('[data-send-layer="in"], svg[data-send-morph="path"]').length;
          mounts[live] += count;
        }
    });
    observer.observe(doc.body, { childList: true, subtree: true });
    let sampling = true;
    const read = () => {
      for (const look of SLOT_LOOKS) {
        const button = doc.querySelector<HTMLElement>(`[data-slot-live="${look}"] .acpmux-send`);
        if (!button) continue;
        const box = button.getBoundingClientRect();
        boxes[look].add(`${box.x},${box.y},${box.width}x${box.height}`);
        report.maxLayers = Math.max(
          report.maxLayers,
          button.querySelectorAll('.acpmux-send-layer, svg[data-send-morph="path"]').length,
        );
      }
      // raf-read: the play samples the slot's own morph, frame by frame; that is its subject.
      if (sampling) win.requestAnimationFrame(read);
    };
    // raf-read: the first sample of the journey.
    win.requestAnimationFrame(read);
    for (let index = 1; index < SLOT_JOURNEY.length; index += 1) {
      const [from] = SLOT_JOURNEY[index - 1]!;
      const [to, hold] = SLOT_JOURNEY[index]!;
      mounts = { claude: 0, codex: 0 };
      doc.dispatchEvent(new win.CustomEvent(STATE_EVENT, { detail: to }));
      // fixed-wait: each state holds for its share of the journey; the time is the subject.
      await new Promise((resolve) => setTimeout(resolve, hold));
      for (const look of SLOT_LOOKS) {
        const transition = slotTransition(set, from, to, look);
        const expected = !still && transition && animates(transition) ? 1 : 0;
        report.swaps.push({ look, from, to, expected, morphs: mounts[look] });
        if (mounts[look] !== expected)
          report.problems.push(`${look} ${from} -> ${to}: ${mounts[look]} morphs, the table names ${expected}`);
      }
    }
    sampling = false;
    observer.disconnect();
    for (const look of SLOT_LOOKS) {
      report.boxes.push(`${look}: ${[...boxes[look]].join(" | ")}`);
      if (boxes[look].size !== 1)
        report.problems.push(`${look}: the button's box moved or resized (${boxes[look].size} boxes)`);
      for (const box of boxes[look])
        if (!box.endsWith("28x28")) report.problems.push(`${look}: the button is ${box}, not 28x28`);
    }
    if (report.maxLayers > 2) report.problems.push(`${report.maxLayers} layers at once: two morphs overlapped`);
    doc.documentElement.dataset.sendSlotReport = JSON.stringify(report);
    if (report.problems.length) throw new Error(report.problems.join("\n"));
  };

export default componentEntry<Props>({
  id: "agent-pane.composer-send-slot-states",
  title: "Composer send slot states",
  area: "Composer",
  pane: true,
  height: 560,
  widths: { normal: 640, narrow: 460 },
  keywords: ["send", "stop", "stopping", "resume", "unsend", "morph", "state machine", "transition"],
  covers: ["agent-session/acpmux/composer/SendSlotGlyph.tsx#SendSlotGlyph"],
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("../composerStates.css"),
      import("../composerLocation.css"),
      import("../composerLook.css"),
      import("../conversation/spinner.css"),
    ]).then(() => undefined),
  load: () => import("./SendSlotGlyph").then(galleryOf),
  variants: Object.fromEntries(
    SLOT_VARIANT_IDS.map((variant) => [
      variant,
      { note: SLOT_VARIANTS[variant].note, props: { variant }, play: journey(variant) },
    ]),
  ),
});
