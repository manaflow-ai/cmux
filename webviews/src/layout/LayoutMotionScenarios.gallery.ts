// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// The layout-motion contract's scenarios on the agent chat page (schemas/layout-motion/contract.json). Leo,
// 2026-11-18: "I was thinking we'd be able to calculate each beforehand everything that would move and just
// go ok well nothing else usually should and the things that move we only expect at certain times etc ...
// Fundamentally". Each variant is one of the moments he named (load, workspace switch, new workspace,
// split, resize, tab moves) as the page sees it; the stage judges its load and every step against the
// contract (layout/motionJudge.ts), and gallery health fails a move the contract does not declare
// (scripts/gallery-matrix/undeclared-baseline.ts). The native sidebar's half of the table is the sidebar's
// own scenario test.
import { agentPaneEntry } from "../gallery/format";
import { activity, assistant, chat, noChat, summary, tool, user } from "../gallery/fixtures/acpmux";
import type { PlayContext } from "../gallery/play";
import type { AcpmuxRow } from "../agent-session/acpmux/model";

function turn(index: number, minutes: number): AcpmuxRow[] {
  const id = `motion-${index}`;
  return [
    user(`Check package ${index} and fix what fails`, minutes, { id: `${id}-user` }),
    activity(
      [
        tool(`bun test packages/p${index}`, "execute", "completed", {
          id: `${id}-test`,
          command: `bun test packages/p${index}`,
          output: Array.from({ length: 8 }, (_, line) => `  ok ${line + 1} - case ${line + 1}`).join("\n"),
          exitCode: 0,
        }),
        tool(`Read packages/p${index}/src/index.ts`, "read", "completed", { id: `${id}-read` }),
      ],
      minutes - 0.2,
      { id: `${id}-activity` },
    ),
    assistant(
      `Package ${index} passes. The **parser** keeps its cache by file, and \`index.ts\` exports one entry.\n\n- tests: 8 pass\n- lint: clean`,
      minutes - 0.4,
      { id: `${id}-reply` },
    ),
    summary(minutes - 0.5, { id: `${id}-summary`, status: "completed", toolCount: 2, durationMs: 31_000 }),
  ];
}

const finished = () =>
  chat(Array.from({ length: 8 }, (_, index) => turn(index + 1, 60 - index * 6)).flat(), { harness: "codex" });
const SCROLLER = { selector: ".acpmux-scroll" };
const atLatest = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="motion-8-summary"]'));
  await ctx.scroll(SCROLLER, "bottom");
};

type Debug = {
  loadSeed(turns: number, options?: { light?: boolean }): Promise<{ session?: string }>;
  selectSession(sessionId: string): Record<string, unknown>;
};
const debugOf = async (ctx: PlayContext): Promise<Debug> => {
  const view = ctx.document.defaultView as unknown as { cmuxAcpmuxDebug?: Debug };
  await ctx.waitFor(() => view.cmuxAcpmuxDebug !== undefined);
  return view.cmuxAcpmuxDebug!;
};

/** Waits `frames` painted frames, as one measured step: what the page does on its own after an act. */
const settleFrames = (ctx: PlayContext, frames: number) => {
  const view = ctx.document.defaultView!;
  let painted = 0;
  let asked = false;
  return ctx.waitFor(() => {
    if (!asked) {
      asked = true;
      const tick = () => {
        painted += 1;
        if (painted < frames) view.requestAnimationFrame(tick);
      };
      view.requestAnimationFrame(tick);
    }
    return painted >= frames;
  });
};

/** Logs `frames` painted frames from now as `motion-trace` console lines: the scroller and the last turns' rows,
 *  where they drew. Read only when the runner echoes them (CMUX_GALLERY_ECHO_TRACE=1, undeclared-run.sh). */
