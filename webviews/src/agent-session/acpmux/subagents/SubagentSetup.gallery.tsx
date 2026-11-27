// l10n-allow-file: gallery fixtures (subagent names, tasks and model ids), not shipped UI.
// What a subagent was started with, on its hover card (SubagentPreview.tsx, subagentSetup.ts). Leo,
// 2026-11-22: "so for subagents, actually, are their permissions/model locked right then and there?
// does it make sense to be able to reveal the fork or whatever switching model behaviour for it?"
// A harness's own subagent takes its model at spawn and runs under its chat's permission mode, and
// nothing switches either later, so the card reveals them. Three looks:
// - `line` (the pick, shipped): one muted line under the state, "claude-haiku-4-5 · high · Plan";
// - `in-state`: the same words appended to the state line (one line fewer, a longer state);
// - `pills`: each as a small pill (louder; reads as controls that are not there).
// Then the shipped line in the states that matter: bypass permissions, no report, a finished one.
// Synthetic data.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { Subagent } from "./subagentFold";

type Look = "line" | "in-state" | "pills";

type Props = {
  look: Look;
  model?: string;
  effort?: string;
  permissionMode?: string;
  done?: boolean;
};

const agentOf = ({ model, effort, permissionMode, done }: Props): Subagent => ({
  id: "setup-agent",
  parent: null,
  name: "Tool-call audit",
  task: "Audit every tool call row for the shared row grammar and list each one that drifts",
  kind: "Explore",
  action: "Grep cv-tool__text",
  state: done ? "completed" : "running",
  startedAt: minutesAgo(4),
  ...(done && { endedAt: minutesAgo(1), lastMessage: "Three rows drift: Read, Grep and WebFetch." }),
  ...(model && { model }),
  ...(effort && { effort }),
  ...(permissionMode && { permissionMode }),
});

export default componentEntry<Props>({
  id: "agent-pane.subagent-setup",
  title: "Subagent card: model and permission mode",
  area: "Agent pane",
  pane: true,
  height: 200,
  widths: { narrow: 360, normal: 560 },
  anchors: [{ selector: "[data-subagent-setup-gallery]" }],
  covers: ["agent-session/acpmux/subagents/SubagentPreview.tsx", "agent-session/acpmux/subagents/subagentSetup.ts"],
  load: async () => {
    const { SubagentPreviewCard, SubagentCardBody } = await import("./SubagentPreview");
    const { subagentSetup, subagentModeName } = await import("./subagentSetup");
    return function GallerySubagentSetup(props: Props) {
      const agent = agentOf(props);
      const setup = subagentSetup(agent);
      return (
        <main className="acpmux-shell" data-subagent-setup-gallery style={{ padding: "var(--ds-space-4)" }}>
          <div className="ui-tooltip ui-glass ui-card acpmux-agent-card__popup acpmux-subagent-preview">
            {props.look === "line" && <SubagentPreviewCard agent={agent} />}
            {props.look === "in-state" && (
              <SubagentCardBody
                name={agent.task}
                status="running"
                state={["Running", "3m 0s", agent.name, agent.kind, setup].filter(Boolean).join(" · ")}
                latest={agent.action}
              />
            )}
            {props.look === "pills" && (
              <span className="acpmux-agent-card">
                <span className="acpmux-agent-card__name">{agent.task}</span>
                <span className="acpmux-agent-card__state">Running · 3m 0s · {agent.name}</span>
                <span style={{ display: "flex", gap: "4px" }}>
                  {[agent.model, agent.effort, agent.permissionMode && subagentModeName(agent.permissionMode)]
                    .filter(Boolean)
                    .map((text) => (
                      <span
                        key={text}
                        style={{
                          padding: "0 calc(var(--ds-space-1) + var(--grid-half-step))",
                          borderRadius: "8px",
                          background: "var(--cmux-fill-secondary, #8882)",
                        }}
                      >
                        {text}
                      </span>
                    ))}
                </span>
              </span>
            )}
          </div>
        </main>
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./subagents.css")]),
  variants: {
    line: {
      note: "The pick: one muted line under the state names the model, effort and permission mode it was started with.",
      props: { look: "line", model: "claude-haiku-4-5", effort: "high", permissionMode: "plan" },
    },
    "in-state": {
      note: "Version B: the same words at the end of the state line. One line fewer, but the state line wraps in a narrow pane.",
      props: { look: "in-state", model: "claude-haiku-4-5", effort: "high", permissionMode: "plan" },
    },
    pills: {
      note: "Version C: each as a pill. Louder, and pills read as pickers, which a subagent has none of.",
      props: { look: "pills", model: "claude-haiku-4-5", effort: "high", permissionMode: "plan" },
    },
    bypass: {
      note: "A subagent of a chat in Bypass permissions: the card says so in Claude Code's own words.",
      props: { look: "line", model: "claude-opus-5-5", permissionMode: "bypassPermissions" },
    },
    "no-report": {
      note: "A harness that reported neither (older acpmux): no setup line, the card as before.",
      props: { look: "line" },
    },
    done: {
      note: "A finished one keeps the line, so what ran it stays readable after it ends.",
      props: { look: "line", model: "claude-sonnet-4-6", effort: "default", permissionMode: "acceptEdits", done: true },
    },
  },
});
