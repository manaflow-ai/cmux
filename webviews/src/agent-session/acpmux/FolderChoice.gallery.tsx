// l10n-allow-file: gallery fixture error text, not shipped UI.
//
// FolderChoice is the one-click bridge from a folderless new chat to the native folder chooser.
// Keep the receipt around the actual button so the offered, failed and keyboard paths remain
// visible without mounting the full agent pane.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { FolderChoice } from "./FolderChoice";

type Props = ComponentProps<typeof FolderChoice>;

function GalleryFolderChoice(props: Props) {
  const [chosen, setChosen] = useState(false);
  return (
    <div className="folder-choice-gallery" data-folder-choice={chosen ? "chosen" : ""}>
      <FolderChoice
        {...props}
        onChoose={() => {
          props.onChoose();
          setChosen(true);
        }}
      />
    </div>
  );
}

const choose: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-folder-choice-button" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-folder-choice="chosen"]') !== null);
};

const keyboard: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-folder-choice-button" });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector('[data-folder-choice="chosen"]') !== null);
};

const props: Props = { onChoose: () => undefined };

export default componentEntry<Props>({
  id: "agent-pane.folder-choice",
  title: "Folder choice notice",
  area: "Agent pane",
  pane: true,
  height: 120,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: ".acpmux-folder-choice" }],
  covers: ["agent-session/acpmux/FolderChoice.tsx#FolderChoice"],
  styles: () => import("./styles.css"),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Choosing a folder is a local button action and must leave the notice anchored above the composer.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The native folder handoff records a receipt without changing the notice's layout.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Folder choice feedback is a direct local button interaction.",
    },
    settleMaxMs: {
      value: 250,
      reason: "The notice must acknowledge the native folder request within a quarter second.",
    },
  },
  load: async () => GalleryFolderChoice,
  variants: {
    offered: {
      note: "A folderless new chat explains its private agent-home and offers the native Choose Folder action.",
      props,
      play: choose,
    },
    keyboard: {
      note: "The underlined folder action is reachable by focus and Enter, matching the mouse path.",
      props,
      play: keyboard,
    },
    error: {
      note: "A native folder refusal stays inline as an alert while Choose Folder remains available for retry.",
      props: { ...props, error: "The folder service is unavailable." },
    },
  },
});
