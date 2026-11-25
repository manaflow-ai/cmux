// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// The chat's structure a look reshapes (chatLayout.ts; the agentPane.display.layout.* settings), each
// arm on one finished coding turn, and the three whole-look combinations: a dense code-first agent
// app (flat rows, square box), a warm chat assistant app (cards, quiet header) and a minimal chat
// assistant app (bubbles, pill box, quiet header). Test: test/chat-layout.test.tsx.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "./model";

const rows = (): AcpmuxRow[] => [
  user("Why does the sidebar jump when a chat finishes? Fix it and add a test.", 12),
  activity(
    [
      tool("rg -n 'settleFinished' Sources", "execute", "completed", {
        description: "Searched for the settle rule",
        command: "rg -n 'settleFinished' Sources",
        output: "SidebarSections/Settle.swift:42\n",
        exitCode: 0,
      }),
      tool("swift test --filter SettleTests", "execute", "completed", {
        description: "Ran the settle tests",
        command: "swift test --filter SettleTests",
        output: "ok\n",
        exitCode: 0,
      }),
    ],
    11,
  ),
  assistant(
    "The finished chat folded behind **Settled** before its row's height animation ended, so the rows under it moved twice. It now folds after the animation, and `SettleTests` covers the order.",
    9,
  ),
  summary(8.9, { status: "completed", durationMs: 96_000, toolCount: 2 }),
  user("Great. Can the folded row keep its unread dot?", 5),
  assistant("Yes: the dot now stays on the Settled row until you open the chat.", 4),
];

const layout = (messages: string, composer: string, header: string) => ({
  "agentPane.display.layout.messages": messages,
  "agentPane.display.layout.composer": composer,
  "agentPane.display.layout.header": header,
});

const variant = (note: string, display: Record<string, unknown>): AgentPaneVariant => ({
  note,
  display,
  snapshot: chat(rows(), { title: "Sidebar settle" }),
});

export default agentPaneEntry({
  id: "agent-pane.chat-layout",
  title: "Chat layout a look sets",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 520, normal: 760, wide: 1000 },
  covers: ["agent-session/acpmux/chatLayout.ts#configureChatLayout"],
  variants: {
    default: variant("Nothing set: bubbles, rounded box, full header (today)", {}),
    flat: variant("Message Layout: Flat Rows", layout("flat", "rounded", "full")),
    card: variant("Message Layout: Cards", layout("card", "rounded", "full")),
    pill: variant("Message Box Shape: Pill", layout("bubbles", "pill", "full")),
    square: variant("Message Box Shape: Square", layout("bubbles", "square", "full")),
    quiet: variant("Chat Header: Quiet", layout("bubbles", "rounded", "quiet")),
    "dense-code": variant("A dense code-first agent app: flat rows, square box", layout("flat", "square", "full")),
    "warm-chat": variant("A warm chat assistant app: cards, quiet header", layout("card", "rounded", "quiet")),
    "minimal-chat": variant(
      "A minimal chat assistant app: bubbles, pill box, quiet header",
      layout("bubbles", "pill", "quiet"),
    ),
  },
});
