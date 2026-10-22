// The chat-index key of an acpmux session (`<index harness>:<harness session id>`, e.g.
// `claude-code:01a1…`): the pane hands it to the app (`chat.resumeKey`) for each chat it shows, so
// when that chat is later gone from acpmux ("This chat isn't available"), Resume from Transcript
// opens that exact chat from its harness transcript (`chats.open`), in one step.

/// The chat index's harness id for an acpmux harness family (cmux-tui chat-index).
const INDEX_HARNESS: Record<string, string> = {
  claude: "claude-code",
  codex: "codex",
  opencode: "opencode",
  gemini: "gemini",
  pi: "pi",
  cursor: "cursor-agent",
};

/// The chat-index key of a session whose harness family is `family` and whose harness session
/// id is `agentSessionId`; undefined for a harness the index does not read, or no id.
export function chatIndexKey(family: unknown, agentSessionId: unknown): string | undefined {
  if (typeof family !== "string" || typeof agentSessionId !== "string") return undefined;
  const harness = INDEX_HARNESS[family];
  if (!harness || !agentSessionId || agentSessionId.includes("/")) return undefined;
  return `${harness}:${agentSessionId}`;
}
