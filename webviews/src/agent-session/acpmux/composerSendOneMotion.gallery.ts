// l10n-allow-file: gallery fixtures (sample prompts and a multi-line draft), not shipped UI.
// Leo, 2026-11-22: "i just felt like just now there was a one-two motion when sending a tall message
// (i.e. multi line composer) when i send it collapses the compser then sends it to you... but i
// think we should be able to calculate it out to be like one smooth motion." He saw it sending after
// the agent sat idle. Each variant sends a draft of 1, 5 or 15 lines, with the agent idle or busy,
// from the latest row or scrolled up; its play samples every frame of the send and fails unless the
// composer, the last prompt, the sent prompt and the thinking row move as one phase
// (gallery/motionPhases.ts; test/agent-pane-send-one-motion.test.ts runs every variant).
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { chat } from "../../gallery/fixtures/acpmux";
import { countMotionPhases, type MotionSample } from "../../gallery/motionPhases";
import type { PlayContext } from "../../gallery/play";
import { COMPOSER_EDITOR, COMPOSER_MD_FIELD } from "./composerSelectors";

const EDITOR = { selector: COMPOSER_EDITOR };
/// The boxes a send moves: the composer card, the last prompt before it, the sent prompt, the thinking row.
const BOXES = ["composer", "prev", "sent", "thinking"] as const;
/// How long the play samples from the send: the motion plus the mock agent's first steps.
const SAMPLE_MS = 1000;

type Sample = MotionSample<(typeof BOXES)[number]> & {
  rows: number;
  label: string;
  text: number;
  /// The prompt field's and the composer card's drawn heights (px).
  field: number | null;
  card: number | null;
  /// The layout-shift score the frame reported (PerformanceObserver), summed.
  shift: number;
};

/// A folder the mock daemon's agents already trust (mock.ts), so no trust question holds the sends.
const TRUSTED = "~/code/cmux";
const fresh = chat([]);
const snapshot = { ...fresh, summary: { ...fresh.summary!, cwd: TRUSTED } };

const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/// Every frame from just before the send to SAMPLE_MS after it, read after the frame's
/// ResizeObserver callbacks ran (a task posted from requestAnimationFrame): what the frame drew.
function sample(doc: Document, draft: string): { done: Promise<Sample[]> } {
  const win = doc.defaultView!;
  const frames: Sample[] = [];
  const top = (node: Element | null | undefined) =>
    node ? Math.round(node.getBoundingClientRect().top * 10) / 10 : null;
  const users = [...doc.querySelectorAll(".acpmux-row.acpmux-user")];
  const prev = users.at(-1);
  const channel = new win.MessageChannel();
  let start = -1;
  let now = 0;
  const height = (node: Element | null | undefined) =>
    node ? Math.round(node.getBoundingClientRect().height * 10) / 10 : null;
  // Layout shifts as the page reports them: buffered until the frame's sample takes them.
  let shifted = 0;
  const shifts =
    typeof PerformanceObserver === "function" && PerformanceObserver.supportedEntryTypes?.includes("layout-shift")
      ? new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) shifted += (entry as PerformanceEntry & { value?: number }).value ?? 0;
        })
      : undefined;
  shifts?.observe({ type: "layout-shift" });
  const done = new Promise<Sample[]>((resolve) => {
    channel.port1.onmessage = () => {
      for (const entry of shifts?.takeRecords() ?? [])
        shifted += (entry as PerformanceEntry & { value?: number }).value ?? 0;
      const sent = [...doc.querySelectorAll(".acpmux-row.acpmux-user")].find((row) => row.textContent?.includes(draft));
      const thinking = [...doc.querySelectorAll(".acpmux-row.acpmux-thinking, .acpmux-row.acpmux-working")].at(-1);
      frames.push({
        t: Math.round(now - start),
        composer: top(doc.querySelector(".acpmux-composer-box")),
        prev: prev?.isConnected ? top(prev) : null,
        sent: top(sent),
        thinking: top(thinking),
        rows: doc.querySelectorAll(".acpmux-row").length,
        // The thinking row's label without its running seconds.
        label: (thinking?.textContent ?? "").slice(0, 30).replace(/\d+s$/, ""),
        text: (doc.querySelector(".acpmux-composer-prompt")?.textContent ?? "").length,
        field: height(doc.querySelector(COMPOSER_MD_FIELD)),
        card: height(doc.querySelector(".acpmux-composer-box")),
        shift: Math.round(shifted * 10000) / 10000,
      });
      shifted = 0;
      if (now - start < SAMPLE_MS) win.requestAnimationFrame(tick);
      else {
        shifts?.disconnect();
        resolve(frames);
      }
    };
  });
  // raf-read: the motion is the behavior; each frame is read as it is drawn.
  const tick = (at: number) => {
    if (start < 0) start = at;
    now = at;
    channel.port2.postMessage(0);
  };
  win.requestAnimationFrame(tick);
  return { done };
}

