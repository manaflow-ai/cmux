// l10n-allow-file: gallery fixtures (prompts, subagent names), not shipped UI.
// The composer's corner and its hat's (the running tray over it), five candidates with the + chip
// (Leo 2026-11-23: "now the composer is a bit too round i think ... just do the claude code
// roundedness"; before that 22, ask-2351b8cf41). Selected: 12, Claude Code desktop's measured corner
// (composerLocation.css --grid-composer-radius; design/composer-corner.md).
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, row, user } from "../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../gallery/clock";
import type { PlayContext } from "../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";

const agents: Subagent[] = ["Audit the picker", "Check the docs", "Measure the composer"].map((name, index) => ({
  id: `round-agent-${index + 1}`,
  parent: null,
  name,
  task: name,
  kind: "Explore",
  state: "running",
  background: true,
  startedAt: minutesAgo(9 - index),
  action: "Read composerLocation.css",
}));

const snapshot = chat(
  [
    user("Round the composer and its hat", 12),
    row(SUBAGENTS, 10, { subagents: agents }),
    assistant("Three subagents are still checking in the background.", 2),
  ],
  { isWorking: false },
);

async function settled(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-box"));
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-running-tray"));
}

const variant = (note: string, round?: string): AgentPaneVariant => ({
  note,
  snapshot,
  play: settled,
  ...(round ? { documentAttributes: { "composer-round": round } } : {}),
});

export default agentPaneEntry({
  id: "agent-pane.composer-round",
  title: "Composer and hat corners",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420, wide: 1100 },
  covers: ["agent-session/acpmux/composerLocation.css"],
  variants: {
    claude: variant("Selected: 12, Claude Code desktop's corner; the + chip's corner is 8; the hat takes the corner."),
    r8: variant("Candidate: 8.", "8"),
    r10: variant("Candidate: 10.", "10"),
    r14: variant("Candidate: 14.", "14"),
    r16: variant("Candidate: 16.", "16"),
    r22: variant("Before: 22, ChatGPT-round (#50920); wrong for a one-line composer.", "22"),
  },
});
