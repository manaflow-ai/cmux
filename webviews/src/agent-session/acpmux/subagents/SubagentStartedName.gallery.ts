// l10n-allow-file: gallery fixtures (prompts, subagent tasks), not shipped UI.
// A start line's name chip and its cap (SubagentStartedLine.css `--cv-started-name-max`). Leo's
// recording (ask-31a1e4b192, 2026-11-27, "this isn't great"): "Resolve cmux#61365 conflict, l…
// started working" cut at 16em with two thirds of the chat's width empty after it. Variants: the
// 16em before, 24em, 28em (shipped) and no cap; each with one name and with two.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const running = (task: string): Subagent => ({
  id: `agent-${task.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}`,
  parent: null,
  name: "general-purpose",
  task,
  kind: "general-purpose",
  action: "Read the code",
  state: "running",
  background: true,
  startedAt: minutesAgo(1),
});

const resolve = running("Resolve cmux#61365 conflict, land");
const broker = running("Broker allowlist for verdict dispatch");

const scene = (agents: Subagent[]) =>
  chat(
    [
      user("land 61365", 2),
      row(SUBAGENTS, 1, { subagents: agents }),
      assistant("It runs in the background; I'll land it when it's green.", 1),
    ],
    { isWorking: true },
  );

const capped = (cap: string | undefined) => async (ctx: PlayContext) => {
  if (cap) ctx.document.documentElement.style.setProperty("--cv-started-name-max", cap);
  else ctx.document.documentElement.style.removeProperty("--cv-started-name-max");
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-started"));
};

export default agentPaneEntry({
  id: "agent-pane.subagent-started-name-cap",
  title: "A start line's name is cut only when the line runs short",
  area: "Agent pane",
  height: 260,
  widths: { narrow: 360, normal: 664 },
  anchors: [{ selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/subagents/SubagentStartedLine.css"],
  variants: {
    "before-16em": {
      note: "Before: a 16em cap cut Leo's 'Resolve cmux#61365 conflict, l…' at a third of a 664px chat.",
      play: capped("16em"),
      snapshot: scene([resolve]),
    },
    "cap-24em": {
      note: "24em: the name whole at 664px; a longer one still cuts near the middle of the line.",
      play: capped("24em"),
      snapshot: scene([resolve]),
    },
    "cap-28em": {
      note: "Shipped, 28em: the name whole; two names still keep their widths and the later one gives way first.",
      play: capped(undefined),
      snapshot: scene([resolve]),
    },
    "cap-28em-two": {
      note: "Shipped, two names at 28em: neither shifts when the other joins.",
      play: capped(undefined),
      snapshot: scene([resolve, broker]),
    },
    "no-cap": {
      note: "No cap: one name runs to the line's end, but a second joining cuts the first, the shift Leo flagged on 2026-11-24.",
      play: capped("none"),
      snapshot: scene([resolve, broker]),
    },
  },
});
