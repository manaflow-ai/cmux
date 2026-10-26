// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { AvatarSetSheet, type AvatarSetSheetProps } from "./AvatarSetSheet";

const set = (id: string, note: string) => ({ note, props: { ids: [id] } satisfies AvatarSetSheetProps });

export default componentEntry({
  id: "agent-pane.animated-avatars",
  title: "Animated avatars",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 420, normal: 560, wide: 900 },
  covers: [
    "agent-session/acpmux/avatars/AnimatedAvatar.tsx#AnimatedAvatar",
    "agent-session/acpmux/avatars/AvatarSetSheet.tsx#AvatarSetSheet",
  ],
  load: async () => AvatarSetSheet,
  variants: {
    pick: {
      note: "The four sets side by side: the static frame, working (moving) and waiting facing left. Mochi is the pick.",
      props: { view: "pick", size: 64 },
    },
    mochi: set("mochi", "Mochi (Codex session 3): every state facing right and left, then the row's frames."),
    captain: set("captain", "Captain (drawn in this lane): every state facing right and left, then the row's frames."),
    sprout: set("sprout", "Sprout (Codex session 1): every state facing right and left, then the row's frames."),
    bolt: set("bolt", "Bolt (Codex session 2): every state facing right and left, then the row's frames."),
  },
});
