// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { CloudChatHint } from "./CloudChatHint";

type Props = Parameters<typeof CloudChatHint>[0];

const onUse = () => undefined;
const onClose = () => undefined;

/// The X folds the row away on the house settle; the stage ends with the row gone.
const close: Play = async (ctx) => {
  await ctx.click({ selector: '[data-testid="cloud-hint-close"]' });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-cloud-hint-fold[data-leaving="true"]'));
};

export default componentEntry<Props>({
  id: "agent-pane.cloud-chat-hint",
  title: "Cloud hint over a new chat's composer",
  area: "Agent pane",
  covers: ["agent-session/acpmux/CloudChatHint.tsx#CloudChatHint"],
  pane: true,
  load: () => import("./CloudChatHint").then((module) => module.CloudChatHint),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 120,
  variants: {
    line: {
      note: "Shipped. One quiet row on a flat tonal fill: the cloud mark, what Cloud gives in one sentence, Use Cloud and an X. It reads as part of the new chat's flow, sits over the strip and never over the box, and costs one 32 px row that folds away on a pick or the X.",
      props: { look: "line", onUse, onClose },
    },
    card: {
      note: "Rejected: a title over the sentence on a taller block. It explains a little more but costs twice the height on every new chat until it is answered, which pushes the composer further down the New Tab page.",
      props: { look: "card", onUse, onClose },
    },
    chip: {
      note: 'Rejected: one small block, Try Cloud and an X. It is the quietest, but it never says what Cloud is, which is the question (Leo, 2026-11-08: "how would they know?").',
      props: { look: "chip", onUse, onClose },
    },
    "line-closing": {
      note: "The X: the row folds to zero height with a fade on the house settle (cubic-bezier(0.16, 1, 0.3, 1), 265 ms), and the composer moves up with it in the same transition.",
      props: { look: "line", onUse, onClose },
      play: close,
    },
  },
});
