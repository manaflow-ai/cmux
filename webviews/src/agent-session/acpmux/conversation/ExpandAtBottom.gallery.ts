// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// Opening and closing a line with the transcript at its very bottom. A long chat whose last turn ran
// two commands under "Ran 2 commands" and wrote a short reply after them, scrolled to its end.
// Opening the group there grows down, as Codex opens a call at the end of a chat (Lucas, 2026-11-06,
// Codex parity): the line and the text above it stay where the reader clicked, what opens goes under
// the composer, and the view stops following (VirtualTranscript.tsx `beginBottomStackFold`). This
// replaces the bottom pin on open (Leo, 2026-11-02). Anywhere else the line also stays put and its
// body grows down (transcript-expand-at-bottom.test.ts). Closing at the very bottom still pulls the
// text above down and leaves no blank room under the rows (Leo, 2026-11-03: "it's weird to collapse
// and get all that empty space at the bottom").
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";

const command = (description: string, line: string, output: string) =>
  tool(line, "execute", "completed", { command: line, description, output, exitCode: 0 });

const paragraph = (index: number) =>
  `Step ${index}. The fetch helper retries every failure the same way, so a 404 waits through three ` +
  "backoffs before it fails. I read how the helper decides to retry and who calls it.";

const earlier = Array.from({ length: 6 }, (_, index) => {
  const minutes = 60 - index * 8;
  return [
    user(`Check part ${index + 1} of the retry loop`, minutes),
    assistant([paragraph(index * 2 + 1), paragraph(index * 2 + 2)].join("\n\n"), minutes - 1),
  ];
}).flat();

const log = Array.from({ length: 12 }, (_, index) => `ok ${index + 1} - fetch retries case ${index + 1}`).join("\n");

/// A finished turn that ran a command, above the last one: its "Worked for" line stays closed.
const middle = [
  user("Find the retry helper", 12),
  activity([command("Find the retry helper", "rg -n fetchWithRetry src", log)], 11, { id: "expand-mid-run" }),
  assistant(paragraph(13), 10),
  summary(9.9, { status: "completed", durationMs: 9_000, toolCount: 1 }),
];

const rows = [
  ...earlier,
  ...middle,
  user("Run the fetch tests and show me the log", 6),
  activity(
    [command("Run the fetch tests", "bun test fetch", log), command("Show the test log", "tail -n 12 fetch.log", log)],
    5,
    { id: "expand-at-bottom-run" },
  ),
  assistant("All twelve fetch cases pass.", 4),
  summary(3.9, { status: "completed", durationMs: 21_000, toolCount: 2 }),
];

/// The same chat ending on a long prompt cut to its first lines, with "Show more" under it, and a
/// short reply: a line that is not a tool's, opened at the bottom.
const LONG_PROMPT = Array.from(
  { length: 18 },
  (_, index) => `${index + 1}. Check that case ${index + 1} of the fetch retries fails fast on a client error.`,
).join("\n");
const promptRows = [
  ...earlier,
  user(LONG_PROMPT, 6),
  assistant("All eighteen cases fail fast now.", 4),
  summary(3.9, { status: "completed", durationMs: 21_000, toolCount: 0 }),
];

/// Opens the last turn's "Worked for" line when the turn folded its run under one, then puts the
/// view at the transcript's very bottom, as the reader leaves it after reading the reply.
const atBottom: Play = async (ctx) => {
  const worked = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-1);
  const group = () =>
    [...ctx.document.querySelectorAll<HTMLButtonElement>("button.cv-tool.is-toggle[aria-expanded]")].find((node) =>
      /2/.test(node.textContent ?? ""),
    );
  await ctx.waitFor(() => worked() ?? group() ?? ctx.document.querySelector(".cv-user__more"), { capMs: 10_000 });
  if (!group() && worked()?.getAttribute("aria-expanded") === "false") {
    worked()!.click();
    await ctx.waitFor(group, { capMs: 10_000 });
  }
  // As the reader's wheel does: it lets go of the line the Worked for click held (`toEnd` below).
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
  if (!scroller) return;
  scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
  scroller.scrollTop = scroller.scrollHeight;
  scroller.dispatchEvent(new Event("scroll"));
};

