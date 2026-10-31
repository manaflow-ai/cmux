// l10n-allow-file: sample transcript and comparison labels, not shipped UI.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";

const snapshot = chat(
  Array.from({ length: 24 }, (_, index) => [
    user(`Check retry case ${index + 1}`, 50 - index * 2),
    assistant(
      `Case ${index + 1} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt.\n\nThe next check verifies that the same response reaches the caller exactly once.`,
      49 - index * 2,
    ),
    summary(49 - index * 2, { status: "completed" }),
  ]).flat(),
);

const park =
  (band?: number): Play =>
  async (ctx) => {
    await ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 1_000);
    await ctx.scroll({ selector: ".acpmux-scroll" }, 1_200);
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest[data-shown]"));
    if (band !== undefined)
      ctx.document.querySelector<HTMLElement>(".acpmux-scroll")!.style.setProperty("--acpmux-fade-bottom", `${band}px`);
  };

export default agentPaneEntry({
  id: "agent-pane.composer-edge",
  title: "Transcript edge above the composer",
  area: "Agent pane",
  height: 700,
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript"],
  checks: {
    anchorMovePx: { value: 0, reason: "Changing an alpha mask must not move transcript or composer geometry." },
  },
  variants: {
    "short-edge": {
      note: "Selected: the normal 18px soft edge keeps text above the composer readable, including beside Jump to latest.",
      snapshot,
      play: park(),
    },
    "wide-edge": {
      note: "Before: Jump to latest extends the fading band to 56px, washing out almost three lines above the composer.",
      snapshot,
      play: park(56),
    },
    "no-edge": {
      note: "Alternative: no fading band; the transcript cuts sharply at the composer while the jump button remains glass.",
      snapshot,
      play: park(0),
    },
  },
});
