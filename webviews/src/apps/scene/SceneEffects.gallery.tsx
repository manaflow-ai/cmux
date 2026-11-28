// l10n-allow-file: gallery fixture text, not shipped UI.
// The app scene motion contract (cmux-app-host js/ABI.md "Motion") as the web renderer draws it:
// every loop, the springs, the transitions, glow, gradient and trim, and every particle preset. The
// fixture plays the app: a timer here changes props the way an app's signal would, and the
// renderer animates each change on its own.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp, type SceneProps } from "./store";

type Look = "loops" | "springs" | "transitions" | "shapes" | "particles";

const LOOPS = ["pulse", "breathe", "spin", "float", "wiggle", "bounce", "shimmer"] as const;
const PRESETS = ["confetti", "sparkles", "rain", "snow", "embers", "stars"] as const;
const SPRINGS = ["move", "appear", "bouncy", "fade"] as const;
// A custom spring (a quick one with a little give): `snappy` is the motion scale's CSS micro step, which moves no transform.
const QUICK = { spring: { response: 0.3, dampingFraction: 0.8 } };
const TRANSITIONS = ["opacity", "slide", "scale", "move", "pop"] as const;
const GOLD = "#FFC94D";
const VIOLET = "#9B7BFF";
const CYAN = "#3FD0E0";

let ids = 0;
const id = (prefix: string) => `${prefix}-${++ids}`;

/** A labeled cell: `content` over a caption, in a fixed box so every cell lines up. */
function cell(ops: SceneOp[], label: string, content: string): string {
  const box = id("cell");
  const caption = id("caption");
  ops.push(
    {
      op: "create",
      id: box,
      type: "VStack",
      props: { spacing: 8, alignment: "center", frame: { width: 96, height: 92 } },
    },
    { op: "create", id: caption, type: "Text", props: { text: label, font: "caption", color: "secondary" } },
    { op: "children", id: box, children: [content, caption] },
  );
  return box;
}

function create(ops: SceneOp[], type: string, props: SceneProps, prefix = type.toLowerCase()): string {
  const node = id(prefix);
  ops.push({ op: "create", id: node, type, props });
  return node;
}

function grid(ops: SceneOp[], cells: string[], perRow = 4): string {
  const rows: string[] = [];
  for (let index = 0; index < cells.length; index += perRow) {
    const row = id("row");
    ops.push(
      { op: "create", id: row, type: "HStack", props: { spacing: 8 } },
      { op: "children", id: row, children: cells.slice(index, index + perRow) },
    );
    rows.push(row);
  }
  const column = id("grid");
  ops.push(
    { op: "create", id: column, type: "VStack", props: { spacing: 12, padding: 12 } },
    { op: "children", id: column, children: rows },
    { op: "root", id: column },
  );
  return column;
}

type Fixture = { ops: SceneOp[]; tick?: (store: SceneStore, step: number) => void; every?: number };

function loops(): Fixture {
  const ops: SceneOp[] = [];
  const cells = LOOPS.map((effect) => {
    const shape =
      effect === "shimmer"
        ? create(ops, "RoundedRectangle", { size: 44, fill: VIOLET, cornerRadius: 12, loop: { effect } })
        : effect === "breathe"
          ? create(ops, "Circle", { size: 36, fill: CYAN, loop: { effect } })
          : create(ops, "Icon", {
              symbol: effect === "spin" ? "arrow.triangle.2.circlepath" : "star.fill",
              size: 28,
              color: GOLD,
              loop: { effect },
            });
    return cell(ops, effect, shape);
  });
  grid(ops, cells);
  return { ops };
}

