// l10n-allow-file: gallery fixtures (sample chats and reasons), not shipped UI.
// A chat that cannot resume here yet (PastChat.tsx, cx-khns1): Open Chat opened a fresh chat for
// it, and its past turns show read-only where the new chat's hero would be.
import { agentPaneEntry } from "../../gallery/format";
import { noChat } from "../../gallery/fixtures/acpmux";

const pastTurns = [
  {
    prompt: "The build fails after the merge. Can you fix it?",
    answer: "Fixed: `ChatList.swift` lost an import in the merge. The build passes again.",
  },
  {
    prompt: "Add a test so it can't regress",
    answer:
      "Added `chatListBuilds()`, which compiles the list with its imports.\n\n- Fails before the fix\n- Passes after",
  },
];

export default agentPaneEntry({
  id: "agent-pane.past-chat",
  title: "Past chat before it resumes",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/PastChat.tsx#PastChat"],
  variants: {
    "folder-gone": {
      note: "The chat's folder was deleted: its past shows read-only, with the Choose Folder line above the composer.",
      ready: {
        newSession: true,
        folderNeeded: { reason: "the chat's folder /Users/you/src/old-app was deleted or moved; pick one" },
        pastTurns,
      },
      snapshot: noChat([]),
    },
    "new-chat": {
      note: "A chat acpmux cannot resume over ACP: a fresh chat on its agent, its past shown read-only above the composer.",
      ready: { newSession: true, cwd: "/Users/you/src/cmux", pastTurns },
      snapshot: noChat([]),
    },
  },
});
