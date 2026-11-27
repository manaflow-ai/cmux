// l10n-allow-file: gallery fixture text, not shipped UI.
// The cmux/weather widget (first-party-apps/widget-weather, a cmux.widget/1 store app) in each size
// and sky, drawn by the web scene renderer from the exact ops its render export emits: the widget
// ran in the fake host against invented Open-Meteo answers (preview/build.ts writes scenes.json).
// The tile is Apple's macOS widget size (small 170, medium 364 x 170, large 364 x 382) with its
// corner radius; the New Tab grid's own frame comes from the widget primitive.
import { useState } from "react";
import scenes from "../../../../first-party-apps/widget-weather/preview/scenes.json";
import { componentEntry } from "../../gallery/format";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";

type State = keyof typeof scenes;
type GalleryState = State | "small-clear-day-flat";
type Props = { state?: GalleryState };

const TILE = {
  small: { width: 170, height: 170 },
  medium: { width: 364, height: 170 },
  large: { width: 364, height: 382 },
};

const TILE_CSS = `.weather-gallery-tile > .cmux-app-scene-root { flex: 1 1 auto; display: flex; width: 100%; min-height: 0 }
.weather-gallery-tile > .cmux-app-scene-root > [data-app-node],
.weather-gallery-tile > .cmux-app-scene-root > .cmux-app-scene-context > [data-app-node] { flex: 1 1 auto; width: 100% }`;

/** Keep the previous flat, single-color scene available for What's New before/after captures. */
function flatBefore(ops: readonly SceneOp[]): SceneOp[] {
  const root = ops.find((op) => op.op === "root")?.id;
  return ops.map((op) => {
    if (op.op !== "create") return op;
    const props = { ...(op.props ?? {}) };
    if (op.id === root) props.background = "#3A86D4";
    if (op.type === "Icon") {
      delete props.symbolRendering;
      delete props.symbolColors;
    }
    return { ...op, props };
  });
}

function WeatherWidget({ state = "small-clear-day" }: { state?: GalleryState }) {
  const before = state === "small-clear-day-flat";
  const scene = scenes[before ? "small-clear-day" : (state as State)];
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply((before ? flatBefore(scene.ops as SceneOp[]) : scene.ops) as SceneOp[], true);
    return s;
  });
  const size = TILE[scene.size as keyof typeof TILE];
  // The New Tab card (widgets.css .nt-widget-card) grows the scene root to the tile; do the same here.
  return (
    <div
      className="weather-gallery-tile"
      style={{ ...size, minWidth: size.width, flexShrink: 0, borderRadius: 16, overflow: "hidden", display: "flex" }}
    >
      <style>{TILE_CSS}</style>
      <SceneRenderer store={store} dispatch={() => {}} />
    </div>
  );
}

export default componentEntry<Props>({
  id: "apps.weather-widget",
  title: "Weather widget (cmux/weather store app)",
  area: "Apps",
  pane: true,
  height: 420,
  widths: { normal: 440 },
  keywords: ["weather", "widget", "cmux.widget/1", "new tab", "open-meteo", "forecast"],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => WeatherWidget,
  variants: {
    "small-clear-day": {
      note: "Chosen: Apple's small Weather widget (HIG reference hig-weather-small): the place with the location arrow (found from the internet address), the big temperature, the sun, Sunny, H and L, on the clear day's blue. US locale: Fahrenheit.",
      props: { state: "small-clear-day" },
    },
    "small-clear-day-flat": {
      note: "Before: the original flat clear-day fill and monochrome symbols, kept for the gradient and multicolor before/after.",
      props: { state: "small-clear-day-flat" },
    },
    "small-clear-night": {
      note: "Night: the moon and Clear on navy. A locale with no region (en) reads the place's country: Tokyo, Celsius.",
      props: { state: "small-clear-night" },
    },
    "small-plain": {
      note: "Background: plain. The theme's background and text, for people who want the widget to match the page (check light and dark).",
      props: { state: "small-plain" },
    },
    "small-no-network": {
      note: "Network access not granted yet: the frame says how to allow it instead of a blank tile.",
      props: { state: "small-no-network" },
    },
    "medium-clear-day": {
      note: "Medium (Apple's macOS Sonoma desktop widget): the condition, H and L at the top right, and the next six hours.",
      props: { state: "medium-clear-day" },
    },
    "medium-rain": {
      note: "Rain in Lisbon on the grey rain sky; the strip runs into the evening, where the symbols turn to night.",
      props: { state: "medium-rain" },
    },
    "medium-plain-rain": {
      note: "Medium on the plain background.",
      props: { state: "medium-plain-rain" },
    },
    "large-clear-night": {
      note: "Large: the medium layout, then today and five days with Apple's range bars over the week's span.",
      props: { state: "large-clear-night" },
    },
    "large-snow": {
      note: "Snow in Denver below freezing, in Fahrenheit.",
      props: { state: "large-snow" },
    },
  },
});
