// l10n-allow-file: deterministic tool-group geometry fixture.
import { componentEntry } from "../../../gallery/format";
import { activity, tool } from "../../../gallery/fixtures/acpmux";
import { VirtualTranscript } from "../App";

const rows = [
  activity(
    [
      tool("Read the first fixture", "read", "completed", { id: "card-height-one" }),
      tool("Read the second fixture", "read", "completed", { id: "card-height-two" }),
    ],
    1,
    { id: "card-height-group", folded: true },
  ),
];

function ToolGroupCardHeightGallery() {
  // The card arm is intentionally gallery-only; production uses the shipped flat rows. Keep the
  // fixture's root arm explicit so this test measures the bordered card rather than plain rows.
  document.documentElement.dataset.toolStepsLook = "card";
  return (
    <div className="acpmux-shell">
      <VirtualTranscript
        rows={rows}
        sessionId="tool-group-card-height"
        expanded={new Set()}
        onToggleActivity={() => {}}
      />
    </div>
  );
}

export default componentEntry<Record<string, never>>({
  id: "agent-pane.tool-group-card-height",
  title: "Expanded tool-group card ends at its last row",
  area: "Agent pane",
  height: 680,
  pane: true,
  covers: ["agent-session/acpmux/conversation/ToolGroupRow.tsx"],
  load: async () => ToolGroupCardHeightGallery,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants: { default: { props: {} } },
});
