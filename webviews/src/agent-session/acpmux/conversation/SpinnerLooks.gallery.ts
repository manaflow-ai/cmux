// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent working-state mark's looks, in light and dark at 12, 14 and 16 px: (a) ChatGPT's ring
// with one gap, a 0.72 arc over a faint track at stroke 2, one turn per 1.4 s (shipped, native and
// web; Leo 2026-11-02, on ChatGPT's beside ours: "THIS IS CHATGPT", "IT GOES SLOWER", "DO IT
// F***ING SLOWER"). Its runners-up: (b) the half arc of ChatGPT's spinner in OpenAI's Work video
// (references chatgpt/web/composer-work-running-spinner-stop), (c) an open ring with no track,
// (d) a thinner stroke, (e) a faster turn. For reference: #31455's faint ring with an 80° sweep
// that this replaces, the loading arc, and the macOS spokes (Leo 2026-11-01: "why the f*** did you
// make the spinner into this????"). (a) is the closest to the ChatGPT spinner Leo pasted: its
// bright arc covers 0.72 of the ring and the gap keeps a faint track.
import { componentEntry } from "../../../gallery/format";
import type { SpinnerLooksBoardProps } from "./SpinnerLooksBoard";

export default componentEntry<SpinnerLooksBoardProps>({
  id: "agent-pane.working-spinner",
  title: "Working spinner: looks",
  area: "Agent pane",
  height: 360,
  covers: [
    "agent-session/acpmux/conversation/icons.tsx#Spinner",
    "agent-session/acpmux/conversation/SpinnerLooksBoard.tsx",
  ],
  keywords: ["spinner", "working", "ring", "gap", "chatgpt", "sweep", "arc", "spokes"],
  styles: () => import("./spinner.css"),
  load: () => import("./SpinnerLooksBoard").then((module) => module.SpinnerLooksBoard),
  variants: {
    compare: {
      note: "Every look side by side; (a) the gap ring ships.",
      props: {
        looks: [
          "gap-ring",
          "gap-ring-half",
          "gap-ring-open",
          "gap-ring-thin",
          "gap-ring-faster",
          "ring-sweep",
          "arc",
          "spokes",
        ],
      },
    },
    "gap-ring": {
      note: "Shipped: ChatGPT's ring with one gap, a 0.72 arc over a 22% track, stroke 2, round caps, one turn per 1.4 s on the shared clock.",
      props: { looks: ["gap-ring"] },
    },
    "runners-up": {
      note: "The video's half arc, the open ring (no track), the thinner stroke and the faster turn.",
      props: { looks: ["gap-ring-half", "gap-ring-open", "gap-ring-thin", "gap-ring-faster"] },
    },
    replaced: {
      note: "For reference only: #31455's 80° sweep this replaces, the loading arc and the macOS spokes.",
      props: { looks: ["ring-sweep", "arc", "spokes"] },
    },
  },
});