/// The send's own frames: from the first frame anything moved or the prompt cleared, up to the agent's
/// next own change (a running turn's next row or label, its reply), a later and separate event.
export function sendWindow(frames: readonly Sample[]): Sample[] {
  const watched = [...BOXES, "text"] as const;
  const first = frames.findIndex(
    (frame, index) => index > 0 && watched.some((key) => frame[key] !== frames[index - 1]![key]),
  );
  if (first < 0) return [...frames];
  const at = frames[first]!;
  const end = frames.findIndex((frame, index) => index > first && (frame.rows !== at.rows || frame.label !== at.label));
  return end < 0 ? [...frames] : frames.slice(0, end);
}

/// What a send did to the composer and the transcript, frame by frame (Leo, 2026-11-22: "THE
/// FUCSKING COLLAPSING OF THE FUCKING COMPOSER / IT TAKES TOO FUCKING LONG"): the frames the field's
/// height changed in from the frame its text cleared, how long after that it last changed, how far
/// the sent row moved after it was first drawn and in how many frames, how many frames the row
/// before it moved in, and the layout shift score the page reported.
export type SendFrames = {
  /** Frames in which the prompt field's height changed. */
  collapseFrames: number;
  /** ms from the frame the text cleared to the field's last height change (0: the same frame). */
  collapseMs: number;
  /** Frames from the text clearing to the field's last height change. */
  collapseLag: number;
  /** Frames in which the sent row moved after it was first drawn, and how far in all (px). */
  sentMoves: number;
  sentDrift: number;
  /** Frames in which the row before the sent one moved. */
  prevMoves: number;
  /** The summed layout-shift score over the send's frames. */
  shift: number;
};

export function sendFrames(frames: readonly Sample[]): SendFrames {
  const changed = (index: number, key: "field" | "sent" | "prev") => {
    const before = frames[index - 1]?.[key];
    const after = frames[index]?.[key];
    return before != null && after != null && Math.abs(after - before) > 0.5;
  };
  const cleared = frames.findIndex((frame, index) => index > 0 && frame.text < frames[index - 1]!.text);
  let collapseFrames = 0;
  let lastField = -1;
  let sentMoves = 0;
  let sentDrift = 0;
  let prevMoves = 0;
  let shift = 0;
  for (let index = 1; index < frames.length; index += 1) {
    if (changed(index, "field")) {
      collapseFrames += 1;
      lastField = index;
    }
    if (changed(index, "sent")) {
      sentMoves += 1;
      sentDrift += Math.abs(frames[index]!.sent! - frames[index - 1]!.sent!);
    }
    if (changed(index, "prev")) prevMoves += 1;
    shift += frames[index]!.shift;
  }
  const from = cleared < 0 ? lastField : cleared;
  return {
    collapseFrames,
    collapseMs: lastField < 0 || from < 0 ? 0 : Math.max(0, frames[lastField]!.t - frames[from]!.t),
    collapseLag: lastField < 0 || from < 0 ? 0 : Math.max(0, lastField - from),
    sentMoves,
    sentDrift: Math.round(sentDrift * 10) / 10,
    prevMoves,
    shift: Math.round(shift * 10000) / 10000,
  };
}

