// l10n-allow-file: gallery fixtures (sample prompts and queued messages), not shipped UI.
// A harness's local commands typed alone run at once, mid-turn too, and a new chat starts with
// Session Info closed (Leo, 2026-11-10: "session info should NOT open by defualt on starting new
// chat / and typing /mcp or /status on its own should NOT queue/steer and wait behind... at least for
// these types of nonsending type messages, they should just... go there. and run. instead of being
// treated like normal messages"). localCommands.ts holds the per-harness set; cmux's own /status
// runs at once the same way. test/composer-local-commands.test.tsx checks the send paths.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, CWD, noChat, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";

const rows = [
  user("Add retries to the fetch helper, with a backoff.", 4),
  assistant("Reading `fetchJson` and its callers first.", 3),
];

const COMMANDS = [
  { name: "mcp", description: "Manage MCP servers" },
  { name: "cost", description: "Show the total cost and duration of the current session" },
  { name: "compact", description: "Clear conversation history but keep a summary in context" },
];

/// A turn running, with one prompt the person queued behind it.
function running(queue: AcpmuxSnapshot["queue"] = [{ id: "q-1", prompt: "Then run the fetch tests." }]) {
  const base = chat(rows, { isWorking: true, queue, commands: COMMANDS });
  return { ...base, summary: { ...base.summary!, steering: true } };
}

/// A new chat before its first send: its session started (prewarmed), nothing opened.
const newChat = noChat([], {
  sessionId: "new-chat",
  summary: { sessionId: "new-chat", cwd: CWD, harness: "claude", turnCount: 0, host: "This Mac", hostKind: "local" },
});

/// Session Info on, as the App's header state has it by default (AgentPaneTunables `agent.sessionInfo`).
const native = { "pane.tabState": { inspector: true } };

/// Types `command` alone and sends it with Return, as the person does mid-turn, then waits for what
/// it shows (`shows`): the play fails when it never comes.
const runs = (command: string, shows: string) => async (ctx: PlayContext) => {
  await ctx.click({ selector: "[role=combobox]" });
  await ctx.type(command);
  // The `/` menu is open over the typed word; Esc closes it so Return sends what is typed.
  await ctx.press("Escape");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(shows));
};

export default agentPaneEntry({
  id: "agent-pane.local-commands",
  title: "Local commands and a new chat's Session Info",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/localCommands.ts",
    "agent-session/acpmux/Composer.tsx",
    "agent-session/acpmux/session-info/sessionInfoState.ts",
  ],
  variants: {
    "new-chat-info-closed": {
      note: "A new chat: Session Info is closed; only its header toggle opens it.",
      snapshot: newChat,
      native,
    },
    "status-mid-turn": {
      note: "/status typed alone while a turn runs: the status card shows at once; nothing joins the queue.",
      snapshot: running(),
      native,
      play: runs("/status", ".acpmux-harness-status"),
    },
    "mcp-mid-turn": {
      note: "/mcp typed alone while a turn runs: Session Info opens on Connectors at once; the queue keeps only what the person queued.",
      snapshot: running(),
      native,
      play: runs("/mcp", ".acpmux-session-info[data-presence=shown]"),
    },
    "queue-beside": {
      note: "The queue next to it: a turn running with one queued prompt, before any command. A normal prompt sent now still waits here.",
      snapshot: running([
        { id: "q-1", prompt: "Then run the fetch tests." },
        { id: "q-2", prompt: "And open a PR when they pass." },
      ]),
      native,
    },
  },
});
