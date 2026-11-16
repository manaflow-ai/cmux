// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// The tool-group entry's regroup scenes (ToolGroupSize.gallery.ts): a running turn, the reader
// scrolled up in it, then the agent's next call arrives (a second read after a lone one; a command
// after two reads). Under the runs arm of liveTurnWork.experiment.ts the run regroups ("Read 2
// files") and a call the reader opened stays open and in place (Leo, 2026-11-08: "if i have a tool
// call expanded, the auto folding situation shouldn't collapse it when a new tool call comes in and
// the folds reformat"). These scenes pin the `line` arm, which draws no finished run while the turn runs, only the
// reply and the one live line (turns.ts `codexRuns`), so there is no call to open and nothing to
// regroup in view: these scenes check that the next call, and the turn's end in the group scene,
// move nothing the reader reads. test/pinned-tool-rows-browser.test.ts plays them in Chromium.
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity } from "../model";

const ROW = "pinned-tool-rows-run";
const paragraph = (index: number) =>
  `Note ${index}. The fetch helper retries every failure the same way, so a 404 waits through three ` +
  "backoffs before it fails. I read how the helper decides to retry and who calls it, then where the " +
  "backoff is set and which callers expect a client error to fail at once.";

const head = Array.from({ length: 4 }, (_, index) => [
  user(`Check part ${index + 1} of the retry loop`, 60 - index * 8),
  assistant([paragraph(index * 2 + 1), paragraph(index * 2 + 2)].join("\n\n"), 59 - index * 8),
]).flat();

const read = (id: string, path: string) =>
  tool(`Read ${path}`, "read", "completed", {
    id,
    output: Array.from({ length: 8 }, (_, line) => `${path}:${line + 1}  retry(${line}) // backoff`).join("\n"),
  });
const command = (id: string, line: string) =>
  tool(line, "execute", "completed", { id, command: line, output: `${line}: ok\n`, exitCode: 0 });

/// The reply the agent is writing under the run, long enough that the view can sit away from its end.
const reply = (version: number) =>
  assistant(Array.from({ length: 5 }, (_, index) => paragraph(20 + index)).join("\n\n"), 4, {
    id: "pinned-tool-rows-reply",
    version,
  });

const snapshot = (items: AcpmuxActivity[], version: number, isWorking = true) =>
  chat(
    [
      ...head,
      user("Read the retry code and run its checks", 6),
      activity(items, 5, { id: ROW, version }),
      reply(version),
    ],
    {
      title: "Retry loop",
      isWorking,
    },
  );

type Scene = {
  before: AcpmuxActivity[];
  after: AcpmuxActivity[];
  /// The turn then ends: its work folds once (turnEndFold.ts) and the reply stays in place.
  ends?: true;
  /// The reader reads the text above, the reply 100 px under the view's foot: the next call moves
  /// nothing in view.
  below?: true;
};

/// A lone read; a second read arrives (the runs arm groups them under "Read 2 files").
const lone: Scene = {
  before: [read("pin-c1", "fetch.ts")],
  after: [read("pin-c1", "fetch.ts"), read("pin-c2", "retry.ts")],
};
/// Two reads; a command joins the running turn's run, then the turn ends.
const group: Scene = {
  before: [read("pin-g1", "fetch.ts"), read("pin-g2", "retry.ts")],
  after: [read("pin-g1", "fetch.ts"), read("pin-g2", "retry.ts"), command("pin-g3", "bun test fetch")],
  ends: true,
};

const scroller = (ctx: Parameters<Play>[0]) => ctx.document.querySelector<HTMLElement>(".acpmux-scroll")!;
const fail = (what: string, seen: unknown): never => {
  throw new Error(`${what}: ${JSON.stringify(seen)}`);
};
/// Waits until `ready` holds, every finite animation ended and the offset and height held still for
/// a few frames.
const settle = async (ctx: Parameters<Play>[0], ready: () => boolean = () => true) => {
  let last = "";
  let still = 0;
  await ctx.waitFor(
    () => {
      if (!ready()) return false;
      const running = ctx.document
        .getAnimations()
        .some((each) => each.playState === "running" && each.effect?.getComputedTiming().endTime !== Infinity);
      const node = scroller(ctx);
      const now = `${node.scrollTop}:${node.scrollHeight}`;
      still = !running && now === last ? still + 1 : 0;
      last = now;
      return still >= 6;
    },
    { capMs: 10_000 },
  );
};
/// The reader's wheel brings `line` to `at` px under the view's top; the wheel lets go of any hold.
const bringTo = async (ctx: Parameters<Play>[0], line: HTMLElement, at = 200) => {
  const node = scroller(ctx);
  node.dispatchEvent(new WheelEvent("wheel", { deltaY: -1, bubbles: true }));
  node.scrollTop += line.getBoundingClientRect().top - node.getBoundingClientRect().top - at;
  node.dispatchEvent(new Event("scroll"));
  await settle(ctx);
};

