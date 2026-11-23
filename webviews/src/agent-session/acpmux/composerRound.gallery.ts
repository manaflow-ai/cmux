// l10n-allow-file: gallery fixtures (prompts, subagent names), not shipped UI.
// The composer's corner and its hat's (the running tray over it), three ways (ask-2351b8cf41,
// Leo 2026-11-22: "we should consider rounding off our composer and its hat a bit more maybe see
// chatgpt too"). Each corner is concentric with what sits in the box (composerLocation.css
// --grid-composer-radius): the selected `large` is half a round control plus the inset (22),
// `moderate` the + plate's corner plus the inset (16), `pill` half the one-line box (24).
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
    large: variant(
      "Selected: 22, half a round control (the mic, Send) plus the inset; the hat over it takes the same corner.",
    ),
    moderate: variant("Alternative: 16, the + plate's 8 corner plus the inset.", "moderate"),
    pill: variant("Alternative: 24, half the one-line box, so one line is a full pill.", "pill"),
  },
});
