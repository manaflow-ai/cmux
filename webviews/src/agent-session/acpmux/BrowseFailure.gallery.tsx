// l10n-allow-file: gallery fixtures use a sample host error.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { BrowseFailure } from "./BrowseFailure";

const base = {
  onRetry: () => undefined,
  onDismiss: () => undefined,
};

const retry: Play = async (ctx) => {
  await ctx.click({ text: "Retry" });
};

export default componentEntry({
  id: "agent-pane.browse-failure",
  title: "Folder browse failure",
  area: "Agent pane",
  covers: ["agent-session/acpmux/BrowseFailure.tsx#BrowseFailure"],
  load: () => Promise.resolve(BrowseFailure),
  styles: () => import("./styles.css"),
  widths: { narrow: 360, normal: 520, wide: 720 },
  height: 56,
  anchors: [{ selector: ".acpmux-folder-choice" }],
  variants: {
    refused: {
      note: "A host refusal stays beside Retry and Dismiss, so the selected start surface remains usable.",
      props: { ...base, error: "The folder chooser is unavailable." },
    },
    "long-reason": {
      note: "A longer host reason wraps inside the existing notice without hiding either action.",
      props: {
        ...base,
        error: "The folder chooser could not reach this Mac while its access service was restarting.",
      },
    },
    retry: {
      note: "Retry is a direct action on the failed browse state.",
      props: { ...base, error: "Folder access was denied." },
      play: retry,
    },
  },
});