declare global {
  interface Window {
    /** What the regroup scene saw: the reply's top and the view's offset before and after the next call arrived. */
    cmuxPinnedToolRows?: {
      before: number;
      after: number;
      /// Rows of the running turn's run drawn after the next call arrived (the `line` draws none).
      runs: number;
      /// The live line is the turn's last row.
      line: boolean;
      fromEnd: number;
      scrollBefore: number;
      scrollAfter: number;
      /// After the turn ended and its fold played (scenes that end the turn).
      ended?: { after: number; scrollAfter: number };
    };
  }
}

const REPLY = '[data-row-id="pinned-tool-rows-reply"]';
const replyRow = (ctx: Parameters<Play>[0]) => ctx.document.querySelector<HTMLElement>(REPLY);
const runs = (ctx: Parameters<Play>[0]) => ctx.document.querySelectorAll(`[data-row-id="${ROW}"]`).length;
const liveLine = (ctx: Parameters<Play>[0]) =>
  ctx.document.querySelector('.acpmux-row[data-row-id="thinking-live"]') !== null;

/// The scene as live-turn-work `line` (pinned) draws a running turn (liveTurnWork.experiment.ts):
/// the reply in sight, one live line under it, and no finished run, so no call the reader could
/// have opened. The reader reads the reply (or, `below`, the text above it, the reply under the
/// view's foot); the next call arrives and moves nothing in view, and a turn that then ends moves
/// nothing either.
function scene(which: Scene): Play {
  return async (ctx) => {
    const view = ctx.document.defaultView!;
    await ctx.waitFor(() => scroller(ctx) && replyRow(ctx) && liveLine(ctx), { capMs: 10_000 });
    await settle(ctx);
    if (runs(ctx)) fail("the running turn draws its finished run over the live line", runs(ctx));
    await bringTo(ctx, replyRow(ctx)!, which.below ? scroller(ctx).clientHeight + 100 : 200);
    const before = replyRow(ctx)!.getBoundingClientRect().top;
    const scrollBefore = scroller(ctx).scrollTop;
    view.cmuxAcpmuxBridge?.receive(structuredClone(snapshot(which.after, 2)));
    await settle(ctx);
    const node = scroller(ctx);
    const seen: NonNullable<Window["cmuxPinnedToolRows"]> = {
      before,
      after: replyRow(ctx)?.getBoundingClientRect().top ?? Number.NaN,
      runs: runs(ctx),
      line: liveLine(ctx),
      fromEnd: node.scrollHeight - node.clientHeight - node.scrollTop,
      scrollBefore,
      scrollAfter: node.scrollTop,
    };
    view.cmuxPinnedToolRows = seen;
    if (seen.runs) fail("the next call drew the running turn's run", seen);
    if (!seen.line) fail("the live line is gone", seen);
    if (which.below) {
      if (!(Math.abs(seen.scrollAfter - seen.scrollBefore) <= 1))
        fail("the next call under the view moved the text the reader was reading", seen);
    } else if (!(Math.abs(seen.after - seen.before) <= 1)) fail("the next call moved the reply in view", seen);
    if (!which.ends) return;
    // The turn ends: its work folds once (turnEndFold.ts). The view's offset holds and the reply stays
    // drawn. Its top is recorded, not held: under `line` the end draws work that was not on screen
    // above the reply (its Worked for, and the run turnEndHold.ts keeps open for the reply), so the
    // reply moves down by it.
    view.cmuxAcpmuxBridge?.receive(structuredClone(snapshot(which.after, 3, false)));
    await settle(ctx, () => !liveLine(ctx) && !ctx.document.querySelector(".acpmux-thread[data-turn-end-folding]"));
    seen.ended = {
      after: replyRow(ctx)?.getBoundingClientRect().top ?? Number.NaN,
      scrollAfter: scroller(ctx).scrollTop,
    };
    view.cmuxPinnedToolRows = seen;
    if (!(Math.abs(seen.ended.scrollAfter - seen.scrollAfter) <= 1)) fail("the turn's end moved the view", seen);
    if (!Number.isFinite(seen.ended.after)) fail("the reply is gone after the turn's end", seen);
  };
}

/// The arm these scenes are about, pinned so they keep it whatever the default.
const LINE = { "live-turn-work": "line" };

export const pinnedVariants = {
  "pinned-lone": {
    note: "Play: a running turn after a lone read, the reader scrolled up to the reply; a second read arrives. Under live-turn-work `line`, pinned: the reply and the live line, no finished run, and the reply stays where it was.",
    snapshot: snapshot(lone.before, 1),
    play: scene(lone),
    experiments: LINE,
  },
  "pinned-below": {
    note: "Play: the reader scrolled up so the reply sits under the view's foot; a second read arrives. The text in view stays where it is, and no finished run draws.",
    snapshot: snapshot(lone.before, 1),
    play: scene({ ...lone, below: true }),
    experiments: LINE,
  },
  "pinned-group": {
    note: "Play: two reads, then a command joins the running turn and the turn ends. While it runs the reply and the live line show and no finished run; the next call moves nothing in view; at the turn's end the view's offset holds and the reply moves down by the work drawn above it.",
    snapshot: snapshot(group.before, 1),
    play: scene(group),
    experiments: LINE,
  },
};
