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
type Props = { state?: State };

const TILE = {
  small: { width: 170, height: 170 },
  medium: { width: 364, height: 170 },
  large: { width: 364, height: 382 },
};

function WeatherWidget({ state = "small-clear-day" }: Props) {
  const scene = scenes[state];
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(scene.ops as SceneOp[], true);
    return s;
  });
  const size = TILE[scene.size as keyof typeof TILE];
  return (
    <div style={{ ...size, borderRadius: 22, overflow: "hidden", display: "flex" }}>
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
  widths: { normal: 400 },
  keywords: ["weather", "widget", "cmux.widget/1", "new tab", "open-meteo", "forecast"],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => WeatherWidget,
  variants: {
    "small-clear-day": {
      note: "Chosen: Apple's small Weather widget (HIG reference hig-weather-small): the place with the location arrow (found from the internet address), the big temperature, the sun, Sunny, H and L, on the clear day's blue. US locale: Fahrenheit.",
      props: { state: "small-clear-day" },
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
