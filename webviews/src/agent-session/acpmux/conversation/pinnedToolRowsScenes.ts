// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// The tool-group entry's regroup scenes (ToolGroupSize.gallery.ts): a running turn, the reader
// scrolled up to a call and opened it, then the agent's next call arrives (a second read groups a
// lone one under "Read 2 files"; a command joins the run). The call stays open and stays where it
// was on screen (Leo, 2026-11-08: "if i have a tool call expanded, the auto folding situation
// shouldn't collapse it when a new tool call comes in and the folds reformat"). A running turn
// never folds its run into a line (turns.ts `codexRuns`, cmux#38339): the group scene ends the turn
// too, and the call stays open and in place through the turn's end fold (turnEndFold.ts, the rows
// in the parked reader's view held open by turnEndHold.ts). test/pinned-tool-rows-browser.test.ts
// plays them in Chromium.
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
  opens: string[];
  call: string;
  /// The line of the group or run that holds the call once the next call arrived.
  line: RegExp;
  /// The turn then ends: its run folds once (turnEndFold.ts) and the opened call stays open and in place.
  ends?: true;
  /// The reader reads the text above, the opened call 100 px under the view's foot (its row still
  /// drawn): the regroup moves the call, never the view.
  below?: true;
};

/// A lone read the reader opened; a second read groups it under "Read 2 files".
const lone: Scene = {
  before: [read("pin-c1", "fetch.ts")],
  after: [read("pin-c1", "fetch.ts"), read("pin-c2", "retry.ts")],
  opens: [],
  call: "pin-c1",
  line: /^Read 2 files$/,
};
/// "Read 2 files" opened, its first read opened; a command joins the running turn's run (its group
/// stays "Read 2 files": a running turn never folds the run into one line), then the turn ends.
const group: Scene = {
  before: [read("pin-g1", "fetch.ts"), read("pin-g2", "retry.ts")],
  after: [read("pin-g1", "fetch.ts"), read("pin-g2", "retry.ts"), command("pin-g3", "bun test fetch")],
  opens: ["Read 2 files"],
  call: "pin-g1",
  line: /^Read 2 files$/,
  ends: true,
};

const scroller = (ctx: Parameters<Play>[0]) => ctx.document.querySelector<HTMLElement>(".acpmux-scroll")!;
const call = (ctx: Parameters<Play>[0], id: string) =>
  ctx.document.querySelector<HTMLElement>(`[data-row-id="${ROW}"] button[data-tool-id="${id}"]`);
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
    /** What the regroup scene saw: the opened call's top before and after the next call arrived. */
    cmuxPinnedToolRows?: {
      before: number;
      after: number;
      open: boolean;
      line: boolean;
      fromEnd: number;
      scrollBefore: number;
      scrollAfter: number;
      /// After the turn ended and its fold played (scenes that end the turn).
      ended?: { after: number; open: boolean; scrollAfter: number };
    };
  }
}

