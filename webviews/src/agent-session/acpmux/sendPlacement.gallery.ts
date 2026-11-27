// l10n-allow-file: gallery fixtures and diagnostics, not shipped UI.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { chat } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { COMPOSER_EDITOR } from "./composerSelectors";
import { sample, seedCompletedTurns } from "./composerSendOneMotion.gallery";

const TRUSTED = "~/code/cmux";
const PROMPT = "Place this new prompt";
const fresh = chat([]);
const snapshot = { ...fresh, summary: { ...fresh.summary!, cwd: TRUSTED } };
// fixed-wait: setup must rest beyond the motion scale before frame sampling starts.
const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function sendPlacement(top: boolean, history: boolean) {
  return async (ctx: PlayContext) => {
    const doc = ctx.document;
    const win = doc.defaultView!;
    // Seed at the ordinary latest position: the option applies to the measured send, not setup.
    if (history) await seedCompletedTurns(ctx, ["first question", "second question", "third question"]);
    const { setChatDisplay } = await import("./chatDisplay");
    setChatDisplay({ "agentPane.display.sendScrollsToTop": top });
    await ctx.type(PROMPT, { selector: COMPOSER_EDITOR });
    await pause(600);
    const scroller = doc.querySelector<HTMLElement>(".acpmux-scroll")!;
    const before = {
      top: scroller.scrollTop,
      overflow: scroller.scrollHeight - scroller.clientHeight,
    };
    // Keep the agent's reply outside the measurement; its growth is a separate motion.
    Object.assign(win, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: 5000 });
    const frames = sample(doc, PROMPT, 1800);
    const frame = () => new Promise<number>((resolve) => win.requestAnimationFrame(resolve));
    await frame();
    await frame();
    await ctx.press("Enter");
    const drawn = await frames.done;
    const prompt = [...doc.querySelectorAll(".acpmux-row.acpmux-user")].find((row) =>
      row.textContent?.includes(PROMPT),
    );
    if (!prompt) throw new Error("The measured send never appeared");
    doc.documentElement.dataset.sendPlacement = JSON.stringify({
      top,
      history,
      before,
      promptTop: prompt.getBoundingClientRect().top,
      scrollerTop: scroller.getBoundingClientRect().top,
      fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
      frames: drawn,
    });
  };
}

const variants: Record<string, AgentPaneVariant> = {};
for (const [name, top, history, note] of [
  ["default-latest", false, true, "Default: earlier turns stay above the new prompt at the latest row."],
  ["top-long", true, true, "Opt-in: a new prompt sweeps to the top of a transcript with history."],
  ["top-short", true, false, "Opt-in: the first prompt sits at the top with room below for its reply."],
] as const)
  variants[name] = {
    note,
    ready: { transport: "mock", newSession: true, cwd: TRUSTED },
    snapshot,
    display: {},
    play: sendPlacement(top, history),
  };

export default agentPaneEntry({
  id: "agent-pane.send-placement",
  title: "Sent prompt placement",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1100 },
  checks: {
    layoutShiftMax: {
      value: 1,
      reason: "The send intentionally moves the transcript; the play records every frame.",
    },
    longFrameFailMs: {
      value: 400,
      reason: "Mock setup renders whole turns; the send is measured separately.",
    },
  },
  covers: ["agent-session/acpmux/VirtualTranscript.tsx", "agent-session/acpmux/conversation/followGlide.ts"],
  variants,
});
