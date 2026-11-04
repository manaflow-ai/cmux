// l10n-allow-file: synthetic gallery names, not shipped UI.
import { componentEntry } from "../../../gallery/format";
import { AgentIdentity, type AgentIdentityLook } from "./AgentIdentity";
import { agentTone } from "./agentTones";

const agents = [
  { id: "reviewer", name: "Review rendering", harness: "claude" },
  { id: "explorer", name: "Explore layout", harness: "claude" },
  { id: "writer", name: "Update tests", harness: "claude" },
  { id: "codex-helper", name: "Check results", harness: "codex" },
];

type Props = { look: AgentIdentityLook };

function IdentityOptions({ look }: Props) {
  return (
    <div className="acpmux-main" style={{ padding: 24 }}>
      {agents.map((agent) => (
        <div key={agent.id} style={{ display: "flex", alignItems: "center", gap: 8, minHeight: 32 }}>
          <AgentIdentity harness={agent.harness} tone={agentTone(agent.id)} size={16} look={look} />
          <span style={{ flex: 1 }}>{agent.name}</span>
          <span className="acpmux-summary-meta">Done · 36s</span>
        </div>
      ))}
    </div>
  );
}

export default componentEntry<Props>({
  id: "agent-pane.subagent-identity",
  title: "Subagent identity hues",
  area: "Agent pane",
  pane: true,
  height: 220,
  widths: { narrow: 320, normal: 420, wide: 620 },
  covers: ["agent-session/acpmux/subagents/AgentIdentity.tsx#AgentIdentity"],
  styles: () => Promise.all([import("../styles.css"), import("./subagents.css")]),
  load: async () => IdentityOptions,
  variants: {
    tint: { props: { look: "tint" }, note: "Selected: one mark, stable hue, no extra geometry." },
    badge: { props: { look: "badge" }, note: "Brand mark with an extra colour badge." },
    marker: { props: { look: "marker" }, note: "Brand mark with a leading colour stroke." },
  },
});
