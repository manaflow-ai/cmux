// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// Leo, 2026-11-22, after the send pop (#50293, #50784): "actually, i think the send pop and whatever...
// well it's made me aware of another situation, which is that the chat transcript above doesn't quite
// smoothly account for things." With the pop on, the sent bubble pops on its 450 ms curve while the
// rows above it jumped into its room in one frame. Each variant turns the pop on, sends a prompt from
// the latest row with one rise arm (composerStates.css SEND-RISE, `data-send-rise`), and samples every
// frame: the rows above (the last prompt), the sent bubble, the thinking row and the composer. It
// records the largest move of the rows above in one frame and when each box comes to rest;
// test/agent-pane-send-rise.test.ts holds the pop arms to a smooth rise and `none` to the jump it fixes.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { chat } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { COMPOSER_EDITOR } from "./composerSelectors";
import { sample, seedCompletedTurns, sendWindow } from "./composerSendOneMotion.gallery";

const EDITOR = { selector: COMPOSER_EDITOR };
const TRUSTED = "~/code/cmux";
const fresh = chat([]);
const snapshot = { ...fresh, summary: { ...fresh.summary!, cwd: TRUSTED } };
const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type Arm = "pop" | "settle" | "quick" | "none";
const ARMS: Record<Arm, string> = {
  pop: "Selected: the rows above rise into the bubble's room on the pop's own clock and curve (450 ms, cubic-bezier(.34, 1.3, .64, 1)), so they and the bubble rest in one frame.",
  settle: "The pop's clock without its overshoot (cubic-bezier(.34, 1, .64, 1)): the rows never pass their place.",
  quick: "The motion scale's large step, eased out: the rows land before the bubble has settled.",
  none: "Before: the rows above jump into the bubble's room in the frame of the send, while it pops.",
};

/// The frame (ms from the first sample) after which `key` no longer moves; 0 when it never moved.
function restAt(frames: readonly ReturnType<typeof sendWindow>[number][], key: "prev" | "sent" | "thinking") {
  let at = 0;
  for (let index = 1; index < frames.length; index += 1) {
    const before = frames[index - 1]![key];
    const after = frames[index]![key];
    if (before != null && after != null && Math.abs(after - before) > 0.5) at = frames[index]!.t;
  }
  return at;
}

function sendWith(arm: Arm, lines: number) {
  return async (ctx: PlayContext) => {
    const doc = ctx.document;
    doc.documentElement.setAttribute("data-send-pop", "claude");
    doc.documentElement.setAttribute("data-send-rise", arm);
    await seedCompletedTurns(ctx, ["first question", "second question"]);
    await pause(400);
    for (let index = 1; index <= lines; index += 1) {
      await ctx.type(`rise line ${index}`, EDITOR);
      if (index < lines) await ctx.press("Shift+Enter");
    }
    await pause(400);
    // The agent's reply ends the send's window (sendWindow), so it comes after the sample: a 40 ms
    // reply on a loaded runner cut the window mid-motion and the rows "rested" early or never moved.
    Object.assign(doc.defaultView!, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: 2000 });
    const win = doc.defaultView!;
    const frameAt = () => new Promise<number>((resolve) => win.requestAnimationFrame(resolve));
    // Long enough for a send a loaded runner holds a few hundred ms to still play whole inside it.
    const frames = sample(doc, "rise line 1", 1800);
    // The sampler's first frame (its t = 0) and one after it, before the send: on a loaded runner the
    // first frame can come after an 80 ms timer, and a sample that starts mid-motion misses its start.
    const start = await frameAt();
    await frameAt();
    await pause(80);
    // The rests are timed from the press, so a late frame only makes them later, never early.
    const pressedAt = win.performance.now() - start;
    await ctx.press("Enter");
    const window = sendWindow(await frames.done);
    let prevJump = 0;
    let prevTravel = 0;
    for (let index = 1; index < window.length; index += 1) {
      const before = window[index - 1]!.prev;
      const after = window[index]!.prev;
      if (before == null || after == null) continue;
      // Per 60 Hz frame: headless Chromium drops frames under load, and a gap of several frames is
      // not one frame's jump.
      const frames = Math.max(1, Math.round((window[index]!.t - window[index - 1]!.t) / (1000 / 60)));
      prevJump = Math.max(prevJump, Math.abs(after - before) / frames);
      prevTravel += Math.abs(after - before);
    }
    const data = doc.documentElement.dataset;
    data.riseFrames = JSON.stringify(window);
    data.risePrevJump = String(Math.round(prevJump * 10) / 10);
    data.risePrevTravel = String(Math.round(prevTravel * 10) / 10);
    const sincePress = (at: number) => (at > 0 ? Math.round(at - pressedAt) : 0);
    data.risePrevRest = String(sincePress(restAt(window, "prev")));
    data.riseSentRest = String(sincePress(restAt(window, "sent")));
  };
}

const variants: Record<string, AgentPaneVariant> = {};
for (const arm of Object.keys(ARMS) as Arm[])
  for (const [shape, lines] of [
    ["1-line-idle", 1],
    ["3-lines-idle", 3],
    ["5-lines-idle", 5],
  ] as const)
    variants[`${arm}-${shape}`] = {
      note: `${ARMS[arm]} Play: send a ${lines}-line prompt to an idle agent with the pop on.`,
      ready: { transport: "mock", newSession: true, cwd: TRUSTED },
      snapshot,
      play: sendWith(arm, lines),
    };

export default agentPaneEntry({
  id: "agent-pane.send-rise",
  title: "The transcript rises with the send pop",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1100 },
  checks: {
    layoutShiftMax: {
      value: 1,
      reason: "A send moves the transcript on purpose; the play measures the rows' rise itself.",
    },
    longFrameFailMs: {
      value: 400,
      reason:
        "The mock agent renders each whole reply turn in one task; the send's own frames are what the play measures.",
    },
  },
  covers: [
    "agent-session/acpmux/composerStates.css#SEND-RISE",
    "agent-session/acpmux/conversation/followChase.ts",
    "agent-session/acpmux/VirtualTranscript.tsx",
  ],
  variants,
});