/// The same chat whose last turn ran a command with a long log, as Leo's Shell card at the bottom.
const tallLog = Array.from({ length: 40 }, (_, index) => `ok ${index + 1} - fetch retries case ${index + 1}`).join(
  "\n",
);
const tallRows = [
  ...earlier,
  ...middle,
  user("Run every fetch test and show me the whole log", 6),
  activity(
    [command("Run the fetch tests", "bun test fetch", log), command("Show the whole log", "cat fetch.log", tallLog)],
    5,
    { id: "expand-at-bottom-run" },
  ),
  assistant("All forty fetch cases pass.", 4),
  summary(3.9, { status: "completed", durationMs: 21_000, toolCount: 2 }),
];

const GROUP = '[data-row-id="expand-at-bottom-run"] button.cv-tool.is-toggle[aria-expanded]';
const scroller = (ctx: Parameters<Play>[0]) => ctx.document.querySelector<HTMLElement>(".acpmux-scroll")!;
/// Where the reader sees the bottom: the last row's foot, how far the view is from its end, the
/// scroller's height, and the top of `line`.
const measure = (ctx: Parameters<Play>[0], line?: HTMLElement) => {
  const node = scroller(ctx);
  const rows = [...node.querySelectorAll<HTMLElement>(".acpmux-row")];
  return {
    lastFoot: rows.at(-1)!.getBoundingClientRect().bottom,
    fromEnd: node.scrollHeight - node.clientHeight - node.scrollTop,
    scrollHeight: node.scrollHeight,
    scrollTop: node.scrollTop,
    line: line?.getBoundingClientRect().top ?? 0,
  };
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
/// Clicks `line` and waits until it says `expanded` and the transcript settled.
const toggleAndSettle = async (ctx: Parameters<Play>[0], line: HTMLElement, expanded: "true" | "false") => {
  line.click();
  await settle(ctx, () => line.getAttribute("aria-expanded") === expanded);
};
const expect = (ok: boolean, what: string, seen: unknown) => {
  if (!ok) throw new Error(`${what}: ${JSON.stringify(seen)}`);
};
const pinned = (before: ReturnType<typeof measure>, after: ReturnType<typeof measure>, what: string) => {
  expect(after.fromEnd <= 2, `${what}: the view left its end`, { before, after });
  expect(Math.abs(after.lastFoot - before.lastFoot) <= 2, `${what}: the last row's foot moved`, { before, after });
};
/// Puts the view back at its very end, as the reader's wheel does, and waits for it to hold still. The
/// wheel lets go of the line the last click held (VirtualTranscript `release`); a scroll from code
/// alone would be put back on it.
const toEnd = async (ctx: Parameters<Play>[0]) => {
  const node = scroller(ctx);
  node.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
  node.scrollTop = node.scrollHeight;
  node.dispatchEvent(new Event("scroll"));
  await settle(ctx);
};

/// At the bottom: opens "Ran 2 commands". The line and the view stay where they were, and what
/// opened grows down under the composer, so the view is no longer at its end.
const expandAtBottom: Play = async (ctx) => {
  await atBottom(ctx);
  await settle(ctx);
  const group = ctx.document.querySelector<HTMLElement>(GROUP)!;
  const before = measure(ctx, group);
  expect(before.fromEnd <= 2, "not at the bottom before the click", before);
  await toggleAndSettle(ctx, group, "true");
  const after = measure(ctx, group);
  expect(Math.abs(after.line - before.line) <= 1, "opening at the bottom moved the line", { before, after });
  expect(Math.abs(after.scrollTop - before.scrollTop) <= 1, "opening at the bottom moved the view", { before, after });
  expect(after.scrollHeight > before.scrollHeight + 40, "opening at the bottom grew nothing down", { before, after });
  expect(after.fromEnd > 40, "opening at the bottom kept the view at its end", { before, after });
};

/// At the bottom: opens the group and its last command (a Shell card with its output), goes back to
/// the very end, then closes the command. The text above comes down by what closed; no blank room is
/// left under the rows.
const collapseAtBottom: Play = async (ctx) => {
  await expandAtBottom(ctx);
  const command = [
    ...ctx.document.querySelectorAll<HTMLElement>(
      '[data-row-id="expand-at-bottom-run"] button.cv-tool.is-toggle[aria-expanded="false"]',
    ),
  ].at(-1)!;
  await toggleAndSettle(ctx, command, "true");
  await toEnd(ctx);
  const before = measure(ctx, command);
  expect(before.fromEnd <= 2, "not at the bottom after opening the command", before);
  await toggleAndSettle(ctx, command, "false");
  const after = measure(ctx, command);
  pinned(before, after, "closing at the bottom");
  expect(after.scrollHeight < before.scrollHeight - 40, "closing at the bottom kept the room", { before, after });
  expect(after.line - before.line > 40, "closing at the bottom did not bring the line down", { before, after });
};

/// At the bottom: opens the group and its tall command, then closes the whole group.
const collapseTallGroup: Play = async (ctx) => {
  await atBottom(ctx);
  await settle(ctx);
  const group = ctx.document.querySelector<HTMLElement>(GROUP)!;
  await toggleAndSettle(ctx, group, "true");
  const command = [
    ...ctx.document.querySelectorAll<HTMLElement>(
      '[data-row-id="expand-at-bottom-run"] button.cv-tool.is-toggle[aria-expanded="false"]',
    ),
  ].at(-1)!;
  await toggleAndSettle(ctx, command, "true");
  await toEnd(ctx);
  const before = measure(ctx, group);
  expect(before.fromEnd <= 2, "not at the bottom with the tall group open", before);
  await toggleAndSettle(ctx, group, "false");
  const after = measure(ctx, group);
  pinned(before, after, "closing a tall group at the bottom");
  expect(after.scrollHeight < before.scrollHeight - 200, "closing the tall group kept the room", { before, after });
};

/// Away from the bottom: an earlier turn's "Worked for" line opens down and stays where it was.
const expandAway: Play = async (ctx) => {
  await atBottom(ctx);
  await settle(ctx);
  const node = scroller(ctx);
  const line = [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-2)!;
  node.scrollTop += line.getBoundingClientRect().top - node.getBoundingClientRect().top - 160;
  await ctx.waitFor(() => Math.abs(line.getBoundingClientRect().top - node.getBoundingClientRect().top - 160) <= 2, {
    capMs: 10_000,
  });
  const before = measure(ctx, line);
  expect(before.fromEnd > 40, "the line is not away from the bottom", before);
  await toggleAndSettle(ctx, line, "true");
  const after = measure(ctx, line);
  expect(Math.abs(after.line - before.line) <= 1, "away from the bottom the line moved", { before, after });
  expect(Math.abs(after.scrollTop - before.scrollTop) <= 1, "away from the bottom the view moved", { before, after });
  expect(after.scrollHeight > before.scrollHeight + 20, "away from the bottom nothing grew down", { before, after });
};

/// The running-chat scenes were checked under live-turn-work `line` (a stretch still running draws
/// no run); they pin it so they keep that look whatever the default.
const RUNNING_ARM = { "live-turn-work": "line" };

/// A chat still working at the bottom, its first two commands done under "Ran 2 commands" (Leo,
/// 2026-11-06, on a recording under load: "the entire tool call expansion apparatus is borked" and
/// "way too discontinuous"). Their stretch ended with its summary: under the live-turn-work
/// `line` a stretch still running draws none of its runs, only the live line (turns.ts
/// `codexRuns`), so the run the reader opens is an ended stretch's. Opening the group while the agent
/// goes on: its next command lands mid-fold, on the live line. `cmuxGalleryArrive` (set by the play)
/// delivers that next snapshot as acpmux would, so a frame test can land it on any frame of the fold
/// (transcript-expand-under-load.test.ts).
const runningHead = [...earlier, ...middle, user("Run the fetch tests and show me the log", 6)];
const runCommands = [
  command("Run the fetch tests", "bun test fetch", log),
  command("Show the test log", "tail -n 12 fetch.log", log),
];
const slowCommand = tool("bun test fetch --slow", "execute", "in_progress", {
  command: "bun test fetch --slow",
  description: "Run the slow case",
});
const reply = assistant("Two runs pass; checking the slow case next.", 4, { id: "expand-at-bottom-reply" });
const ran = [
  ...runningHead,
  activity(runCommands, 5, { id: "expand-at-bottom-run" }),
  reply,
  summary(3.9, { status: "completed", durationMs: 21_000, toolCount: 2 }),
];
const runningSnapshot = chat(ran, { title: "Fetch tests", isWorking: true });
const arrivedSnapshot = chat([...ran, activity([slowCommand], 3.8, { id: "expand-at-bottom-next" })], {
  title: "Fetch tests",
  isWorking: true,
});

declare global {
  interface Window {
    /** The under-load scene's next snapshot: the agent's next command, on the live line. */
    cmuxGalleryArrive?: () => void;
  }
}

/// At the bottom of the working chat, with the next snapshot armed for the test to deliver. An ended
/// stretch keeps its run open while the chat works (turns.ts `codexRuns`), so the reader has shut it
/// first, at the very bottom, and gone back to the end.
const armUnderLoad: Play = async (ctx) => {
  await atBottom(ctx);
  await settle(ctx);
  const group = ctx.document.querySelector<HTMLElement>(GROUP);
  if (group?.getAttribute("aria-expanded") === "true") {
    await toggleAndSettle(ctx, group, "false");
    await toEnd(ctx);
  }
  const view = ctx.document.defaultView!;
  view.cmuxGalleryArrive = () => view.cmuxAcpmuxBridge?.receive(structuredClone(arrivedSnapshot));
};

/// A click whose layout is slow, as at load ~260 (Leo, 2026-11-10: "when things get slow this tool
/// call expansion situatoin gets insanely f***ed"): the page is busy for `ms` right after React drew
/// the click, before the browser lays out what opened, while the turn's next snapshot lands. The
/// clicked line opens where it was clicked (foldAnchor.ts `notePlacement`).
const slowClick = async (ctx: Parameters<Play>[0], line: HTMLElement, ms = 1_200) => {
  const row = line.closest<HTMLElement>(".acpmux-row")!;
  ctx.document.defaultView!.addEventListener(
    "click",
    () => {
      const until = performance.now() + ms;
      while (performance.now() < until);
    },
    { once: true },
  );
  const before = measure(ctx, line);
  const head = row.getBoundingClientRect().top;
  line.click();
  ctx.document.defaultView?.cmuxGalleryArrive?.();
  const id = line.getAttribute("data-tool-id") ?? line.getAttribute("data-tool-group");
  const again = () =>
    (id && row.isConnected
      ? row.querySelector<HTMLElement>(`[data-tool-id="${id}"], [data-tool-group="${id}"]`)
      : undefined) ?? line;
  await settle(ctx, () => again().getAttribute("aria-expanded") === "true");
  const after = measure(ctx, again());
  expect(Math.abs(after.line - before.line) <= 2, "a slow render moved the clicked line", { before, after });
  const moved = row.getBoundingClientRect().top - head;
  expect(Math.abs(moved) <= 2, "a slow render moved the run's header", { moved });
};

/// At the bottom of the working chat: "Ran 2 commands" opened with a slow render, the agent's next
/// command landing as it renders.
const slowGroup: Play = async (ctx) => {
  await armUnderLoad(ctx);
  await slowClick(ctx, ctx.document.querySelector<HTMLElement>(GROUP)!);
};

/// The group open, then one of its commands opened with a slow render while the next snapshot lands.
const slowCommandLine: Play = async (ctx) => {
  await armUnderLoad(ctx);
  const group = ctx.document.querySelector<HTMLElement>(GROUP)!;
  await toggleAndSettle(ctx, group, "true");
  await toEnd(ctx);
  const command = [
    ...ctx.document.querySelectorAll<HTMLElement>(
      '[data-row-id="expand-at-bottom-run"] button.cv-tool.is-toggle[aria-expanded="false"]',
    ),
  ][0]!;
  await slowClick(ctx, command);
};

/// Away from the bottom: an earlier turn's command opened with a slow render.
const slowAway: Play = async (ctx) => {
  await atBottom(ctx);
  await settle(ctx);
  const node = scroller(ctx);
  const line = [...ctx.document.querySelectorAll<HTMLElement>(".cv-worked")].at(-2)!;
  node.scrollTop += line.getBoundingClientRect().top - node.getBoundingClientRect().top - 160;
  await settle(ctx);
  await slowClick(ctx, line);
};

export default agentPaneEntry({
  id: "agent-pane.expand-at-bottom",
  title: "Opening a line at the bottom",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
    "agent-session/acpmux/conversation/foldAnchor.ts",
    // An opened run draws in its scroll box (RunScroll.tsx); the tall group's play opens one.
    "agent-session/acpmux/conversation/RunScroll.tsx#RunScroll",
  ],
  variants: {
    shipped: {
      note: "Scrolled to the very bottom with “Ran 2 commands” closed. Opening it grows down under the composer, as Codex does: the line and the text above it stay put. Away from the bottom it opens down too.",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: atBottom,
    },
    prompt: {
      note: "Scrolled to the very bottom under a long prompt cut to its first lines. Its Show more opens the whole prompt downward: the prompt's top stays put and the reply under it moves down.",
      snapshot: chat(promptRows, { title: "Fetch tests" }),
      play: atBottom,
    },
    "expand-at-bottom": {
      note: "Play: scrolled to the very bottom, “Ran 2 commands” opened: the line stays where it was clicked, its steps grow down under the composer, and the view stops following.",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: expandAtBottom,
    },
    "collapse-at-bottom": {
      note: "Play: a command's Shell card opened, the view back at its very bottom, then the card closed: the text above comes down and no blank room is left under the reply (Leo, 2026-11-03).",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: collapseAtBottom,
    },
    "collapse-tall-group": {
      note: "Play: a tall group open (a 40-line log), the view back at its very bottom, then the group closed: the bottom stays pinned and the text above comes down.",
      snapshot: chat(tallRows, { title: "Fetch tests" }),
      play: collapseTallGroup,
    },
    "under-load": {
      note: "A working chat scrolled to the very bottom with an ended stretch's “Ran 2 commands” shut by the reader. Opened while the agent's next command lands on the live line: one motion, the bottom stays pinned, nothing overlaps.",
      snapshot: runningSnapshot,
      experiments: RUNNING_ARM,
      play: armUnderLoad,
    },
    "slow-render-group": {
      note: "Play: a working chat's ended “Ran 2 commands” opened while the page takes 1.2 s to draw the click and the agent's next command lands on the live line: it opens in place, the header stays, the view stops following.",
      snapshot: runningSnapshot,
      experiments: RUNNING_ARM,
      play: slowGroup,
    },
    "slow-render-command": {
      note: "Play: a command inside the open group opened during a 1.2 s render while the next snapshot lands: the command opens under its line and stays open; nothing above it moves.",
      snapshot: runningSnapshot,
      experiments: RUNNING_ARM,
      play: slowCommandLine,
    },
    "slow-render-away": {
      note: "Play: away from the bottom, an earlier turn's “Worked for” opened during a 1.2 s render: the line stays where it was clicked.",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: slowAway,
    },
    "expand-away": {
      note: "Away from the bottom an earlier turn's “Worked for” line opens down: the line and the view stay where they were.",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: expandAway,
    },
  },
});
