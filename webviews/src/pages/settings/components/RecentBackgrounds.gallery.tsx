// l10n-allow-file: gallery fixtures (sample folders and pictures), not shipped UI.
// The Background card's Recent strip: the backgrounds shown before, one click each.
// - empty: nothing changed yet, so the strip is not drawn at all.
// - mixed: a rotating folder, a picture, the paintings shuffle and Light & Dark.
// - many: the full eight, folders and pictures, wrapping in a narrow window.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { recentTiles } from "../recentBackgrounds";
import { RecentBackgrounds } from "./RecentBackgrounds";

const choices = [
  { id: "desktop", title: "My Desktop Picture" },
  { id: "starryNight", title: "The Starry Night" },
  { id: "friedrich-forest-moonlight", title: "Forest in Moonlight" },
  { id: "file:/Users/me/Pictures/Harbor.png", title: "Harbor" },
];
const words = {
  shuffle: "Shuffle Paintings",
  none: "No wallpaper",
  appearance: "Light & Dark",
  schedule: "Time of Day",
};

type Props = { current: string; recents: string[] };

function RecentFixture({ current: initial, recents: initialRecents }: Props) {
  const [current, setCurrent] = useState(initial);
  const [recents, setRecents] = useState(initialRecents);
  // As the settings write keeps it: the replaced one first, the new one out of the list.
  const choose = (id: string) => {
    setRecents((list) => [current, ...list.filter((item) => item !== current && item !== id)].slice(0, 8));
    setCurrent(id);
  };
  return (
    <section className="settings-page" style={{ padding: 16 }}>
      <section className="group" data-card="backdrop">
        <p className="row-help">Now: {current}</p>
        <RecentBackgrounds tiles={recentTiles(recents, current, choices, words)} onChoose={choose} />
      </section>
    </section>
  );
}

export default componentEntry<Props>({
  id: "settings.recent-backgrounds",
  title: "Background: Recent",
  area: "Settings",
  height: 320,
  widths: { narrow: 420, normal: 680 },
  covers: ["pages/settings/components/RecentBackgrounds.tsx#RecentBackgrounds"],
  load: async () => {
    const { installCatalog } = await import("../strings");
    installCatalog((await import("../generated/strings.json")).default);
    return RecentFixture;
  },
  styles: () => import("../page.css"),
  variants: {
    empty: {
      note: "No change yet: the strip is not drawn.",
      props: { current: "starryNight", recents: [] },
    },
    mixed: {
      note: "A rotating folder, a picture, the shuffle and a mode; a click swaps.",
      props: {
        current: "folder:/Users/me/Pictures/Walls",
        recents: ["starryNight", "daily", "appearance", "file:/Users/me/Pictures/Harbor.png"],
      },
    },
    many: {
      note: "The full eight, wrapping.",
      props: {
        current: "desktop",
        recents: [
          "folder:/Users/me/Pictures/Walls",
          "file:/Users/me/Pictures/Harbor.png",
          "folder:/Users/me/Pictures/Travel 2025",
          "starryNight",
          "daily",
          "friedrich-forest-moonlight",
          "schedule",
          "none",
        ],
      },
    },
  },
});
