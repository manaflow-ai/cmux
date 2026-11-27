// l10n-allow-file: gallery fixtures (sample prompts, paths and file text), not shipped UI.
// A Write's transcript row (WriteLabel.tsx) in each state: named before its input ("Writing a
// file"), running with its file ("Writing gen.py"), done ("Wrote gen.py +6", the name opening the
// file), failed ("Writing notes.md failed"), and with no text to count ("Wrote plan.md").
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const GEN = "/Users/you/src/fleetviz/gen.py";
const genText = [
  "import json, sys, urllib.request",
  "",
  'URL = "http://fleet.example.test/v1/status"',
  "",
  "def main():",
  "    print(json.load(urllib.request.urlopen(URL)))",
].join("\n");
const created = { path: GEN, newText: `${genText}\n` };
const fragment = { ...created, fragment: true as const };
const input = JSON.stringify({ file_path: GEN, content: `${genText}\n` });

const variants: Record<string, AgentPaneVariant> = {
  done: {
    note: "Finished Writes: Wrote gen.py +6 (its name opens the file), a failed one, one with no text to count, and an Edit beside them for comparison.",
    snapshot: chat([
      user("Write a generator for the fleet status page", 6),
      activity([tool("Write gen.py", "edit", "completed", { inputSummary: input, diffs: [created] })], 5.9),
      assistant("Wrote the generator. Now the notes.", 5.8),
      activity(
        [
          tool("Write notes.md", "edit", "failed", {
            inputSummary: JSON.stringify({ file_path: "/Users/you/src/fleetviz/notes.md", content: "# Notes\n" }),
          }),
        ],
        5.7,
      ),
      assistant("That failed; writing the plan instead.", 5.6),
      activity(
        [
          tool("Write plan.md", "edit", "completed", {
            inputSummary: JSON.stringify({ file_path: "/Users/you/src/fleetviz/plan.md" }),
          }),
        ],
        5.5,
      ),
      assistant("And one edit to the README.", 5.4),
      activity(
        [
          tool("Edit README.md", "edit", "completed", {
            diffs: [
              {
                path: "/Users/you/src/fleetviz/README.md",
                oldText: "# fleetviz\n",
                newText: "# fleetviz\n\nRun gen.py.\n",
              },
            ],
          }),
        ],
        5.3,
      ),
      assistant("Done.", 5.2),
      summary(5.2, { status: "completed", toolCount: 4 }),
    ]),
  },
  "named-before-input": {
    note: "Claude Code names a Write as its block starts, before any input: Writing a file, never the bare Write.",
    snapshot: chat([
      user("Write a generator for the fleet status page", 1),
      activity([tool("Write", "edit", "pending")], 0.5),
    ]),
  },
  running: {
    note: "A Write whose text has come, still running: Writing gen.py.",
    snapshot: chat([
      user("Write a generator for the fleet status page", 1),
      activity([tool("Write gen.py", "edit", "in_progress", { inputSummary: input, diffs: [fragment] })], 0.5),
    ]),
  },
};

export default agentPaneEntry({
  id: "agent-pane.write-rows",
  title: "Write tool rows",
  area: "Agent pane",
  covers: [
    "agent-session/acpmux/conversation/WriteLabel.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
  ],
  variants,
});
