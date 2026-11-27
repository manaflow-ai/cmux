// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { AutoSizeLook } from "./AutoSizeRow";
import type { AutoSizeRow } from "./autosizeModel";
import {
  GREW_FOR_MEMORY,
  HELD_AT_PLAN_LIMIT,
  HELD_SHARED,
  HELD_UNKNOWN_CODE,
  ROWS,
  SHRANK_IDLE,
} from "./autosizeModel.fixtures";

type Props = { rows: AutoSizeRow[]; look: AutoSizeLook };

export default componentEntry<Props>({
  id: "agent-pane.autosize-rows",
  title: "AutoSize rows",
  area: "Agent pane",
  pane: true,
  height: 180,
  widths: { narrow: 320, normal: 720, wide: 900 },
  covers: ["agent-session/acpmux/autosize/AutoSizeRow.tsx"],
  load: async () => {
    const { AutoSizeRows } = await import("./AutoSizeRow");
    return function GalleryAutoSizeRows({ rows, look }: Props) {
      return (
        <div className="acpmux-shell" style={{ padding: 12 }}>
          <AutoSizeRows rows={rows} look={look} onUpgrade={() => {}} />
        </div>
      );
    };
  },
  styles: () => import("../styles.css"),
  variants: {
    "line-sequence": { props: { rows: ROWS, look: "line" } },
    "chip-sequence": { props: { rows: ROWS, look: "chip" } },
    "card-sequence": { props: { rows: ROWS, look: "card" } },
    "line-plan-limit": { props: { rows: [HELD_AT_PLAN_LIMIT], look: "line" } },
    "card-plan-limit": { props: { rows: [HELD_AT_PLAN_LIMIT], look: "card" } },
    "card-shared-view": { props: { rows: [HELD_SHARED], look: "card" } },
    "line-grow": { props: { rows: [GREW_FOR_MEMORY], look: "line" } },
    "line-shrink": { props: { rows: [SHRANK_IDLE], look: "line" } },
    "line-unknown-hold": { props: { rows: [HELD_UNKNOWN_CODE], look: "line" } },
  },
});
