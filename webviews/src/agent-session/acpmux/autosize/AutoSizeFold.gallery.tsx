// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { AutoSizeRow } from "./autosizeModel";
import { GREW_FOR_MEMORY, HELD_AT_PLAN_LIMIT, HELD_SHARED, SHRANK_IDLE } from "./autosizeModel.fixtures";

type Props = { rows: AutoSizeRow[]; open?: boolean };

/// The dock over the composer (place/PlaceMounts.tsx AutoSizeDock): the newest row, the rest behind "N earlier".
export default componentEntry<Props>({
  id: "agent-pane.autosize-dock",
  title: "AutoSize dock",
  area: "Agent pane",
  pane: true,
  height: 160,
  widths: { narrow: 320, normal: 720, wide: 900 },
  covers: ["agent-session/acpmux/autosize/AutoSizeRow.tsx", "agent-session/acpmux/place/PlaceMounts.tsx"],
  load: async () => {
    const { AutoSizeFold } = await import("./AutoSizeRow");
    return function GalleryAutoSizeFold({ rows, open }: Props) {
      return (
        <div className="acpmux-shell" style={{ padding: 12 }}>
          <AutoSizeFold rows={rows} initiallyOpen={open} onUpgrade={() => {}} />
        </div>
      );
    };
  },
  styles: () => import("../styles.css"),
  variants: {
    "one-row": { props: { rows: [GREW_FOR_MEMORY] } },
    "folded-hold-with-count": { props: { rows: [GREW_FOR_MEMORY, SHRANK_IDLE, HELD_SHARED] } },
    "upgrade-offer": { props: { rows: [GREW_FOR_MEMORY, HELD_AT_PLAN_LIMIT] } },
    unfolded: { props: { rows: [GREW_FOR_MEMORY, SHRANK_IDLE, HELD_AT_PLAN_LIMIT], open: true } },
  },
});
