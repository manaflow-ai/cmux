// l10n-allow-file: sample transcript and comparison notes, not shipped UI.
// The band at the chat's foot, behind the composer (dockBand.experiment.ts, conversation/besideStack.ts).
// Leo, 2026-11-22, of a chat scrolled up: "AND I KINDA HATE HOW MUCH FUCKING SOLID + BLUR THERE IS AT
// THE BOTTOM [image] OF THE BOX. FIGURE OUT HOW WE CAN HAVE MORE STUFF THERE." Every variant is a long
// chat parked mid-transcript, so rows run behind the composer card and its quiet row; one variant per
// arm. View light and dark (?colorScheme=light / dark), and over a picture (?background=dark): only
// there does the card's glass blur, so only there do the frost arms show rows under it; test/agent-pane-dock-band.test.ts measures how
// many px of rows read under the card and in the band, and captures every arm.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import { dockBand } from "./dockBand.experiment";
import type { DockBandArm } from "./conversation/besideStack";

const snapshot = chat(
  Array.from({ length: 20 }, (_, index) => [
    user(`Check retry case ${index + 1}`, 60 - index * 2),
    assistant(
      `Case ${index + 1} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. `.repeat(
        3,
      ),
      59 - index * 2,
    ),
    summary(59 - index * 2, { status: "completed" }),
  ]).flat(),
);

/** Parks the transcript 900 px above its end, so rows pass behind the card and the quiet row. */
const park: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-foot"));
  await ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 2_000);
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  await ctx.scroll({ selector: ".acpmux-scroll" }, Math.max(0, scroller.scrollHeight - scroller.clientHeight - 900));
  await ctx.waitFor(() =>
    ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.style.getPropertyValue("--acpmux-beside-images"),
  );
};

const variant = (arm: DockBandArm, note: string) => ({
  note,
  snapshot,
  play: park,
  experiments: { [dockBand.id]: arm },
});

export default agentPaneEntry({
  id: "agent-pane.dock-band",
  title: "The band behind the composer at the chat's foot",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: [
    "agent-session/acpmux/dockBand.experiment.ts",
    "agent-session/acpmux/conversation/besideStack.ts",
    "agent-session/acpmux/conversation/useBesideStack.ts",
  ],
  keywords: ["composer", "bottom stack", "band", "blur", "frost", "glass", "mask", "quiet row"],
  checks: {
    anchorMovePx: { value: 0, reason: "Parking the reader moves only the transcript; the composer holds still." },
  },
  experiment: { definition: dockBand, script: [{ name: "Park mid-chat", run: park }] },
  variants: {
    shipped: variant(
      "shipped",
      "Selected (ships), Leo's screenshot: rows stop at the card's top edge; the card and the quiet row's band are blank.",
    ),
    frost: variant("frost", "Rows run under the card's glass and stop at its bottom edge."),
    "frost-ramp": variant("frost-ramp", "Rows under the card's glass, then a 16 px fade into the quiet row's band."),
    "frost-through": variant(
      "frost-through",
      "No blank band: rows under the card and on to the pane's foot, fading out behind the quiet row.",
    ),
  },
});