function springs(): Fixture {
  const ops: SceneOp[] = [];
  const nodes: string[] = [];
  const cells = SPRINGS.map((motion) => {
    const dot = create(ops, "Circle", { size: 28, fill: GOLD, animation: motion, offset: { x: -24, y: 0 }, scale: 1 });
    nodes.push(dot);
    return cell(ops, motion, dot);
  });
  const glow = create(ops, "Circle", {
    size: 28,
    fill: VIOLET,
    animation: QUICK,
    glow: { color: VIOLET, radius: 2, opacity: 0.4 },
  });
  nodes.push(glow);
  cells.push(cell(ops, "glow", glow));
  const blur = create(ops, "Text", { text: "cmux", font: "title2", weight: "semibold", animation: "move", blur: 0 });
  cells.push(cell(ops, "blur", blur));
  const progress = create(ops, "ProgressView", { value: 0.1, animation: QUICK, frame: { width: 80 } });
  cells.push(cell(ops, "value", progress));
  grid(ops, cells);
  return {
    ops,
    every: 1100,
    tick: (store, step) => {
      const on = step % 2 === 1;
      store.apply([
        ...nodes.slice(0, SPRINGS.length).map((node): SceneOp => ({
          op: "update",
          id: node,
          props: { offset: { x: on ? 24 : -24, y: 0 }, scale: on ? 1.25 : 1 },
        })),
        {
          op: "update",
          id: glow,
          props: { glow: { color: VIOLET, radius: on ? 14 : 2, opacity: on ? 1 : 0.4 }, scale: on ? 1.15 : 1 },
        },
        { op: "update", id: blur, props: { blur: on ? 6 : 0, opacity: on ? 0.4 : 1 } },
        { op: "update", id: progress, props: { value: on ? 0.9 : 0.1 } },
      ]);
    },
  };
}

function transitions(): Fixture {
  const ops: SceneOp[] = [];
  const slots = TRANSITIONS.map((transition) => {
    const slot = create(ops, "ZStack", { frame: { width: 56, height: 44 }, clipped: true }, "slot");
    return { transition, slot };
  });
  grid(
    ops,
    slots.map(({ transition, slot }) => cell(ops, transition, slot)),
  );
  return {
    ops,
    every: 900,
    tick: (store, step) => {
      const next: SceneOp[] = [];
      for (const { transition, slot } of slots) {
        const current = store.getNode(slot)?.children ?? [];
        for (const child of current) next.push({ op: "remove", id: child });
        if (step % 2 === 1) {
          const chip = id("chip");
          next.push(
            { op: "create", id: chip, type: "Badge", props: { text: transition, tone: "warning", transition } },
            { op: "children", id: slot, children: [chip] },
          );
        } else next.push({ op: "children", id: slot, children: [] });
      }
      store.apply(next);
    },
  };
}

function shapes(): Fixture {
  const ops: SceneOp[] = [];
  const ring = create(ops, "Circle", {
    size: 48,
    stroke: CYAN,
    strokeWidth: 5,
    trim: { to: 0.2 },
    animation: "bouncy",
  });
  const track = create(ops, "Circle", { size: 48, stroke: "separator", strokeWidth: 5 });
  const gauge = create(ops, "ZStack", {}, "gauge");
  ops.push({ op: "children", id: gauge, children: [track, ring] });
  const capsule = create(ops, "Capsule", {
    size: 44,
    stroke: GOLD,
    strokeWidth: 3,
    trim: { from: 0, to: 0.6 },
    animation: QUICK,
  });
  const gradient = create(ops, "RoundedRectangle", {
    size: 44,
    cornerRadius: 12,
    gradient: { colors: [VIOLET, CYAN], angle: 45 },
    loop: { effect: "pulse" },
  });
  const panel = create(ops, "VStack", {
    padding: 8,
    cornerRadius: 8,
    gradient: { colors: ["#2A1E5C", "#0E3A4A"] },
    glow: { color: VIOLET, radius: 10, opacity: 0.8 },
  });
  const panelText = create(ops, "Text", { text: "Glow", color: "#FFFFFF", weight: "semibold" });
  ops.push({ op: "children", id: panel, children: [panelText] });
  const glowText = create(ops, "Icon", {
    symbol: "star.fill",
    size: 28,
    color: GOLD,
    glow: { color: GOLD, radius: 10 },
    loop: { effect: "breathe" },
  });
  grid(ops, [
    cell(ops, "trim ring", gauge),
    cell(ops, "trim capsule", capsule),
    cell(ops, "gradient", gradient),
    cell(ops, "panel glow", panel),
    cell(ops, "icon glow", glowText),
  ]);
  return {
    ops,
    every: 1400,
    tick: (store, step) => {
      const fraction = [0.2, 0.85, 0.5, 1][step % 4]!;
      store.apply([
        { op: "update", id: ring, props: { trim: { to: fraction } } },
        { op: "update", id: capsule, props: { trim: { from: 0, to: 1 - fraction / 2 } } },
      ]);
    },
  };
}