const trace = (ctx: PlayContext, label: string, frames = 24) => {
  const doc = ctx.document;
  const view = doc.defaultView!;
  let frame = 0;
  const log = (when: string) => {
    const scroller = doc.querySelector<HTMLElement>(".acpmux-scroll");
    const rows = [...doc.querySelectorAll<HTMLElement>("[data-row-id]")]
      .filter((row) => /motion-(7|8)-/.test(row.dataset.rowId ?? ""))
      .map((row) => {
        const box = row.getBoundingClientRect();
        return `${row.dataset.rowId}:${box.top.toFixed(1)}/${box.height.toFixed(1)}`;
      });
    console.log(
      `motion-trace ${label} f${frame}${when} t${view.performance.now().toFixed(0)} w${scroller?.clientWidth} st${scroller?.scrollTop.toFixed(1)} sh${scroller?.scrollHeight} ${rows.join(" ")}`,
    );
  };
  // Each frame twice: in its callback (before its layout and ResizeObserver passes) and once it has drawn.
  const drawn = new MessageChannel();
  drawn.port1.onmessage = () => {
    log("d");
    frame += 1;
    if (frame < frames) view.requestAnimationFrame(tick);
    else drawn.port1.close();
  };
  const tick = () => {
    log("r");
    drawn.port2.postMessage(0);
  };
  tick();
};
/** The page leaves view and comes back, as a tab dragged to another pane does. */
const setVisible = (ctx: PlayContext, visible: boolean) => {
  const doc = ctx.document;
  Object.defineProperty(doc, "visibilityState", { configurable: true, get: () => (visible ? "visible" : "hidden") });
  Object.defineProperty(doc, "hidden", { configurable: true, get: () => !visible });
  doc.dispatchEvent(new Event("visibilitychange"));
};

export default agentPaneEntry({
  id: "layout.motion-scenarios",
  title: "Layout motion contract: load, switch, new workspace, split, resize, tab move",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 520, normal: 760, wide: 760 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: ["layout/motionContract.ts", "layout/motionJudge.ts", "layout/boxSample.ts", "agent-session/acpmux/App.tsx"],
  checks: {
    longFrameFailMs: {
      value: 250,
      reason:
        "This entry judges layout moves; opening and switching seeded chats on the mock daemon takes long frames the open benches own.",
    },
    layoutShiftMax: {
      value: 1,
      reason:
        "This entry is judged by the layout-motion contract (undeclared moves, gallery health), not the per-step CLS limit.",
    },
  },
  variants: {
    load: {
      note: "Opening a finished chat: every row and the composer draw at their final place and size, then hold still.",
      snapshot: finished(),
    },
    "workspace-switch": {
      note: "Play: two long chats on the mock daemon; switch from the second back to the first, as a workspace switch shows its chat. The chat that opens draws once.",
      ready: { transport: "mock" },
      snapshot: chat([]),
      play: async (ctx) => {
        const debug = await debugOf(ctx);
        let first: string | undefined;
        let second: string | undefined;
        void debug.loadSeed(40, { light: true }).then((answer) => (first = answer.session));
        await ctx.waitFor(() => first !== undefined, { capMs: 30_000 });
        void debug.loadSeed(40, { light: true }).then((answer) => (second = answer.session));
        await ctx.waitFor(() => second !== undefined, { capMs: 30_000 });
        debug.selectSession(first!);
        await settleFrames(ctx, 30);
      },
    },
    "new-workspace": {
      note: "Play: a new workspace's chat, from its empty page to the sent prompt and the streamed reply. The composer holds; the reply grows at the end (a declared stream append).",
      ready: { transport: "mock", newSession: true },
      snapshot: noChat([]),
      play: async (ctx) => {
        const doc = ctx.document;
        await ctx.waitFor(() => doc.querySelector(".acpmux-model"));
        await ctx.type("what can you do?", { selector: ".acpmux-md" });
        ctx.declare("stream-append");
        await ctx.press("Enter");
        await ctx.waitFor(() => doc.querySelector(".cv-md"), { capMs: 10_000 });
        await settleFrames(ctx, 30);
      },
    },
    split: {
      note: "Play: the pane is split, so the chat has half the width, then the split closes. Each box moves once per resize, with no bounce, and nothing moves after.",
      snapshot: finished(),
      play: async (ctx) => {
        await atLatest(ctx);
        trace(ctx, "split-380");
        await ctx.resize(380);
        await settleFrames(ctx, 20);
        trace(ctx, "split-760");
        await ctx.resize(760);
        await settleFrames(ctx, 20);
      },
    },
    resize: {
      note: "Play: the window is dragged narrower and wider in steps. Each step lays every box out once; nothing moves between steps.",
      snapshot: finished(),
      play: async (ctx) => {
        await atLatest(ctx);
        for (const width of [700, 640, 580, 640, 700, 760]) await ctx.resize(width);
        await settleFrames(ctx, 20);
      },
    },
    "tab-move": {
      note: "Play: the chat's tab moves to another pane: the page leaves view, comes back at the other pane's width, and holds still from its first frame back.",
      snapshot: finished(),
      play: async (ctx) => {
        await atLatest(ctx);
        setVisible(ctx, false);
        (ctx.document.defaultView as unknown as { cmuxMotionTrace?: boolean }).cmuxMotionTrace = true;
        trace(ctx, "tab-520", 40);
        await ctx.resize(520);
        setVisible(ctx, true);
        await settleFrames(ctx, 30);
      },
    },
  },
});
