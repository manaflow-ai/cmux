// l10n-allow-file: gallery fixtures (prompts, subagent tasks), not shipped UI.
// Each subagent's own colour (agentTones.ts). Leo, 2026-11-04: "Each subagent gets its own colour
// (medium). Today three Claude subagents look identical. Keep the harness mark and add a stable
// colour per subagent, used everywhere it shows." The three Claude subagents here have ids that all
// hash to one tone, the case that drew them alike: the chat now assigns its agents' tones together,
// so each keeps the Claude mark and gets its own theme tone, the same in the transcript, the tray and
// Session Info.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const claude = (id: string, task: string, minutes: number, state: Subagent["state"]): Subagent => ({
  id,
  parent: null,
  name: "general-purpose",
  kind: "general-purpose",
  task,
  harness: "claude",
  state,
  background: true,
  startedAt: minutesAgo(minutes),
  ...(state !== "running" && { endedAt: minutesAgo(minutes - 1.5) }),
  ...(state === "running" && { action: "Read subagents.css" }),
});

const three = (state: Subagent["state"]) => [
  claude("agent-review-rendering", "Review rendering", 6, state),
  claude("agent-check-tokens", "Check the colour tokens", 5, state),
  claude("agent-read-theme", "Read the theme's palette", 4, state),
];

const scene = (state: Subagent["state"]) =>
  chat(
    [
      user("Split the theming review three ways", 7),
      row(SUBAGENTS, 6, { subagents: three(state) }),
      ...(state === "running" ? [] : [assistant("All three reviewers reported back.", 1)]),
    ],
    { isWorking: state === "running" },
  );

export default agentPaneEntry({
  id: "agent-pane.subagent-tones",
  title: "Three Claude subagents, three colours",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }, { selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/subagents/agentTones.ts"],
  variants: {
    running: {
      note: "Three Claude subagents running, whose ids hash to one tone: each takes its own tone in the tray and the transcript, and keeps the Claude mark.",
      snapshot: scene("running"),
    },
    done: {
      note: "The same three after they finished: each done line keeps the tone it had while it ran.",
      snapshot: scene("completed"),
    },
  },
});
