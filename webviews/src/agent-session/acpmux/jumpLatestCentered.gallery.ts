// l10n-allow-file: sample transcript and comparison labels, not shipped UI.
// Jump to latest on the composer's center line (conversation.css .acpmux-jump-latest). Leo,
// 2026-11-07: "And also the jump to bottom button is still not centered with the composer yet." The
// button took the stage's middle while the composer card sits in the column between --cv-inset and
// --cv-inset-end, so Session Info pushing the column left (a wide pane) or the computer use preview
// taking its end stood it right of the card. Each variant parks the reader mid-chat so the button
// shows; view them at every width (narrow 420, normal 900, wide 1600). The `anchor-*` arms compare
// where the button could center while Session Info pushes; `anchor-composer` ships.
// test/agent-pane-jump-latest-centered.test.ts measures |button center - composer center| <= 0.5px.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";

const snapshot = chat(
  Array.from({ length: 24 }, (_, index) => [
    user(`Check retry case ${index + 1}`, 50 - index * 2),
    assistant(
      `Case ${index + 1} passes. The client retries a temporary transport failure, keeps the original request id, and stops after the last attempt. `.repeat(
        3,
      ),
      49 - index * 2,
    ),
    summary(49 - index * 2, { status: "completed" }),
  ]).flat(),
);

type Info = "closed" | "overlay" | "push";

/** Where an arm puts the button's center instead of the shipped rule (conversation.css). */
const ANCHORS = {
  /** Before: the stage's middle, blind to the column's insets. */
  stage: "50%",
  /** The middle of the chat that Session Info leaves beside it, blind to the column's own clamp. */
  visible: "calc((100% - var(--acpmux-session-info-shift, 0px)) / 2)",
} as const;

const park =
  ({ info, computerUse, anchor }: { info: Info; computerUse?: boolean; anchor?: keyof typeof ANCHORS }): Play =>
  async (ctx) => {
    if (info !== "closed") {
      const { setHeaderState } = await import("./header/headerState");
      const { setChatDisplay } = await import("./chatDisplay");
      const { setSessionInfoOpen } = await import("./session-info/sessionInfoState");
      setHeaderState({ inspector: true });
      setChatDisplay({ "agentPane.display.sessionInfo.placement": info });
      setSessionInfoOpen(true);
      const toggle = '.acpmux-session-info-toggle[aria-pressed="false"]';
      await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-info-toggle"));
      if (ctx.document.querySelector(toggle)) await ctx.click({ selector: toggle });
      await ctx.waitFor(() => ctx.document.querySelector('.acpmux-session-info[data-presence="shown"]'));
    }
    if (computerUse) ctx.document.querySelector(".acpmux-main")?.setAttribute("data-cu-preview", "");
    await ctx.waitFor(() => (ctx.document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollHeight ?? 0) > 1_000);
    await ctx.scroll({ selector: ".acpmux-scroll" }, 1_200);
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest:not(.acpmux-jump-up)[data-shown]"));
    if (anchor)
      ctx.document
        .querySelector<HTMLElement>(".acpmux-jump-latest:not(.acpmux-jump-up)")
        ?.style.setProperty("left", ANCHORS[anchor]);
  };

export default agentPaneEntry({
  id: "agent-pane.jump-latest-centered",
  title: "Jump to latest centered on the composer",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1600 },
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  keywords: ["jump to bottom", "scroll to bottom", "center", "session info"],
  checks: {
    anchorMovePx: { value: 0, reason: "Parking the reader moves only the transcript; the composer holds still." },
  },
  variants: {
    closed: {
      note: "Session Info closed: the card and the button share the pane's middle.",
      snapshot,
      play: park({ info: "closed" }),
    },
    "session-info-overlay": {
      note: "Session Info floats over the chat: the column does not move, nor does the button.",
      snapshot,
      play: park({ info: "overlay" }),
    },
    "session-info-push": {
      note: "Session Info pushes (wide): the column moves left and the button stays on the card's center (ships).",
      snapshot,
      play: park({ info: "push" }),
    },
    "computer-use-beside": {
      note: "The computer use preview takes the column's end: the button follows the card's center.",
      snapshot,
      play: park({ info: "closed", computerUse: true }),
    },
    "anchor-stage": {
      note: "Before: the stage's middle; with Session Info pushing at wide the button stands right of the card.",
      snapshot,
      play: park({ info: "push", anchor: "stage" }),
    },
    "anchor-visible": {
      note: "The middle of the chat beside Session Info: right only while the column is not clamped to the pane's edge.",
      snapshot,
      play: park({ info: "push", anchor: "visible" }),
    },
    "anchor-composer": {
      note: "Selected (ships): the composer card's own center, from the insets the card is laid out by.",
      snapshot,
      play: park({ info: "push" }),
    },
  },
});
