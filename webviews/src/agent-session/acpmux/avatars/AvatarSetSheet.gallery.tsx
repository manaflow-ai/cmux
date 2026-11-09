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
    look: {
      note: "Thinking, looking left, right, up and down: the shipped face turn (eyes, mouth and cheeks slide 1 px), the eyes alone, and the face turn opening on a blink. Shipped: the face turn, which reads as the head turning at pet size; the eyes alone get lost in Captain's and Sprout's faces, and a blink each time the look changes reads as sleepy.",
      props: { view: "variants", motion: "look", variants: ["look-eyes", "look-blink"], size: 64 },
    },
    drag: {
      note: "Dragged left, right, up and down: the shipped shear (the top leads by 3 px, the feet stay), the body offset in two steps, and a squash and stretch. Shipped: the shear, a smooth lean with the feet trailing; the offset breaks the body at the waist, and the squash resamples the outline unevenly.",
      props: { view: "variants", motion: "drag", variants: ["drag-offset", "drag-squash"], size: 64 },
    },
  },
});