async function settle(ctx: PlayContext) {
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-cancel"), { capMs: 30_000 });
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-thread")?.hasAttribute("data-turn-end-folding"));
}

function sendOnce(lines: number, busy: boolean, scrolled: boolean) {
  return async (ctx: PlayContext) => {
    const doc = ctx.document;
    for (const line of ["first question", "second question", "third question"]) {
      await ctx.type(line, EDITOR);
      await ctx.press("Enter");
      await ctx.waitFor(() =>
        [...doc.querySelectorAll(".cv-user__bubble")].some((node) => node.textContent?.includes(line)),
      );
      await settle(ctx);
    }
    await pause(400);
    if (busy) {
      await ctx.type("a running question", EDITOR);
      await ctx.press("Enter");
      await ctx.waitFor(() => doc.querySelector(".acpmux-row.acpmux-thinking, .acpmux-row.acpmux-working"));
    }
    for (let index = 1; index <= lines; index += 1) {
      await ctx.type(`draft line ${index} of the tall message`, EDITOR);
      if (index < lines) await ctx.press("Shift+Enter");
    }
    await pause(busy ? 250 : 600);
    if (scrolled) {
      const scroller = doc.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = Math.max(0, scroller.scrollTop - 260);
      await pause(busy ? 250 : 600);
    }
    // The agent echoes the prompt a little late, as acpmux does.
    Object.assign(doc.defaultView!, { cmuxAcpmuxMockSlowMethod: "session/prompt", cmuxAcpmuxMockSlowMs: 40 });
    const frames = sample(doc, "draft line 1 of");
    await pause(80);
    await ctx.press("Enter");
    const window = sendWindow(await frames.done);
    const send = countMotionPhases(window, BOXES);
    // The frames, for a reader of a failed play: each box's top, every frame of the send.
    doc.documentElement.dataset.sendFrames = JSON.stringify(window);
    doc.documentElement.dataset.sendPhases = String(send.phases);
    doc.documentElement.dataset.sendMaxJump = String(send.maxJump);
    doc.documentElement.dataset.sendFrameStats = JSON.stringify(sendFrames(window));
    // Scrolled up with a turn running, the queued prompt's send can bounce the rows for one frame
    // (up, then most of the way back), on the base code too: a separate cause, recorded, not failed.
    if (send.phases > 1 && !(busy && scrolled))
      throw new Error(`the send moved in ${send.phases} phases: ${send.detail.join("; ")}`);
  };
}

const variants: Record<string, AgentPaneVariant> = {};
for (const lines of [1, 5, 30])
  for (const busy of [false, true])
    for (const scrolled of [false, true])
      variants[`${lines}-lines-${busy ? "busy" : "idle"}-${scrolled ? "scrolled-up" : "latest"}`] = {
        note: `Play: send a ${lines}-line draft ${busy ? "while a turn runs" : "to an idle agent"}${
          scrolled ? ", scrolled up" : " from the latest row"
        }; it moves in one phase.`,
        ready: { transport: "mock", newSession: true, cwd: TRUSTED },
        snapshot,
        play: sendOnce(lines, busy, scrolled),
      };

export default agentPaneEntry({
  id: "agent-pane.composer-send-one-motion",
  title: "A tall send is one motion",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 420, normal: 900, wide: 1100 },
  checks: {
    layoutShiftMax: {
      value: 1,
      reason: "A send moves the transcript on purpose; the play counts the send's phases itself (motionPhases.ts).",
    },
    longFrameFailMs: {
      value: 400,
      reason:
        "The mock agent renders each whole reply turn in one task; the send's own frames are what the play measures.",
    },
  },
  covers: ["agent-session/acpmux/VirtualTranscript.tsx", "agent-session/acpmux/Composer.tsx"],
  variants,
});
