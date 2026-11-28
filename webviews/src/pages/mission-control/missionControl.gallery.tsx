// l10n-allow-file: gallery fixtures (public-safe sample sessions), not shipped UI.
// Mission control (wow-20 idea 8): every session as a live thumbnail, badged working, waiting on you
// or done. Chosen: `v1-corner` (the badge over the picture's corner, read before the title). The
// alternatives it was weighed against: `v2-caption` (the badge before the title, icon only) and
// `v3-dense` (smaller tiles, more per row).
import { componentEntry } from "../../gallery/format";
import { FIXTURE_STRINGS, fixtureTiles } from "./fixtures";
import { MissionControl, type MissionBadgePlace } from "./MissionControl";
import { DEFAULT_METRICS, type MissionGridMetrics } from "./model";

type Props = { count: number; thumbs?: boolean; badge?: MissionBadgePlace; metrics?: MissionGridMetrics };

function MissionControlGallery({ count, thumbs, badge, metrics }: Props) {
  return (
    <div style={{ height: 560 }}>
      <MissionControl
        tiles={fixtureTiles(count, { thumbs })}
        strings={FIXTURE_STRINGS}
        badge={badge}
        metrics={metrics}
      />
    </div>
  );
}

export default componentEntry<Props>({
  id: "pages.mission-control",
  title: "Mission control",
  area: "Pages",
  height: 560,
  widths: { narrow: 520, normal: 900, wide: 1280 },
  covers: ["pages/mission-control/MissionControl.tsx"],
  keywords: ["mission control", "sessions", "grid", "thumbnails", "fleet", "overview"],
  load: async () => MissionControlGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    "v1-corner": {
      note: "Chosen: 12 sessions, the badge over the picture's top right corner with its words.",
      props: { count: 12 },
    },
    "v2-caption": {
      note: "V2 (not chosen): the badge's glyph before the title, no words; quieter, but waiting reads later.",
      props: { count: 12, badge: "caption" },
    },
    "v3-dense": {
      note: "V3 (not chosen): 180 px tiles, more per row; the pictures get too small to read a terminal.",
      props: { count: 24, metrics: { ...DEFAULT_METRICS, minTileWidth: 180, gap: 8 } },
    },
    "two-hundred": {
      note: "200 sessions: only the rows in sight and one viewport each side mount (data-mounted on the page).",
      props: { count: 200 },
    },
    "no-pictures": {
      note: "Sessions with no snapshot yet: the tile says so instead of a blank.",
      props: { count: 6, thumbs: false },
    },
    empty: {
      note: "No sessions.",
      props: { count: 0 },
    },
  },
});
