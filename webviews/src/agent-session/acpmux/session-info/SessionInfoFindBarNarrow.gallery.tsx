// l10n-allow-file: gallery entry notes, not shipped UI.
// Find in Chat's bar beside Session Info in narrow panes (sessionInfoFindBarPlay.ts).
import { componentEntry } from "../../../gallery/format";
import {
  findBarCovers as covers,
  findBarLoad as load,
  findBarStyles as styles,
  findBesidePanel,
  type FindBarProps as Props,
} from "./sessionInfoFindBarPlay";

export default componentEntry<Props>({
  id: "agent-pane.session-info-find-bar-narrow",
  title: "Find in Chat beside Session Info in a narrow pane: narrowed beside it, or the panel steps aside",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { normal: 528, wide: 740 },
  covers,
  load,
  styles,
  variants: {
    "find-open": {
      note: "At 740px the panel lies over the chat and the bar narrows to the room left of it. At 528px even the bar's narrowest has no room beside the panel, so the panel steps aside when Find opens; its toggle brings it back and closes Find.",
      props: { surface: "transcript", find: true },
      play: findBesidePanel,
    },
  },
});
