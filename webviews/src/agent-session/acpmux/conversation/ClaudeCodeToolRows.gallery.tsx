// l10n-allow-file: gallery fixture prose, tool names and commands, not shipped copy.
// Tool rows and the live line beside Claude Code desktop's (Leo, 2026-11-03: "i feel like
// comparing claude code's to ours, we're not faithfully following how they're doing stuff" / "wrt
// tool calls and the lowest level thinking"). A finished call is one muted line, verb then tool
// ("Used repo: repo grep", "Ran 3 commands", "Read App.tsx"), its chevron right after the words; the
// live line names the current action in full ink, the rest muted, then the turn's time and its
// tokens ("Using repo: repo grep 3m 2s · 47.4K tokens"). Its only working mark is the shimmer
// ("we don't want the claude symbol ellipsis thing btw we just keep the shimmer ONLY"), so Claude's
// orange dots have no variant. References: claude/live/transcript-tool-rows-and-task-list,
// claude/live/transcript-peer-session-message.
import { useEffect, useState } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { McpCallRows } from "./McpCallRows";
import { Thinking } from "./Thinking";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRow } from "./ToolRow";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";
import { WorkingCountsContext, type WorkingCounts } from "./WorkingFor";

type Look = "shipped" | "bare" | "caret" | "split";
type Props = { look: Look; mode: "light" | "dark" };

const START = Date.UTC(2026, 10, 3, 6, 0, 0);
const now = () => START + 182_000;
const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 47_400,
  split: { output: 47_400, input: 9_000, cacheRead: 2_650_000, cacheWrite: 41_000 },
};

const rows = {
  grep: tool("mcp__repo__repo_grep", "other", "completed", {
    inputSummary: JSON.stringify({ pattern: "cv-tool__icon" }),
    output: "conversation.css:2415\nToolRow.tsx:142",
  }),
  commands: [
    tool("git status", "execute", "completed", { command: "git status", output: "On branch tool-rows\n" }),
    tool("bun test transcript", "execute", "completed", { command: "bun test transcript" }),
    tool("bunx vp lint", "execute", "completed", { command: "bunx vp lint" }),
  ],
  read: tool("Read App.tsx", "read", "completed", { locations: [{ path: "src/App.tsx" }], output: "export {}" }),
};

function ClaudeCodeToolRows({ look, mode }: Props) {
  // The split arm of `live-line-tokens`, for this stage only (its own frame).
  useState(() => {
    globalThis.cmuxExperiments = look === "split" ? { "live-line-tokens": "split" } : {};
    return 0;
  });
  useEffect(() => resetTranscriptDisclosure("gallery-claude-code-tool-rows"), []);
  return (
    <TranscriptDisclosureProvider sessionId="gallery-claude-code-tool-rows">
      <main className="claude-code-tool-rows acpmux-conversation" data-mode={mode} data-look={look}>
        <p className="claude-code-tool-rows__prose">Found the row grammar in the transcript styles.</p>
        <div className="acpmux-row">
          <McpCallRows items={[rows.grep]} disclosureKey="gallery:grep" />
        </div>
        <div className="acpmux-row">
          <ToolGroupRow kind="commands" items={rows.commands} disclosureKey="gallery:commands" folded />
        </div>
        <div className="acpmux-row">
          <ToolRow item={rows.read} />
        </div>
        <p className="claude-code-tool-rows__prose">Checking the other call sites.</p>
        <WorkingCountsContext.Provider value={counts}>
          <div className="acpmux-row acpmux-thinking">
            <Thinking since={START} now={now} doing="Using repo: repo grep" below />
          </div>
        </WorkingCountsContext.Provider>
      </main>
    </TranscriptDisclosureProvider>
  );
}

const variant = (look: Look, mode: Props["mode"], note: string): ComponentVariant<Props> => ({
  note: `${note} ${mode === "dark" ? "Dark" : "Light"} theme.`,
  props: { look, mode },
});

export default componentEntry<Props>({
  id: "agent-pane.claude-code-tool-rows",
  title: "Tool rows and the live line, as Claude Code draws them",
  area: "Agent pane",
  pane: true,
  height: 260,
  widths: { narrow: 420, normal: 640, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/Thinking.tsx",
    "agent-session/acpmux/conversation/McpCallRows.tsx",
    "agent-session/acpmux/conversation/mcpCalls.ts",
  ],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ClaudeCodeToolRows.gallery.css")]),
  load: async () => ClaudeCodeToolRows,
  keywords: ["claude", "tool", "using", "live", "tokens", "shimmer", "caret", "chevron"],
  variants: {
    shipped: variant(
      "shipped",
      "dark",
      "Chosen: Claude Code's words and one-count tokens; our icon column and down chevron stay (design/chat-transcript.md).",
    ),
    "shipped-light": variant("shipped", "light", "Chosen, light."),
    bare: variant("bare", "dark", "No icons, as Claude Code: words start on the prose edge; breaks the icon column."),
    caret: variant("caret", "dark", "Claude Code's right-pointing caret instead of our down chevron."),
    split: variant("split", "dark", "The earlier tokens, output and input apart, on the live line."),
  },
});
