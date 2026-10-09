// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { MissingFolder } from "./missingFolder";

type Props = Parameters<typeof MissingFolder>[0];

const onChoose = () => undefined;

export default componentEntry<Props>({
  id: "agent-pane.missing-folder",
  title: "Missing chat folder",
  area: "Agent pane",
  height: 120,
  widths: { narrow: 320, normal: 560, wide: 760 },
  anchors: [{ selector: ".acpmux-folder-choice-button" }],
  covers: ["agent-session/acpmux/missingFolder.tsx#MissingFolder"],
  pane: true,
  load: () => import("./missingFolder").then((module) => module.MissingFolder),
  variants: {
    "recorded-folder-missing": {
      note: "A resumed chat explains that its recorded folder is gone and offers one clear recovery action.",
      props: { reason: "The recorded folder no longer exists.", onChoose },
    },
    "choose-failed": {
      note: "The folder picker returned an error; the recovery action remains available for another attempt.",
      props: {
        reason: "Choose a folder to resume this chat.",
        error: "The selected folder could not be opened.",
        onChoose,
      },
    },
  },
});
