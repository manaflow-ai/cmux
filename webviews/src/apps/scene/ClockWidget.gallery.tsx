// l10n-allow-file: gallery fixture text, not shipped UI.
// The store app first-party-apps/widget-clock (cmux/clock, a cmux.widget/1) in each size and face,
// drawn by the web scene renderer from the ops its render export sends at 9:41 AM on Monday,
// November 16 (ClockWidget.scenes.json, written by its preview/build.ts from the packed app). The tile
// is a stand-in for the widget host's card: the New Tab host's small tile (148, as a DEV build draws it),
// Apple's macOS medium and large (364 x 170, 364 x 382) and a 22 pt corner; the widget insets its own content. Light and dark use the gallery theme switch.
import { useState } from "react";
import scenes from "./ClockWidget.scenes.json";
import { componentEntry } from "../../gallery/format";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";
import "./ClockWidget.gallery.css";

type Variant = keyof typeof scenes;
type Props = { variant?: Variant; all?: boolean };

function Tile({ variant }: { variant: Variant }) {
  const scene = scenes[variant];
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(scene.ops as SceneOp[], true);
    return s;
  });
  return (
    <div className="gallery-clock-widget-tile" data-size={scene.size} data-variant={variant}>
      <SceneRenderer store={store} dispatch={() => {}} />
    </div>
  );
}

function ClockWidget({ variant = "small", all = false }: Props) {
  if (!all) return <div className="gallery-clock-widget">{<Tile variant={variant} />}</div>;
  return (
    <div className="gallery-clock-widget" data-all="">
      <div className="gallery-clock-widget-row">
        <Tile variant="small" />
        <Tile variant="small-analog" />
      </div>
      <Tile variant="medium" />
      <Tile variant="medium-analog" />
      <Tile variant="large" />
    </div>
  );
}

export default componentEntry<Props>({
  id: "apps.clock-widget",
  title: "Clock widget (store app)",
  area: "Apps",
  pane: true,
  height: 460,
  widths: { narrow: 420, normal: 440 },
  keywords: ["widget", "clock", "time", "world clock", "cmux.widget", "lock screen"],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => ClockWidget,
  variants: {
    small: {
      note: "Chosen small: the weekday in red over the date, the time big and heavy at the bottom, as Apple's Calendar and Lock Screen do. Zero setup.",
      props: { variant: "small" },
    },
    medium: {
      note: "Medium: the small layout on the left; two cities on the right, each with its time, how far it is from you and Tomorrow when its day is not yours. The defaults skip cities at your own time.",
      props: { variant: "medium" },
    },
    large: {
      note: "Large: the Lock Screen's date line over the time, then four cities.",
      props: { variant: "large" },
    },
    "small-analog": {
      note: "Face: analog. A dial with twelve ticks and the hour and minute hands, the day under it.",
      props: { variant: "small-analog" },
    },
    "medium-analog": {
      note: "Face: analog, medium: Apple's World Clock row, here and three cities, each named under its dial.",
      props: { variant: "medium-analog" },
    },
    "large-24h": {
      note: "Settings: a 24-hour clock and cities the person typed (Paris, Kolkata, Singapore, Auckland), shown as written.",
      props: { variant: "large-24h" },
    },
    "thin-glass": {
      note: "Look settings (the New Tab clock's options): the system font, thin, in glass (the theme's text, translucent).",
      props: { variant: "thin-glass" },
    },
    "mono-accent": {
      note: "Look settings: monospaced and bold in the theme's accent.",
      props: { variant: "mono-accent" },
    },
    "serif-orange-no-date": {
      note: "Look settings: serif, regular, a #FF9500 color the person typed, the date off. Serif and rounded draw once the scene renderer has fontDesign.",
      props: { variant: "serif-orange-no-date" },
    },
    "small-12h-widest": {
      note: "The widest 12-hour time, 10:58 PM, in the small tile: the digits are sized to the tile so the time and its PM fit (they clipped the PM at 50 pt, cmux#44962).",
      props: { variant: "small-12h-widest" },
    },
    "small-mono-12h-widest": {
      note: "10:58 PM, monospaced and heavy (the widest font) in the small tile: the time and its PM fit.",
      props: { variant: "small-mono-12h-widest" },
    },
    "small-24h-widest": {
      note: "22:58 on a 24-hour clock in the small tile: no PM, so the digits take the whole width.",
      props: { variant: "small-24h-widest" },
    },
    "all-sizes": {
      note: "Every size side by side, as the widget gallery offers them.",
      props: { all: true },
    },
  },
});
