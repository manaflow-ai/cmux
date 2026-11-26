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
import type { LoadToolsOptions } from "../agent-session/acpmux/loadDebug";

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
  // The debug hook's own options type, never a copy of its shape: a hand-copied one drifted the moment
  // `reply` was added to it (loadDebug.ts), and the gallery saw a type error instead of the option.
  loadTools(options?: LoadToolsOptions): Promise<Record<string, unknown>>;
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
    const nodes = [...doc.querySelectorAll<HTMLElement>("[data-row-id]")];
    // The snapshot fixtures' last two turns (`motion-7`, `motion-8`); a seeded mock chat names its
    // rows otherwise (`user-354`), so there take the top of the mounted window and the end.
    const picked = nodes.filter((row) => /motion-(7|8)-/.test(row.dataset.rowId ?? ""));
    const rows = (picked.length > 0 ? picked : [...nodes.slice(0, 3), ...nodes.slice(-5)]).map((row) => {
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
/** Waits off the harness's measured steps: every `ctx.waitFor` and `ctx.scroll` is a step the stage
 *  judges, so a scenario's *setup* is judged as if it were the scenario. Opening a seeded chat in an
 *  empty pane moves the composer and the rows once as it arrives (the contract's `load`, which no web
 *  surface declares; the same 10 boxes move on `workspace-switch`, whose scenario that arrival is). What
 *  these scenarios are about is a turn's end, so the setup waits here and the end is the measured step. */
const quietly = (ctx: PlayContext, condition: () => boolean, capMs = 30_000): Promise<void> => {
  const view = ctx.document.defaultView!;
  return new Promise((resolve, reject) => {
    const until = view.performance.now() + capMs;
    const tick = () => {
      if (condition()) resolve();
      else if (view.performance.now() > until) reject(new Error("the scenario's setup never arrived"));
      else view.requestAnimationFrame(tick);
    };
    tick();
  });
};

/** `frames` painted frames, off the measured steps (`quietly`): the page settling after a setup act. */
const quietFrames = (ctx: PlayContext, frames: number): Promise<void> => {
  const view = ctx.document.defaultView!;
  let painted = 0;
  const tick = () => {
    painted += 1;
    if (painted < frames) view.requestAnimationFrame(tick);
  };
  view.requestAnimationFrame(tick);
  return quietly(ctx, () => painted >= frames, 1_000 + frames * 250);
};

/** The view to the latest row, off the measured steps (the stage's own `ctx.scroll` is one). */
const toLatest = (ctx: PlayContext): void => {
  const scroller = ctx.document.querySelector<HTMLElement>(SCROLLER.selector);
  if (!scroller) return;
  scroller.scrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
  scroller.dispatchEvent(new Event("scroll", { bubbles: false }));
};

/** Opens one seeded mock chat and lets every box rest, so what moves after is judged. A box that has
 *  not drawn twice in the same place is still mounting (the contract's `load`), so the rest comes first.
 *  All of it is setup, so none of it is a measured step (`quietly`). */
const seededChat = async (ctx: PlayContext, turns = 40): Promise<Debug> => {
  const debug = await debugOf(ctx);
  let session: string | undefined;
  void debug.loadSeed(turns, { light: true }).then((answer) => (session = answer.session));
  await quietly(ctx, () => session !== undefined);
  await quietFrames(ctx, 8);
  toLatest(ctx);
  await quietFrames(ctx, 24);
  // The last rows settle to their measured heights as they draw, which moves the pinned bottom: take
  // the view to the latest row once more, and only then is the chat at the rest the end is judged from.
  toLatest(ctx);
  await quietFrames(ctx, 12);
  return debug;
};

/** Runs `act` on the next painted frame. A mock emit on the calling tick lands before the step that
 *  is meant to measure it has started sampling, and the change it makes goes unjudged. */
const onNextFrame = (ctx: PlayContext, act: () => void): void => {
  ctx.document.defaultView!.requestAnimationFrame(() => act());
};

/** The turn runs: its prompt and its calls arrive at the transcript's end and the view follows them
 *  down (`stream-append`, which the pane declares itself while it works: devMotionAudit.ts). Left
 *  open, so the *end* is the act the next step measures, and settled, so the end is judged from rest. */
const runningTurn = async (ctx: PlayContext, debug: Debug, options: LoadToolsOptions): Promise<void> => {
  await debug.loadTools({ ...options, keep_open: true });
  await quietFrames(ctx, 24);
};

/** The turn ends, as one measured step. The swap is started and *not* awaited, so it lands while the
 *  stage's tracker is sampling: the fold declares its own motion (turnEndFold.ts `declareMove`, event
 *  `turn-end`, strict) and every other box that moves is undeclared. Awaiting it instead -- what the
 *  scenarios did first -- ran the whole end between two steps, where nothing judges it, and the zero
 *  that read like a pass meant only that nothing was watching. */
const endingTurn = async (ctx: PlayContext, debug: Debug): Promise<void> => {
  const thread = () => ctx.document.querySelector(".acpmux-thread")?.innerHTML ?? "";
  const live = thread();
  onNextFrame(ctx, () => void debug.loadTools({ count: 0, keep_open: false }));
  await settleFrames(ctx, 40);
  // A step that drew the same thread it started with never saw the end, and its zero would say only
  // that nothing was watching -- the shape three of these scenarios had before. The end always changes
  // the live turn's rows (its spinner, its fold); whether anything *moves* is what the judge decides.
  if (thread() === live) throw new Error("the turn's end did not land inside the measured step");
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
  title: "Layout motion contract: load, switch, new workspace, split, resize, tab move, turn end",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 520, normal: 760, wide: 760 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: [
    "layout/motionContract.ts",
    "layout/motionJudge.ts",
    "layout/boxSample.ts",
    "agent-session/acpmux/App.tsx",
    "agent-session/acpmux/devMotionAudit.ts",
    "agent-session/acpmux/conversation/turnEndFold.ts",
  ],
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
    // The turn's end, the moment Leo kept finding by eye (2026-11-22: "IT FUCKING JUMPS ... WHEN A TURN BY AN
    // AGENT END / STOP ADDING FUCKING DINGLEBERRIES OF TOOL CALLS AND BULLSHIT THAT SHIFTS POORLY. IF IT NEEDS
    // TO SHIFT, IT SHIFTS MOTHERFUCKING GRACEFULLY"). The judge had every other moment of the page and not this
    // one, so the only detector for it was him.
    "turn-end": {
      note: "Play: a turn ends at the bottom of a followed transcript. Its fold is the one declared move; no row above it, and no box outside it, shifts.",
      ready: { transport: "mock" },
      snapshot: chat([]),
      play: async (ctx) => {
        const debug = await seededChat(ctx);
        await runningTurn(ctx, debug, { count: 0 });
        trace(ctx, "turn-end", 40);
        await endingTurn(ctx, debug);
      },
    },
    "turn-end-tools": {
      note: "Play: three trailing tool calls arrive and then the turn ends, as Leo's recording shows. Each call enters at the end (the contract's `enter`: nothing else moves because of it) and the end's fold is the one declared move.",
      ready: { transport: "mock" },
      snapshot: chat([]),
      play: async (ctx) => {
        const debug = await seededChat(ctx);
        await runningTurn(ctx, debug, { count: 3, gap_ms: 60 });
        trace(ctx, "turn-end-tools", 40);
        await endingTurn(ctx, debug);
      },
    },
    // The shape the fix is about: the turn ends on an answer that carries a tagged ask, so the card
    // only a concluded turn used to draw is in play. On base it is appended at the swap at its full
    // height and the pinned bottom lifts every row above it (37.75px on the unit test's fixture); the
    // variants that end on calls alone never reach that row, which is how the judged scenario missed it.
    "turn-end-ask": {
      note: "Play: trailing tool calls arrive, then the turn ends on an answer that carries a tagged ask. The ask's card is drawn while the turn still runs, so the end appends nothing; the fold is the one declared move.",
      ready: { transport: "mock" },
      snapshot: chat([]),
      play: async (ctx) => {
        const debug = await seededChat(ctx);
        await runningTurn(ctx, debug, {
          count: 3,
          gap_ms: 60,
          reply: [
            "Landed the fix and the gate is green.",
            "",
            "- **[taste]** Should the fold keep the old look?",
            "  - Keep it",
            "  - Use the new one",
          ].join("\n"),
        });
        (ctx.document.defaultView as unknown as { cmuxMotionTrace?: boolean }).cmuxMotionTrace = true;
        trace(ctx, "turn-end-ask", 40);
        await endingTurn(ctx, debug);
      },
    },
    "turn-end-scrolled-away": {
      note: "Play: the reader is scrolled up into the finished turns while trailing calls arrive and the turn ends. The view follows nothing, so on screen nothing may move at all.",
      ready: { transport: "mock" },
      snapshot: chat([]),
      play: async (ctx) => {
        const debug = await seededChat(ctx);
        const scroller = ctx.document.querySelector<HTMLElement>(SCROLLER.selector)!;
        // Up into the finished turns, far enough that the turn's end is off screen but rows stay in view
        // above and below: the reader is reading, not following the end. A setup act, so it is no
        // measured step of its own (`quietly`) and needs no `user-scroll` declaration.
        scroller.scrollTop = Math.max(0, scroller.scrollHeight - scroller.clientHeight - 1200);
        scroller.dispatchEvent(new Event("scroll", { bubbles: false }));
        await quietFrames(ctx, 24);
        // Away from the end the pane declares nothing (`stream-append` is open only while the view
        // follows it: devMotionAudit.ts), so the calls arriving below the view are judged too.
        trace(ctx, "turn-end-away", 60);
        onNextFrame(ctx, () => void debug.loadTools({ count: 3, gap_ms: 60, keep_open: true }));
        await settleFrames(ctx, 40);
        await endingTurn(ctx, debug);
      },
    },
  },
});
