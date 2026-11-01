// l10n-allow-file: synthetic transcript for copy-control regression captures.
import { componentEntry } from "../../../gallery/format";
import { activity, assistant, tool } from "../../../gallery/fixtures/acpmux";
import { VirtualTranscript } from "../App";

const rows = [
  assistant("The build returned this result.", 3),
  activity(
    [
      tool("Read build result", "other", "completed", {
        output: '{"status":"passed","checks":12,"warnings":0}',
        startedAt: 1000,
        endedAt: 3300,
      }),
    ],
    2,
    { id: "copy-tool" },
  ),
  assistant("Copy just this block when sharing the command:\n\n```sh\nbun run check\n```", 1),
];
function CopyControls() {
  return (
    <div className="acpmux-shell">
      <VirtualTranscript rows={rows} sessionId="copy-controls" expanded={new Set()} onToggleActivity={() => {}} />
    </div>
  );
}
export default componentEntry<Record<string, never>>({
  id: "agent-pane.copy-controls",
  title: "One copy action per transcript item",
  area: "Agent pane",
  height: 520,
  pane: true,
  covers: [
    "agent-session/acpmux/App.tsx#RowFrame",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/conversation/CopyButton.tsx",
  ],
  load: async () => CopyControls,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: {
    output: {
      props: {},
      note: "Open the tool result: wrap and output-copy stay inside the block; no floating copy covers the duration.",
    },
  },
});
