// l10n-allow-file: gallery design fixtures for the settle moment, not shipped UI.
// What the person sees when a chat settles because its pull request merged (opt-in, acpmux
// hub/auto_settle.rs): today's look and three designs for Leo's pick (SettleMomentDesigns.tsx).
import { componentEntry } from "../../gallery/format";
import type { SettleMomentDesignsProps } from "./SettleMomentDesigns";

export default componentEntry<SettleMomentDesignsProps>({
  id: "agent-pane.settle-moment",
  title: "Settle on merge: the moment (designs)",
  area: "Agent pane",
  pane: true,
  height: 320,
  widths: { narrow: 640, normal: 760, wide: 960 },
  covers: ["agent-session/acpmux/SettleMomentDesigns.tsx"],
  keywords: ["settle", "settled", "merged", "archive", "undo", "toast", "sidebar"],
  load: () => import("./SettleMomentDesigns").then((module) => module.SettleMomentDesigns),
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./bottomStack.css"),
      import("../../ui/ui.css"),
      import("./ToastLayer.gallery.css"),
    ]),
  variants: {
    now: {
      props: { design: "now" },
      note: "Today: the pull request merged and the row only shows the merged glyph; the chat stays on the list.",
    },
    toast: {
      props: { design: "toast" },
      note: "(a) The row leaves the list; a toast at the chat's foot names the chat and the pull request, with Undo.",
    },
    fade: {
      props: { design: "fade" },
      note: "(b) The row fades down into a Settled group at the list's foot, dimmed; no toast.",
    },
    chip: {
      props: { design: "chip" },
      note: "(c) The row stays where it was, dimmed, with an inline merged, settled chip and Undo; it leaves on the next visit.",
    },
  },
});
