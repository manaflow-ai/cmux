// l10n-allow-file: deterministic motion fixture labels.
// The followed transcript while a long Claude reply streams and its tool calls land and fold, one
// variant per follow-motion arm (Leo, 2026-11-22: "i also feel like the animation or whatever for when
// im at the bottom and the text is streaming to be a bit jarring ... it's just not great design to
// have the jolts. esp in tandem with how aggressively we're folding claude code chats. it's not
// smooth."). It plays the fold-stream turn (scriptedTurn.ts) that test/stream-follow-smooth.test.ts
// measures at 60 Hz, with the Claude family's folds; the `-runs` variants fold each finished run while
// the turn still runs (live-turn-work `runs`).
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { followMotion } from "./followMotion.experiment";
import { FOLD_STREAM_TURN } from "./scriptedTurn";
import { SendStreamMotionGallery } from "./sendStreamMotion.gallery";

/// Plays the turn and waits until its summary row is drawn and the follow motion rests.
const playFold: Play = async (ctx) => {
  ctx.motion.start({ kind: "streaming-follow", target: ".acpmux-scroll", maxMs: 16_000 });
  await ctx.click({ testId: "send-stream-play" });
  await ctx.waitFor(() => ctx.find({ testId: "send-stream-state" }).textContent === "Turn settled", { capMs: 18_000 });
  const thread = ctx.find({ selector: ".acpmux-thread" }) as HTMLElement;
  await ctx.waitFor(() => !thread.style.translate, { capMs: 2_000 });
  const report = ctx.motion.stop();
  if (!report || report.status === "fail") throw new Error(report?.problems.join("; ") ?? "the turn was not sampled");
};

const ARMS = {
  send: "The slim arm (the default before): each chunk, tool row and fold moves at once.",
  steady: "Steady drift (the default): the view moves at the stream's own pace, a small reserve under the composer.",
  blocks: "Chase each chunk home in one eased step.",
  linear: "Chase each chunk home at a constant speed.",
} as const;

const variants = Object.fromEntries(
  Object.entries(ARMS).flatMap(([arm, note]) => [
    [arm, { props: {}, play: playFold, note, experiments: { "follow-motion": arm } }],
    [
      `${arm}-runs`,
      {
        props: {},
        play: playFold,
        note: `${note} Each finished run folds while the turn runs.`,
        experiments: { "follow-motion": arm, "live-turn-work": "runs" },
      },
    ],
  ]),
);

function StreamFollowFold() {
  return <SendStreamMotionGallery turn={FOLD_STREAM_TURN} family="claude" />;
}

export default componentEntry<Record<string, never>>({
  id: "agent-pane.stream-follow-fold",
  title: "Stream and fold follow motion",
  area: "Agent pane",
  height: 600,
  anchors: [{ selector: "[data-testid=send-stream-play]" }],
  checks: {
    anchorMovePx: { value: 0, reason: "The transcript's motion must not move the fixed play control." },
    settleMaxMs: {
      value: 18_000,
      reason: "The scripted turn streams and folds for about eight seconds, then settles.",
    },
  },
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
    "agent-session/acpmux/conversation/followChase.ts#createFollowChase",
  ],
  load: async () => StreamFollowFold,
  pane: true,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("../composerControls.css"),
      import("../bottomStack.css"),
    ]),
  variants,
  experiment: {
    definition: followMotion,
    script: [{ name: "Stream and fold", run: playFold }],
  },
});
