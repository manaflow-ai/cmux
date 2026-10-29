// l10n-allow-file: deterministic sample transcript for overlap regression captures.
import { componentEntry } from "../../../gallery/format";
import { activity, assistant, tool, user } from "../../../gallery/fixtures/acpmux";
import { VirtualTranscript } from "../App";

const rows = [
  ...Array.from({ length: 35 }, (_, index) => [
    user(`Review pass ${index + 1}: check the build and the transcript.`, 80 - index, {
      id: `mixed-user-${index}`,
    }),
    assistant(
      `Pass ${index + 1} completed. The build receipt matches the reviewed commit.\n\nThe transcript keeps its own place while older work opens.`,
      79 - index,
      { id: `mixed-answer-${index}` },
    ),
  ]).flat(),
  activity(
    [
      tool("Update the verification note", "edit", "completed", {
        diffs: [{ path: "verification.md", oldText: "pending", newText: "verified" }],
      }),
      tool("Check the exact build receipt", "execute", "completed", {
        command: "printf '%s\\n' 'build receipt verified'",
        output: "build receipt verified",
      }),
      tool("Read the coordination note", "read", "completed", {
        locations: [{ path: "coordination.md" }],
        output:
          "coordination-note.txt: The reviewed head is ready; keep the receipt on the exact SHA and preserve transcript order while the tools settle. This long first line deliberately reaches beneath the top-right Wrap lines and Copy controls so the output needs a readable right lane, never a wrapper plate.\n\nSecond line: checks remain green.",
      }),
    ],
    1,
    { id: "mixed-tool-group", foldRun: true },
  ),
  user(
    "Correction: post-merge verification exposed a wrapper bug. Keep the following message below every tool row, including while a group is expanding.\n\nThis prompt deliberately spans several lines so the bubble has a visible leading edge.",
    0.5,
    { id: "mixed-after-tools" },
  ),
];

function ToolGroupOverlapGallery() {
  return (
    <div className="acpmux-shell">
      <VirtualTranscript rows={rows} sessionId="mixed-tool-overlap" expanded={new Set()} onToggleActivity={() => {}} />
    </div>
  );
}

export default componentEntry<Record<string, never>>({
  id: "agent-pane.tool-group-overlap",
  title: "Tool group followed by a prompt in a long transcript",
  area: "Agent pane",
  height: 680,
  pane: true,
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript", "agent-session/acpmux/conversation/ToolRun.tsx"],
  load: async () => ToolGroupOverlapGallery,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: { mixed: { props: {} } },
});
