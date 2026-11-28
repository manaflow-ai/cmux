// l10n-allow-file: gallery fixtures (sample chats and reasons), not shipped UI.
// A chat whose folder is missing (missingFolder.tsx, cx-nn3e.1): Open Chat opened it in its pane;
// one line above the composer says why it has no folder and offers Choose Folder.
import { agentPaneEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";

export default agentPaneEntry({
  id: "agent-pane.missing-folder",
  title: "Missing chat folder",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/missingFolder.tsx#MissingFolder"],
  variants: {
    deleted: {
      note: "The chat's folder was deleted or moved: the line names acpmux's reason and offers Choose Folder.",
      ready: {
        newSession: true,
        folderNeeded: { reason: "the chat's folder /Users/you/src/old-app was deleted or moved; pick one" },
      },
      snapshot: noChat([]),
    },
    "no-folder": {
      note: "The chat recorded no folder at all.",
      ready: { newSession: true, folderNeeded: { reason: "the chat recorded no folder; pick one" } },
      snapshot: noChat([]),
    },
  },
});
