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

type Look = "shipped" | "bare" | "caret" | "split" | "condensed";
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

/// acpmux's condensed tools: a `description` argument says what the call is for, and the result's
/// first line (also `structuredContent.summary`) says how it came out, with `status` ok, failed or
/// running (Leo, 2026-11-03: "claude code desktop's summarization of tool calls/parsing of them seem
/// kinda good? we should bea bel to do that AND have condensed tools that are callable in
/// acpmux/cmux-next").
const condensed = (summary: string, status: "ok" | "failed" | "running", facts: Record<string, unknown>) =>
  JSON.stringify({
    content: [{ type: "text", text: `${summary}\n${JSON.stringify(facts)}` }],
    structuredContent: { summary, status, ...facts },
    isError: false,
  });
const condensedRows = [
  tool("mcp__acpmux__pr_state", "other", "completed", {
    inputSummary: JSON.stringify({ repo: "manaflow-ai/cmux", pr: 33316, description: "Check the pr_state PR" }),
    output: condensed("#33316 merged at 4c1e9a0", "ok", { state: "MERGED" }),
  }),
  tool("mcp__acpmux__bg_start", "other", "completed", {
    inputSummary: JSON.stringify({
      command: "rg -n cancelForced webviews/src",
      notify: true,
      description: "Find cancelForced references",
    }),
    output: condensed("Background command completed", "ok", { id: "bg-7", exitCode: 0 }),
  }),
  tool("mcp__acpmux__run_wait", "other", "completed", {
    inputSummary: JSON.stringify({ run: 19123456789, description: "Wait for the webview tests" }),
    output: condensed("web / react-apps-base-check failed: 2 tests", "failed", { conclusion: "failure" }),
  }),
];

function ShippedRows() {
  return (
    <>
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
    </>
  );
}

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
        {look === "condensed" ? (
          <>
            <p className="claude-code-tool-rows__prose">Checking the PR and the tests.</p>
            {condensedRows.map((row, index) => (
              <div key={row.tool!.id} className="acpmux-row">
                <McpCallRows items={[row]} disclosureKey={`gallery:condensed:${index}`} />
              </div>
            ))}
          </>
        ) : (
          <ShippedRows />
        )}
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
    "agent-session/acpmux/conversation/toolGroups.ts",
  ],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ClaudeCodeToolRows.gallery.css")]),
  load: async () => ClaudeCodeToolRows,
  keywords: [
    "claude",
    "tool",
    "using",
    "live",
    "tokens",
    "shimmer",
    "caret",
    "chevron",
    "condensed",
    "description",
    "summary",
  ],
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
    condensed: variant(
      "condensed",
      "dark",
      "acpmux's condensed tools: each call titled with its description, its one-line outcome muted after it, and a failed status in the failure red.",
    ),
    "condensed-light": variant("condensed", "light", "Condensed tools, light."),
  },
});
