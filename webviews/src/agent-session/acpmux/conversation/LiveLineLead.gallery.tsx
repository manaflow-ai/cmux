// l10n-allow-file: gallery fixture prose, tool names and commands, not shipped copy.
// The live line under a turn's folded work, three ways (liveLineLead.experiment.ts). Leo, 2026-11-03,
// on "Sent a message, finished 3 background tasks, ran 5 commands" with "Thinking · 1m 23s total ·
// 3.2K tokens" under it: the second line sat under the text, not on a clear column, and its icon
// column did not line up with the other rows. `mark` (chosen): a still glyph of what the line names
// in the rows' icon column, its words on their text column, so it is a row of its own; `slot`: the
// earlier empty slot (#33157), which reads as the run's second line; `flush`: no glyph, its words on
// the icon column. The shimmer stays the only working sign (design/chat-transcript.md). References:
// claude/live/transcript-tool-rows-and-task-list, claude/live/transcript-peer-session-message.
import { useEffect, useState } from "react";
import { componentEntry, type ComponentVariant } from "../../../gallery/format";
import { tool } from "../../../gallery/fixtures/acpmux";
import { Thinking } from "./Thinking";
import { ToolGroupRow } from "./ToolGroupRow";
import { ToolRow } from "./ToolRow";
import { TranscriptDisclosureProvider, resetTranscriptDisclosure } from "./transcriptDisclosure";
import { WorkingCountsContext, type WorkingCounts } from "./WorkingFor";

type Look = "mark" | "slot" | "flush";
type Line = "thinking" | "command" | "subagents";
type Props = { look: Look; line: Line; mode: "light" | "dark" };

const START = Date.UTC(2026, 10, 3, 6, 0, 0);
const now = () => START + 83_000;
const counts: WorkingCounts = {
  agents: 0,
  commands: 0,
  sessions: 0,
  openAgents: () => {},
  openCommands: () => {},
  openSessions: () => {},
  tokens: 3_200,
  split: { output: 3_200, input: 1_200, cacheRead: 412_000, cacheWrite: 9_000 },
};

const commands = [
  tool("git status", "execute", "completed", { command: "git status", output: "On branch live-line\n" }),
  tool("bun test transcript", "execute", "completed", { command: "bun test transcript" }),
  tool("bunx vp lint", "execute", "completed", { command: "bunx vp lint" }),
  tool("gh pr checks 2210", "execute", "completed", { command: "gh pr checks 2210" }),
  tool("git log --oneline -1", "execute", "completed", { command: "git log --oneline -1" }),
];
const read = tool("Read Thinking.tsx", "read", "completed", { locations: [{ path: "src/Thinking.tsx" }], output: "" });

function LiveLineLead({ look, line, mode }: Props) {
  // The arm for this stage only (its own frame).
  useState(() => {
    globalThis.cmuxExperiments = { "live-line-lead": look };
    return 0;
  });
  useEffect(() => resetTranscriptDisclosure("gallery-live-line-lead"), []);
  return (
    <TranscriptDisclosureProvider sessionId="gallery-live-line-lead">
      <main className="claude-code-tool-rows acpmux-conversation" data-mode={mode} data-look={look}>
        <p className="claude-code-tool-rows__prose">Checking the PR before I land it.</p>
        <div className="acpmux-row">
          <ToolGroupRow kind="commands" items={commands} disclosureKey="gallery:live-lead:commands" folded />
        </div>
        <div className="acpmux-row">
          <ToolRow item={read} />
        </div>
        <WorkingCountsContext.Provider value={counts}>
          <div className="acpmux-row acpmux-thinking">
            {line === "command" ? (
              <Thinking since={START} now={now} doing="bun test transcript" doingShell turnTotal below />
            ) : line === "subagents" ? (
              <Thinking since={START} now={now} liveState="subagents" liveAgents={2} turnTotal below />
            ) : (
              <Thinking since={START} now={now} thoughtMs={4_000} turnTotal below />
            )}
          </div>
        </WorkingCountsContext.Provider>
      </main>
    </TranscriptDisclosureProvider>
  );
}

const variant = (look: Look, line: Line, mode: Props["mode"], note: string): ComponentVariant<Props> => ({
  note: `${note} ${mode === "dark" ? "Dark" : "Light"} theme.`,
  props: { look, line, mode },
});

export default componentEntry<Props>({
  id: "agent-pane.live-line-lead",
  title: "The live line's lead: on the rows' icon column",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 420, normal: 640, wide: 900 },
  covers: [
    "agent-session/acpmux/conversation/Thinking.tsx",
    "agent-session/acpmux/conversation/liveLineLead.experiment.ts",
  ],
  styles: () =>
    Promise.all([import("../styles.css"), import("./conversation.css"), import("./ClaudeCodeToolRows.gallery.css")]),
  load: async () => LiveLineLead,
  keywords: ["live", "thinking", "indent", "icon", "column", "total", "tokens", "shimmer"],
  variants: {
    mark: variant(
      "mark",
      "thinking",
      "dark",
      "Chosen: a still clock in the rows' icon column, \"Thinking 4s · 1m 23s total · 3.2K tokens\" on their text column.",
    ),
    "mark-light": variant("mark", "thinking", "light", "Chosen, light."),
    "mark-command": variant("mark", "command", "dark", "Chosen, a command in flight: the terminal glyph."),
    "mark-subagents": variant("mark", "subagents", "dark", "Chosen, waiting on subagents: the bot glyph."),
    slot: variant("slot", "thinking", "dark", "Before (#33157): an empty slot; the line reads as the run's second line."),
    flush: variant("flush", "thinking", "dark", "No glyph, the words on the icon column, as a reply's text starts."),
  },
});
