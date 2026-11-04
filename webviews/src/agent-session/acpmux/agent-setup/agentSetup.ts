// The Agent setup viewer's data (Leo, 2026-11-04: "giving the users a better way to, like, see
// what's actually happening ... as a viewer ... some people just want to edit it a bit"). acpmux
// answers `_acpmux/agent_setup {sessionId}` (cmux-tui/crates/acpmux/src/server/requests/agent_setup.rs)
// with what a chat's agent is told beside the person's messages; `_acpmux/agent_setup/save` sets
// the chat's preset's system prompt and answers the same shape.
//
// The viewer opens as its own tab right of the chat: `chat.setupPane {sessionId}` asks the app for
// a tab on the chat's own session, which opens on the `agent-setup` reveal (App.tsx `reveal`), the
// way `chat.subagentPane` opens a subagent's on `subagent:<id>`. A host that opens none (the
// gallery, Quick Chat, an older app) shows the viewer in the chat's own pane.

/// The `revealTurn` value that opens a pane on the chat's Agent setup viewer.
export const AGENT_SETUP_REVEAL = "agent-setup";

export type AgentSetupTool = { name: string; description: string };
export type AgentSetupServer = { name: string; instructions?: string; tools: AgentSetupTool[] };
export type AgentSetupPreset = {
  name: string;
  hasSystemPrompt: boolean;
  /// The prompt's text; acpmux sends it only to this Mac's app (the connection that may save it).
  systemPrompt?: string;
  /// The chat's harness takes a preset system prompt (Claude Code's `--system-prompt-file`).
  takesSystemPrompt: boolean;
  /// This connection may save it.
  editable: boolean;
};
export type AgentSetup = {
  harness: string;
  family: string;
  harnessPrompt: { source: string; note: string; link?: string };
  servers: AgentSetupServer[];
  /// None for a chat started without a preset.
  preset?: AgentSetupPreset;
};

const text = (value: unknown) => (typeof value === "string" ? value : "");
const record = (value: unknown): Record<string, unknown> | undefined =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const list = (value: unknown): Record<string, unknown>[] =>
  Array.isArray(value)
    ? (value as unknown[]).map(record).filter((item): item is Record<string, unknown> => item !== undefined)
    : [];

/// acpmux's answer, or undefined when it is not one.
export function parseAgentSetup(value: unknown): AgentSetup | undefined {
  const source = record(value);
  const prompt = record(source?.harnessPrompt);
  if (!source || !prompt) return undefined;
  const link = text(prompt.link);
  const preset = record(source.preset);
  const systemPrompt = typeof preset?.systemPrompt === "string" ? preset.systemPrompt : undefined;
  return {
    harness: text(source.harness),
    family: text(source.family),
    harnessPrompt: { source: text(prompt.source), note: text(prompt.note), ...(link ? { link } : {}) },
    servers: list(source.servers)
      .map((server) => {
        const instructions = text(server.instructions);
        return {
          name: text(server.name),
          ...(instructions ? { instructions } : {}),
          tools: list(server.tools)
            .map((tool) => ({ name: text(tool.name), description: text(tool.description) }))
            .filter((tool) => tool.name),
        };
      })
      .filter((server) => server.name),
    ...(preset && text(preset.name)
      ? {
          preset: {
            name: text(preset.name),
            hasSystemPrompt: preset.hasSystemPrompt === true,
            ...(systemPrompt !== undefined ? { systemPrompt } : {}),
            takesSystemPrompt: preset.takesSystemPrompt === true,
            editable: preset.editable === true,
          },
        }
      : {}),
  };
}

/// What Save sends for the editor's text: null (remove the prompt) when it is only whitespace.
export const savedPrompt = (draft: string): string | null => (draft.trim() ? draft : null);

/// The editor's text once a save of `submitted` succeeds. Edits made while it was pending stay (and
/// so stay unsaved); otherwise the editor shows what acpmux now holds: `stored`, the reply's prompt,
/// or, with no readable reply, what was sent (a whitespace-only prompt reads as the empty one).
export function draftAfterSave(submitted: string, current: string, stored: string | undefined): string {
  if (current !== submitted) return current;
  return stored ?? savedPrompt(submitted) ?? "";
}

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Asks the app to open (or focus) chat `sessionId`'s Agent setup tab right of the chat; false when
/// the host opened none (it does not know `chat.setupPane`, or answered without `opened`).
export async function openAgentSetupPane(call: Call, sessionId: string): Promise<boolean> {
  try {
    const reply = await call("chat.setupPane", { sessionId });
    return (reply as { opened?: unknown } | null)?.opened === true;
  } catch {
    return false;
  }
}
