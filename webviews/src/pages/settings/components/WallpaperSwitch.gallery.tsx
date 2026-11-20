// l10n-allow-file: gallery fixtures (sample pictures and schedules), not shipped UI.
// Switch Automatically in the Background card, three ways to choose the mode:
// - segmented: the five modes in one segmented row, the chosen mode's editor under it.
// - menu: one "Switch Automatically" menu and a summary line of what changes when.
// - timeline: the segmented row, and Time of Day also drawn as a strip of the day.
// Shipped: segmented, because every mode stays one click away and visible at once, like the card's
// All Workspaces | This Workspace row, while the menu hides the choice and the strip only helps one mode.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { PictureChoice, WallpaperValues, WallpaperWrite } from "../wallpaperSwitch";
import { WallpaperSwitch, type WallpaperSwitchDesign } from "./WallpaperSwitch";

const choices: PictureChoice[] = [
  { id: "none", title: "No wallpaper" },
  { id: "desktop", title: "My Desktop Picture" },
  { id: "starryNight", title: "The Starry Night" },
  { id: "friedrich-forest-moonlight", title: "Forest in Moonlight" },
  {
    id: "system:/System/Library/Desktop Pictures/Sonoma.madesktop",
    title: "Sonoma",
    collection: "apple",
    dynamic: true,
  },
  {
    id: "system:/System/Library/Desktop Pictures/Ventura.madesktop",
    title: "Ventura",
    collection: "apple",
    dynamic: true,
  },
  { id: "file:/Users/me/Pictures/Harbor.png", title: "Harbor", collection: "yours" },
];

const KEYS: Record<string, keyof WallpaperValues> = {
  "appearance.background": "background",
  "appearance.backgroundLight": "light",
  "appearance.backgroundDark": "dark",
  "appearance.backgroundSchedule": "schedule",
  "appearance.backgroundDynamic": "dynamic",
};

type Props = { design: WallpaperSwitchDesign; values: WallpaperValues };

function WallpaperSwitchFixture({ design, values: initial }: Props) {
  const [values, setValues] = useState(initial);
  const [location, setLocation] = useState<string | null>(null);
  const write = (writes: WallpaperWrite[]) =>
    setValues((now) => {
      const next = { ...now } as Record<string, unknown>;
      for (const [key, value] of writes) {
        const field = KEYS[key];
        if (field) next[field] = value ?? (field === "dynamic" ? "appearance" : null);
      }
      return next as WallpaperValues;
    });
  return (
    <section className="settings-page" style={{ padding: 16 }}>
      <section className="group" data-card="backdrop">
        <WallpaperSwitch
          design={design}
          values={values}
          choices={choices}
          location={location}
          yoursFolder="/Users/me/Pictures"
          onWrite={write}
          onLocation={setLocation}
          onChooseFolder={() => undefined}
        />
      </section>
    </section>
  );
}

const off: WallpaperValues = {
  background: "starryNight",
  light: null,
  dark: null,
  schedule: null,
  dynamic: "appearance",
};
const lightDark: WallpaperValues = {
  ...off,
  background: "appearance",
  light: "starryNight",
  dark: "friedrich-forest-moonlight",
};
const timeOfDay: WallpaperValues = {
  ...off,
  background: "schedule",
  schedule: {
    "07:00": "starryNight",
    "sunset-30m": "file:/Users/me/Pictures/Harbor.png",
    dusk: "friedrich-forest-moonlight",
  },
};
const sun: WallpaperValues = { ...off, background: choices[4]!.id, dynamic: "time" };

export default componentEntry<Props>({
  id: "settings.wallpaper-switch",
  title: "Background: Switch Automatically",
  area: "Settings",
  height: 520,
  widths: { narrow: 420, normal: 680 },
  covers: ["pages/settings/components/WallpaperSwitch.tsx#WallpaperSwitch"],
  load: async () => {
    // The control's labels come from the Settings catalog, which this component host does not load.
    const { installCatalog } = await import("../strings");
    installCatalog((await import("../generated/strings.json")).default);
    return WallpaperSwitchFixture;
  },
  styles: () => import("../page.css"),
  variants: {
    "segmented-off": {
      note: "Shipped: five modes in one row; Off has no editor.",
      props: { design: "segmented", values: off },
    },
    "segmented-light-dark": {
      note: "Shipped: Light and Dark picture slots.",
      props: { design: "segmented", values: lightDark },
    },
    "segmented-time-of-day": {
      note: "Shipped: When rows, a picture each.",
      props: { design: "segmented", values: timeOfDay },
    },
    "segmented-sun": {
      note: "Shipped: a dynamic macOS picture following the sun.",
      props: { design: "segmented", values: sun },
    },
    "menu-light-dark": { note: "One menu and a summary line.", props: { design: "menu", values: lightDark } },
    "menu-time-of-day": {
      note: "One menu; the summary lists every start.",
      props: { design: "menu", values: timeOfDay },
    },
    "timeline-time-of-day": {
      note: "The day as a strip over the rows.",
      props: { design: "timeline", values: timeOfDay },
    },
  },
});
