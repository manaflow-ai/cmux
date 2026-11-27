// l10n-allow-file: gallery fixtures (agent names), not shipped UI.
//
// A Cloud chat's first prompt on the machine's own chat page while its agent starts there
// (CloudAgentStartLine.tsx): "Starting Claude Code" and its clock" with its clock, where a
// bare "Thinking" stood. `thinking-before` is that old line.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import { CloudAgentStartLine } from "./CloudAgentStartLine";
import { Thinking } from "./Thinking";

type Props = { agent: string; ago: number; before?: boolean };

/// The line as the chat's transcript draws it: under the person's prompt, its clock counting from the
/// send `ago` ms before the stage mounted.
function Stage({ agent, ago, before }: Props) {
  const [since] = useState(() => Date.now() - ago);
  return (
    <div className="acpmux-row acpmux-thinking" style={{ padding: "12px 16px" }}>
      {before ? <Thinking starting since={since} untimed /> : <CloudAgentStartLine agent={agent} since={since} />}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.cloud-agent-start",
  title: "Cloud agent starting line",
  area: "Agent pane",
  experimental: true,
  pane: true,
  covers: [
    "agent-session/acpmux/conversation/CloudAgentStartLine.tsx",
    "agent-session/acpmux/rows/ThinkingRow.tsx",
    "agent-session/acpmux/cloudStartViewModel.ts",
  ],
  keywords: ["cloud", "machine", "start", "agent", "thinking", "first message"],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => Stage,
  widths: { narrow: 300, normal: 620, wide: 760 },
  height: 120,
  variants: {
    "just-sent": {
      note: "Just handed over from the Mac: the machine's page names the agent it starts and the usual wait.",
      props: { agent: "Claude Code", ago: 2_000 },
    },
    "mid-wait": {
      note: "Twelve seconds in: the clock counts on, the usual wait stays.",
      props: { agent: "Claude Code", ago: 12_000 },
    },
    "taking-longer": {
      note: "Past 30 seconds: the usual wait gives way to 'taking longer than usual'.",
      props: { agent: "Claude Code", ago: 47_000 },
    },
    codex: {
      note: "A Codex chat: the line names Codex.",
      props: { agent: "Codex", ago: 4_000 },
    },
    "thinking-before": {
      note: "Before: the bare Thinking line a new user saw while the agent started on the machine.",
      props: { agent: "Claude Code", ago: 4_000, before: true },
    },
  },
});
