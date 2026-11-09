// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { threadMinimapRestTick } from "./restTick.experiment";

// The left prompt rail's resting ticks where its gutter runs short (Leo, 2026-11-06: "you guys didn't fix
// the spacing on this left side session rail thing"): Session Info pushing the chat's column toward the
// left rail, the same push with the rail on the right, and a narrow pane. The compare view shows the
// three arms of restTick.experiment.ts side by side: `steady` (shipped), `squeeze` (the earlier ticks,
// shortened with the hit width) and `inset-first` (the rail's inset gives way first, so the rail moves).
const rows = Array.from({ length: 14 }, (_, index) => [
  user(`Prompt ${index + 1}: check the next part of the plan`, 200 - index * 2),
  assistant(
    `Part ${index + 1} checked.\n\nThe reply has a second paragraph so each turn has some height in the transcript.`,
    199.8 - index * 2,
  ),
  summary(199.6 - index * 2, { status: "completed" }),
]).flat();

const push = { "agentPane.display.sessionInfo.placement": "push" };

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-rest-tick",
  title: "Prompt rail resting ticks beside a pushed chat",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 800, normal: 1200, wide: 1400 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: ["agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap"],
  experiment: {
    definition: threadMinimapRestTick,
    script: [{ name: "hover prompt 4", run: (ctx) => ctx.hover({ selector: '[data-tick="3"]' }) }],
  },
  variants: {
    "left-pushed": {
      note: "Session Info pushes the chat (Push always): the column moves toward the left rail. Steady ticks keep their 6 px; squeezed ones draw 4.6 px at 1200; inset-first moves the rail in.",
      snapshot: chat(rows, { title: "Left rail beside a pushed chat" }),
      native: { "pane.tabState": { inspector: true } },
      sessionInfoOpen: true,
      display: push,
    },
    "right-pushed": {
      note: "The same push with the rail on the right: the column moves away from it, so every arm draws it as at rest.",
      snapshot: chat(rows, { title: "Right rail beside a pushed chat" }),
      native: { "pane.tabState": { inspector: true } },
      sessionInfoOpen: true,
      display: { ...push, "agentPane.display.rail.side": "right" },
    },
    closed: {
      note: "Session Info closed: the rail at its pane-edge inset; at 800 the tight gutter narrows it, and squeezed ticks draw 2.8 px there.",
      snapshot: chat(rows, { title: "Left rail at rest" }),
    },
  },
});
