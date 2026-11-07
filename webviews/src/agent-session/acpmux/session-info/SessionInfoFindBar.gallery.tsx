// l10n-allow-file: gallery entry notes, not shipped UI.
// Find in Chat's bar beside Session Info in wide panes (sessionInfoFindBarPlay.ts).
import { componentEntry } from "../../../gallery/format";
import {
  findBarCovers as covers,
  findBarLoad as load,
  findBarStyles as styles,
  findBesidePanel,
  type FindBarProps as Props,
} from "./sessionInfoFindBarPlay";

export default componentEntry<Props>({
  id: "agent-pane.session-info-find-bar",
  title: "Find in Chat sits left of Session Info in every stage: in the gutter, pushing, over the chat",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 1100, normal: 1200, wide: 1600 },
  covers,
  load,
  styles,
  variants: {
    "find-open": {
      note: "Session Info open, then Cmd-F: at 1600px the panel floats in the gutter, at 1100px it pushes the column, at 1200px it lies over the chat. The bar sits in the chat's column, its right edge the panel's left less the inset.",
      props: { surface: "transcript", find: true },
      play: findBesidePanel,
    },
  },
});
