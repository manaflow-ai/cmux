// l10n-allow-file: synthetic gallery conversation, not shipped UI.
// The font pack (FontPack.gallery.ts) at a desktop column, about 900 px: the rich reply, pack off
// and on, where the serif's measure and the code block's width read as they will in a wide pane.
import { agentPaneEntry } from "../../../gallery/format";
import { CWD } from "../../../gallery/fixtures/acpmux";
import { FOLIO_PACK, packLoaded, richChat } from "./FontPack.gallery";

export default agentPaneEntry({
  id: "agent-pane.font-pack-wide",
  title: "Font pack at a desktop column",
  area: "Agent pane",
  height: 1150,
  widths: { narrow: 900, normal: 900, wide: 900 },
  covers: ["agent-session/acpmux/chatFontFaces.ts", "agent-session/acpmux/chatDisplay.ts"],
  keywords: ["font", "font pack", "typography", "theme", "serif", "wide"],
  variants: {
    off: { note: "Font pack off at a desktop column.", snapshot: richChat, ready: { cwd: CWD }, display: {} },
    on: {
      note: "Font pack on at a desktop column: Folio Serif replies, Folio Mono code at 0.8.",
      snapshot: richChat,
      ready: { cwd: CWD },
      display: FOLIO_PACK,
      play: packLoaded,
    },
  },
});
