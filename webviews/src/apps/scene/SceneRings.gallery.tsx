// l10n-allow-file: gallery fixture text, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SceneMount } from "./panels";
import type { MountedPanel } from "./panelsClient";
import { SceneStore, type SceneOp } from "./store";

type Look = "activity" | "usage";

/** Apple's activity ring colors, each with its track (the same hue, dimmed). */
const MOVE = { tint: "#FA114F", track: "#FA114F33" };
const EXERCISE = { tint: "#92E82A", track: "#92E82A33" };
const STAND = { tint: "#1EEAEF", track: "#1EEAEF33" };

/** One ring as the SDK's `Ring(value, {tint, track, width, size})` draws it: a full track circle
 * and a round-capped arc from 12 o'clock, trimmed to `value`, that sweeps on `animation`. */
const ring = (
  id: string,
  value: number,
  colors: { tint: string; track: string },
  size: number,
  width = 10,
): SceneOp[] => [
  { op: "create", id, type: "ZStack", props: {} },
  { op: "create", id: `${id}-track`, type: "Circle", props: { size, stroke: colors.track, strokeWidth: width } },
  {
    op: "create",
    id: `${id}-arc`,
    type: "Circle",
    props: {
      size,
      stroke: colors.tint,
      strokeWidth: width,
      trim: { to: value, lineCap: "round" },
      animation: "smooth",
    },
  },
  { op: "children", id, children: [`${id}-track`, `${id}-arc`] },
];

/** A small activity tile: three nested rings (Move, Exercise, Stand) on a dark card. */
const activity = (move: number, exercise: number, stand: number): SceneOp[] => [
  {
    op: "create",
    id: "tile",
    type: "HStack",
    props: { spacing: 16, padding: 16, cornerRadius: 22, background: "#000000" },
  },
  { op: "create", id: "rings", type: "ZStack", props: {} },
  ...ring("move", move, MOVE, 96),
  ...ring("exercise", exercise, EXERCISE, 72),
  ...ring("stand", stand, STAND, 48),
  { op: "children", id: "rings", children: ["move", "exercise", "stand"] },
  { op: "create", id: "stats", type: "VStack", props: { spacing: 2, alignment: "leading" } },
  {
    op: "create",
    id: "move-t",
    type: "Text",
    props: { text: "Move 320/500 kcal", font: 13, weight: "semibold", color: MOVE.tint },
  },
  {
    op: "create",
    id: "ex-t",
    type: "Text",
    props: { text: "Exercise 24/30 min", font: 13, weight: "semibold", color: EXERCISE.tint },
  },
  {
    op: "create",
    id: "stand-t",
    type: "Text",
    props: { text: "Stand 9/12 h", font: 13, weight: "semibold", color: STAND.tint },
  },
  { op: "create", id: "bump", type: "Button", props: { title: "Close the rings" } },
  { op: "children", id: "stats", children: ["move-t", "ex-t", "stand-t", "bump"] },
  { op: "children", id: "tile", children: ["rings", "stats"] },
  { op: "root", id: "tile" },
];

/** Usage limits as rings with the value inside, in the theme's tones: 5-hour and weekly. */
const usage: SceneOp[] = [
  { op: "create", id: "tile", type: "HStack", props: { spacing: 20, padding: 16 } },
  ...[
    ["five", 0.38, "success", "38%", "5-hour"],
    ["week", 0.81, "warning", "81%", "Weekly"],
    ["empty", 0, "accent", "0%", "Idle"],
  ].flatMap(([id, value, tint, label, caption]): SceneOp[] => [
    { op: "create", id: `${id}`, type: "VStack", props: { spacing: 6, alignment: "center" } },
    { op: "create", id: `${id}-z`, type: "ZStack", props: {} },
    ...ring(`${id}-r`, value as number, { tint: tint as string, track: "separator" }, 56, 6),
    { op: "create", id: `${id}-v`, type: "Text", props: { text: label, font: 13, weight: "semibold" } },
    { op: "children", id: `${id}-z`, children: [`${id}-r`, `${id}-v`] },
    { op: "create", id: `${id}-c`, type: "Text", props: { text: caption, font: 12, color: "secondary" } },
    { op: "children", id: `${id}`, children: [`${id}-z`, `${id}-c`] },
  ]),
  { op: "children", id: "tile", children: ["five", "week", "empty"] },
  { op: "root", id: "tile" },
];

function mounted(look: Look): MountedPanel {
  const store = new SceneStore();
  const ops = look === "usage" ? usage : activity(0.64, 0.8, 0.75);
  store.apply(ops);
  return {
    panel: { app: "local/gallery", section: "gallery", title: "Gallery" },
    store,
    dispatch: (node, event) => {
      if (event !== "tap" || node !== "bump") return;
      store.apply([
        { op: "update", id: "move-arc", props: { trim: { to: 1, lineCap: "round" } } },
        { op: "update", id: "exercise-arc", props: { trim: { to: 1, lineCap: "round" } } },
        { op: "update", id: "stand-arc", props: { trim: { to: 1, lineCap: "round" } } },
      ]);
    },
    reload: () => store.apply(ops, true),
    layout: () => undefined,
    resolveAsset: () => undefined,
  };
}

function SceneRings({ look = "activity" }: { look?: Look }) {
  const [mount] = useState(() => mounted(look));
  return (
    <div style={{ width: 340, padding: 12 }}>
      <SceneMount mounted={mount} />
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cmux-app-scene-mount svg") !== null);
};

export default componentEntry<{ look?: Look }>({
  id: "apps.scene-rings",
  title: "App scene rings (shape trim)",
  area: "Apps",
  pane: true,
  height: 220,
  widths: { narrow: 320, normal: 364 },
  covers: ["apps/scene/SceneRenderer.tsx", "apps/scene/sceneStyle.ts", "apps/scene/scene.css"],
  load: async () => SceneRings,
  variants: {
    activity: {
      note: "Apple-style activity rings: three nested Circles with stroke, trim {to, lineCap: round} from 12 o'clock clockwise, over dimmed tracks.",
      props: { look: "activity" },
      play: ready,
    },
    swept: {
      note: "After Close the rings: each arc sweeps to a full ring on animation smooth (drawn at once under Reduce Motion or calm motion).",
      props: { look: "activity" },
      play: async (ctx) => {
        await ready(ctx);
        await ctx.click({ text: "Close the rings" });
      },
    },
    usage: {
      note: "Usage rings in theme tones with the value inside (ZStack), on separator tracks; an empty ring draws only its track.",
      props: { look: "usage" },
      play: ready,
    },
  },
});
