// l10n-allow-file: gallery fixture text, not shipped UI.
// The store app first-party-apps/widget-calendar (cmux/calendar, a cmux.widget/1) in each size and
// state, drawn by the web scene renderer from the ops its render export sends at 1:12 PM on Tuesday,
// November 17 with a fake calendar (preview/scenes.json, written by its preview/build.ts from the
// packed app). The tile is a stand-in for the widget host's frame: Apple's macOS widget sizes (small
// 170, medium 364 x 170, large 364 x 382) and a continuous corner. Light and dark use the gallery
// theme switch.
import { useState } from "react";
import scenes from "../../../../first-party-apps/widget-calendar/preview/scenes.json";
import { componentEntry } from "../../gallery/format";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";
import "./CalendarWidget.gallery.css";

type Variant = keyof typeof scenes;
type Props = { variant?: Variant; all?: boolean; clear?: boolean };

function Tile({ variant }: { variant: Variant }) {
  const scene = scenes[variant];
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(scene.ops as SceneOp[], true);
    return s;
  });
  return (
    <div className="gallery-calendar-widget-tile" data-size={scene.size} data-variant={variant}>
      <SceneRenderer store={store} dispatch={() => {}} />
    </div>
  );
}

function CalendarWidget({ variant = "small", all = false, clear = false }: Props) {
  if (clear) {
    return (
      <div className="gallery-calendar-widget" data-all="">
        <Tile variant="small-clear" />
        <Tile variant="medium-clear" />
        <Tile variant="large-empty" />
      </div>
    );
  }
  if (!all) return <div className="gallery-calendar-widget">{<Tile variant={variant} />}</div>;
  return (
    <div className="gallery-calendar-widget" data-all="">
      <Tile variant="small" />
      <Tile variant="medium" />
      <Tile variant="large" />
    </div>
  );
}

export default componentEntry<Props>({
  id: "apps.calendar-widget",
  title: "Calendar widget (store app)",
  area: "Apps",
  pane: true,
  height: 460,
  widths: { narrow: 420, normal: 440 },
  keywords: ["widget", "calendar", "up next", "events", "eventkit", "cmux.widget"],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => CalendarWidget,
  variants: {
    small: {
      note: "Chosen small, a busy day: the weekday in red over the date, then the next two events, each a block tinted with its calendar's color and a bar of that color.",
      props: { variant: "small" },
    },
    medium: {
      note: "Medium, a busy day: the next event under the date on the left (with its place); the rest of today on the right.",
      props: { variant: "medium" },
    },
    large: {
      note: "Large, a busy day: Apple's hour grid. Today from the current hour under the date, the red now line at 1:12, each event a tinted block at its time; tomorrow from an hour before its first event.",
      props: { variant: "large" },
    },
    "small-clear": {
      note: "Empty: nothing is left today, so it says No more events today, as Apple's widget does.",
      props: { variant: "small-clear" },
    },
    "medium-clear": {
      note: "Empty today, medium: No more events today on the left; tomorrow's first events on the right.",
      props: { variant: "medium-clear" },
    },
    "medium-all-day": {
      note: "All-day event: its title alone on the tint, above the day's timed events.",
      props: { variant: "medium-all-day" },
    },
    "large-all-day": {
      note: "All-day events today and tomorrow, large: a row above the hour grid in both columns, so the hours stay level.",
      props: { variant: "large-all-day" },
    },
    "large-empty": {
      note: "Empty today and tomorrow, large: the hour grid with No more events today and No events.",
      props: { variant: "large-empty" },
    },
    "small-ask": {
      note: "First install: one Allow Access button; a tap shows macOS's calendar prompt in place, then the events.",
      props: { variant: "small-ask" },
    },
    "medium-denied": {
      note: "Access turned off: it says where to turn it on (Privacy & Security > Calendars); macOS cannot ask twice.",
      props: { variant: "medium-denied" },
    },
    "large-list": {
      note: "Settings, large as a list: the rest of today on the left with a count of what does not fit; tomorrow on the right.",
      props: { variant: "large-list" },
    },
    "large-24h": {
      note: "Settings: a 24-hour clock on the hour grid.",
      props: { variant: "large-24h" },
    },
    "all-sizes": {
      note: "Every size side by side, a busy day.",
      props: { all: true },
    },
    "clear-day": {
      note: "Every size on a clear day.",
      props: { clear: true },
    },
  },
});
