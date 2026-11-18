// l10n-allow-file: gallery fixture text, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SceneMount } from "./panels";
import type { MountedPanel } from "./panelsClient";
import { SceneStore, type SceneOp } from "./store";

type Look = "weather-day" | "weather-night" | "rendering-modes";

const sky = {
  day: { linear: { colors: ["#2F7FD6", "#69A8E8"], angle: 180 } },
  night: { linear: { colors: ["#0B1A3A", "#253B6E", "#3A4E86"], angle: 180 } },
};

const hours: Array<[string, string, string]> = [
  ["Now", "cloud.sun.fill", "18°"],
  ["3PM", "sun.max.fill", "19°"],
  ["4PM", "cloud.sun.rain.fill", "17°"],
  ["5PM", "cloud.rain.fill", "15°"],
  ["6PM", "cloud.bolt.rain.fill", "14°"],
];

/** An Apple-style medium weather tile: a sky gradient, big temperature, multicolor symbols. */
const weather = (night: boolean): SceneOp[] => {
  const white = "#FFFFFF";
  const dim = "#FFFFFFB3";
  const ops: SceneOp[] = [
    {
      op: "create",
      id: "tile",
      type: "VStack",
      props: { spacing: 10, padding: 16, cornerRadius: 22, background: night ? sky.night : sky.day },
    },
    { op: "create", id: "top", type: "HStack", props: { spacing: 8 } },
    { op: "create", id: "left", type: "VStack", props: { spacing: 0 } },
    {
      op: "create",
      id: "city",
      type: "Text",
      props: { text: "Cupertino", font: "headline", weight: "semibold", color: white },
    },
    {
      op: "create",
      id: "temp",
      type: "Text",
      props: { text: night ? "12°" : "18°", font: 40, weight: "light", color: white },
    },
    { op: "create", id: "gap", type: "Spacer", props: {} },
    { op: "create", id: "right", type: "VStack", props: { spacing: 2, alignment: "trailing" } },
    {
      op: "create",
      id: "now",
      type: "Icon",
      props: {
        symbol: night ? "moon.stars.fill" : "cloud.sun.fill",
        size: 22,
        color: white,
        symbolRendering: "multicolor",
      },
    },
    {
      op: "create",
      id: "cond",
      type: "Text",
      props: { text: night ? "Clear" : "Partly Cloudy", font: "caption", color: white },
    },
    { op: "create", id: "range", type: "Text", props: { text: "H:21° L:9°", font: "caption", color: dim } },
    { op: "create", id: "hours", type: "HStack", props: { spacing: 0 } },
  ];
  const hourIds: string[] = [];
  hours.forEach(([label, symbol, temp], index) => {
    const id = `h${index}`;
    hourIds.push(id);
    ops.push(
      { op: "create", id, type: "VStack", props: { spacing: 6, alignment: "center", frame: { maxWidth: "infinity" } } },
      { op: "create", id: `${id}-t`, type: "Text", props: { text: label, font: "caption", color: dim } },
      {
        op: "create",
        id: `${id}-i`,
        type: "Icon",
        props: { symbol, size: 18, color: white, symbolRendering: "multicolor" },
      },
      {
        op: "create",
        id: `${id}-v`,
        type: "Text",
        props: { text: temp, font: "callout", weight: "medium", color: white },
      },
      { op: "children", id, children: [`${id}-t`, `${id}-i`, `${id}-v`] },
    );
  });
  ops.push(
    { op: "children", id: "left", children: ["city", "temp"] },
    { op: "children", id: "right", children: ["now", "cond", "range"] },
    { op: "children", id: "top", children: ["left", "gap", "right"] },
    { op: "children", id: "hours", children: hourIds },
    { op: "children", id: "tile", children: ["top", "hours"] },
    { op: "root", id: "tile" },
  );
  return ops;
};

