// l10n-allow-file: gallery fixtures (sample commands), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { LiveChatChoice } from "./LiveChatChoice";

type Props = Parameters<typeof LiveChatChoice>[0];

const onChoose = () => undefined;

export default componentEntry<Props>({
  id: "agent-pane.live-chat-choice",
  title: "Chat open elsewhere",
  area: "Agent pane",
  height: 160,
  covers: ["agent-session/acpmux/LiveChatChoice.tsx#LiveChatChoice"],
  pane: true,
  load: () => import("./LiveChatChoice").then((module) => module.LiveChatChoice),
  variants: {
    "claude-in-terminal": {
      props: { canFork: true, command: "claude --resume 3f2b9c1e-6d4a-4f7e-9b2a-8c1d5e0f7a64", onChoose },
      note: "Claude Code: Fork It starts a new chat from this one",
    },
    "process-unknown": { props: { canFork: true, onChoose } },
    "no-fork": {
      props: { canFork: false, command: "codex resume 01a116b7-6cc2-7ed0-979c-a57960351fb9", onChoose },
      note: "Harnesses without fork offer Open Anyway only",
    },
  },
});