function particles(): Fixture {
  const ops: SceneOp[] = [];
  const fields: string[] = [];
  const cells = PRESETS.map((preset) => {
    const field = create(ops, "Particles", { preset, burst: 0, frame: { width: 150, height: 96 } });
    fields.push(field);
    const label = create(ops, "Text", { text: preset, font: "caption", weight: "semibold", color: "#FFFFFF" });
    const stage = create(
      ops,
      "ZStack",
      { frame: { width: 150, height: 96 }, cornerRadius: 8, background: "#141824" },
      "stage",
    );
    ops.push({ op: "children", id: stage, children: [field, label] });
    return stage;
  });
  grid(ops, cells, 3);
  return {
    ops,
    every: 1500,
    tick: (store, step) => {
      // Confetti and sparkles fire on each increase of `burst`, the way `burst: () => pulls()` does.
      store.apply([
        { op: "update", id: fields[0]!, props: { burst: step } },
        { op: "update", id: fields[1]!, props: { burst: step } },
      ]);
    },
  };
}

const FIXTURES: Record<Look, () => Fixture> = { loops, springs, transitions, shapes, particles };

function SceneMotion({ look = "loops" }: { look?: Look }) {
  const [fixture] = useState(() => {
    const built = FIXTURES[look]();
    const store = new SceneStore();
    store.apply(built.ops);
    return { ...built, store };
  });
  useEffect(() => {
    const { tick, every, store } = fixture;
    if (!tick) return;
    const counter = { step: 0 };
    const next = () => {
      counter.step += 1;
      tick(store, counter.step);
    };
    next();
    // gallery-capture: the tick stands in for the app's signal; each variant's `ready` play waits for the scene root, and the scene's first step is applied before the interval.
    const timer = window.setInterval(next, every ?? 1000);
    return () => window.clearInterval(timer);
  }, [fixture]);
  return (
    <div style={{ padding: 8 }}>
      <SceneRenderer store={fixture.store} dispatch={() => {}} />
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cmux-app-scene-root") !== null);
};

export default componentEntry<{ look?: Look }>({
  id: "apps.scene-effects",
  title: "App scene effects",
  area: "Apps",
  pane: true,
  height: 360,
  widths: { narrow: 440, normal: 520 },
  covers: [
    "apps/scene/SceneRenderer.tsx",
    "apps/scene/SceneParticles.tsx",
    "apps/scene/motionProps.ts",
    "apps/scene/particleField.ts",
    "apps/scene/useSceneMotion.ts",
    "apps/scene/scene.css",
  ],
  load: async () => SceneMotion,
  variants: {
    loops: {
      note: "Every loop (pulse, breathe, spin, float, wiggle, bounce, shimmer) run by CSS with no script per frame; Reduce Motion stops them.",
      props: { look: "loops" },
      play: ready,
    },
    springs: {
      note: "The motion tokens (move, appear, bouncy, fade) and a custom spring retargeting offset and scale from the value on screen, plus glow, blur and a ProgressView value on springs.",
      props: { look: "springs" },
      play: ready,
    },
    transitions: {
      note: "Badges entering and leaving with opacity, slide, scale, move and pop; a removed node stays until its exit ends.",
      props: { look: "transitions" },
      play: ready,
    },
    shapes: {
      note: "Trim (a ring gauge from 12 o'clock and a capsule outline) on springs, a gradient fill, a glowing gradient panel and a glowing icon.",
      props: { look: "shapes" },
      play: ready,
    },
    particles: {
      note: "Every particle preset on one canvas each: confetti and sparkles fire on each burst, rain, snow, embers and stars run continuously.",
      props: { look: "particles" },
      play: ready,
    },
  },
});