/** One symbol in each rendering mode, over a radial-gradient chip, beside gradient-filled shapes. */
const modes: SceneOp[] = [
  { op: "create", id: "root", type: "VStack", props: { spacing: 12, padding: 12 } },
  { op: "create", id: "row", type: "HStack", props: { spacing: 12 } },
  ...(["monochrome", "hierarchical", "palette", "multicolor"] as const).flatMap((mode): SceneOp[] => [
    {
      op: "create",
      id: `chip-${mode}`,
      type: "VStack",
      props: {
        spacing: 6,
        alignment: "center",
        padding: 10,
        cornerRadius: 14,
        background: { radial: { colors: ["#3A4E86", "#0B1A3A"] } },
      },
    },
    {
      op: "create",
      id: `icon-${mode}`,
      type: "Icon",
      props: {
        symbol: "cloud.sun.rain.fill",
        size: 28,
        color: "#FFFFFF",
        symbolRendering: mode,
        ...(mode === "palette" ? { symbolColors: ["#FFFFFF", "#FFCC00", "#64D2FF"] } : {}),
      },
    },
    { op: "create", id: `label-${mode}`, type: "Text", props: { text: mode, font: "caption2", color: "#FFFFFFB3" } },
    { op: "children", id: `chip-${mode}`, children: [`icon-${mode}`, `label-${mode}`] },
  ]),
  { op: "create", id: "shapes", type: "HStack", props: { spacing: 12 } },
  {
    op: "create",
    id: "circle",
    type: "Circle",
    props: { size: 40, fill: { linear: { colors: ["#FF9F0A", "#FF375F"], angle: 135 } } },
  },
  {
    op: "create",
    id: "rounded",
    type: "RoundedRectangle",
    props: { size: 40, cornerRadius: 10, fill: { linear: { colors: ["success", "#0A84FF"], angle: 90 } } },
  },
  {
    op: "create",
    id: "capsule",
    type: "Capsule",
    props: { size: 40, fill: { radial: { colors: ["#FFCC00", "#FF9F0A", "#FF453A"] } } },
  },
  {
    op: "children",
    id: "row",
    children: ["monochrome", "hierarchical", "palette", "multicolor"].map((m) => `chip-${m}`),
  },
  { op: "children", id: "shapes", children: ["circle", "rounded", "capsule"] },
  { op: "children", id: "root", children: ["row", "shapes"] },
  { op: "root", id: "root" },
];

function mounted(look: Look): MountedPanel {
  const store = new SceneStore();
  const ops = look === "rendering-modes" ? modes : weather(look === "weather-night");
  store.apply(ops);
  return {
    panel: { app: "local/customize", section: "gallery", title: "Gallery" },
    store,
    dispatch: () => undefined,
    reload: () => store.apply(ops, true),
    layout: () => undefined,
    resolveAsset: () => undefined,
  };
}

function SceneGradients({ look = "weather-day" }: { look?: Look }) {
  const [mount] = useState(() => mounted(look));
  return (
    <div style={{ width: 340, padding: 12 }}>
      <SceneMount mounted={mount} />
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cmux-app-scene-mount") !== null);
};

export default componentEntry<{ look?: Look }>({
  id: "apps.scene-gradients",
  title: "App scene gradients and symbol rendering",
  area: "Apps",
  pane: true,
  height: 260,
  widths: { narrow: 320, normal: 364 },
  covers: ["apps/scene/sceneStyle.ts", "apps/scene/SceneSymbol.tsx", "apps/scene/SceneRenderer.tsx"],
  load: async () => SceneGradients,
  variants: {
    "weather-day": {
      note: "A medium weather tile on a linear sky gradient with multicolor symbols in the hourly strip (one-color glyphs such as the sun in their color, layered ones in the tint).",
      props: { look: "weather-day" },
      play: ready,
    },
    "weather-night": {
      note: "The same tile at night: a three-stop gradient and a multicolor moon.",
      props: { look: "weather-night" },
      play: ready,
    },
    "rendering-modes": {
      note: "cloud.sun.rain.fill in each symbolRendering mode on radial-gradient chips, and shapes with gradient fills.",
      props: { look: "rendering-modes" },
      play: ready,
    },
  },
});