function scene(which: Scene): Play {
  return async (ctx) => {
    const view = ctx.document.defaultView!;
    await ctx.waitFor(() => scroller(ctx) && ctx.document.querySelector(`[data-row-id="${ROW}"]`), { capMs: 10_000 });
    await settle(ctx);
    for (const words of which.opens) {
      const line = [...ctx.document.querySelectorAll<HTMLElement>(`[data-row-id="${ROW}"] button.is-run`)].find(
        (each) => each.textContent?.includes(words),
      );
      if (!line) fail(`no line "${words}"`, ctx.document.querySelector(`[data-row-id="${ROW}"]`)?.textContent);
      await bringTo(ctx, line!);
      if (line!.getAttribute("aria-expanded") !== "true") {
        line!.click();
        await settle(ctx, () => line!.getAttribute("aria-expanded") === "true");
      }
    }
    await ctx.waitFor(() => call(ctx, which.call), { capMs: 10_000 });
    await bringTo(ctx, call(ctx, which.call)!);
    call(ctx, which.call)!.click();
    await settle(ctx, () => call(ctx, which.call)?.getAttribute("aria-expanded") === "true");
    // The reader's wheel again: the click's own hold is over, the view is theirs.
    await bringTo(ctx, call(ctx, which.call)!, which.below ? scroller(ctx).clientHeight + 100 : 200);
    if (which.below && !call(ctx, which.call)) fail("the opened call's row is not drawn under the view", {});
    const before = call(ctx, which.call)!.getBoundingClientRect().top;
    const scrollBefore = scroller(ctx).scrollTop;
    view.cmuxAcpmuxBridge?.receive(structuredClone(snapshot(which.after, 2)));
    const regrouped = () =>
      [...ctx.document.querySelectorAll(`[data-row-id="${ROW}"] button.is-run`)].some((each) =>
        which.line.test(each.querySelector(".cv-tool__summary")?.textContent?.trim() ?? ""),
      );
    // A scene whose group keeps its line (the command joins the running run) waits for the new call itself.
    const next = which.after.at(-1)!.tool!.id;
    const arrived = () =>
      regrouped() &&
      (!which.ends || ctx.document.querySelector(`[data-row-id="${ROW}"] [data-tool-id="${next}"]`) !== null);
    await settle(ctx, arrived);
    const node = scroller(ctx);
    const opened = call(ctx, which.call);
    const seen: NonNullable<Window["cmuxPinnedToolRows"]> = {
      before,
      after: opened?.getBoundingClientRect().top ?? Number.NaN,
      open: opened?.getAttribute("aria-expanded") === "true",
      line: regrouped(),
      fromEnd: node.scrollHeight - node.clientHeight - node.scrollTop,
      scrollBefore,
      scrollAfter: node.scrollTop,
    };
    view.cmuxPinnedToolRows = seen;
    if (!seen.open) fail("the opened call closed when the next call arrived", seen);
    if (which.below) {
      if (!(Math.abs(seen.scrollAfter - seen.scrollBefore) <= 1))
        fail("a regroup under the view moved the text the reader was reading", seen);
    } else if (!(Math.abs(seen.after - seen.before) <= 1))
      fail("the opened call moved when the next call arrived", seen);
    if (!which.ends) return;
    // The turn ends: its work folds once (turnEndFold.ts), and the call the reader opened, in their
    // view, stays open and where it was.
    view.cmuxAcpmuxBridge?.receive(structuredClone(snapshot(which.after, 3, false)));
    await settle(
      ctx,
      () =>
        !ctx.document.querySelector('[data-row-id="thinking-live"]') &&
        !ctx.document.querySelector(".acpmux-thread[data-turn-end-folding]"),
    );
    const ended = call(ctx, which.call);
    seen.ended = {
      after: ended?.getBoundingClientRect().top ?? Number.NaN,
      open: ended?.getAttribute("aria-expanded") === "true",
      scrollAfter: scroller(ctx).scrollTop,
    };
    view.cmuxPinnedToolRows = seen;
    if (!seen.ended.open) fail("the opened call closed when the turn ended", seen);
    if (!(Math.abs(seen.ended.after - seen.before) <= 1)) fail("the opened call moved when the turn ended", seen);
  };
}

export const pinnedVariants = {
  "pinned-lone": {
    note: "Play: a running turn, scrolled up to a lone read the reader opened; a second read arrives and groups it under “Read 2 files”. The read stays open and stays where it was.",
    snapshot: snapshot(lone.before, 1),
    play: scene(lone),
  },
  "pinned-below": {
    note: "Play: a lone read the reader opened, then scrolled up so it sits under the view's foot; a second read groups it. The text in view stays where it is.",
    snapshot: snapshot(lone.before, 1),
    play: scene({ ...lone, below: true }),
  },
  "pinned-group": {
    note: "Play: “Read 2 files” opened and its first read opened; a command joins the running turn, then the turn ends and its run folds. The group and the read stay open and the read stays where it was.",
    snapshot: snapshot(group.before, 1),
    play: scene(group),
  },
};
