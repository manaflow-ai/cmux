// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// Opening a line with the transcript at its very bottom (Leo, 2026-11-02: "YOU EXPAND UP WHILE YOUR
// SCCROLL IS AT THE VERY BOTTOM AKA YOU FUCKING PUSH THE TEXT UP VISUALLY INSTEAD OF EXPANDING DOWN
// LIKE USUAL / JUST THAT CASE"). A long chat whose last turn ran two commands under "Ran 2 commands"
// and wrote a short reply after them, scrolled to its end. Opening the group there keeps the bottom
// where it is and pushes everything above it up (App.tsx `beginBottomStackFold`); anywhere else the
// line stays put and its body grows down (transcript-expand-at-bottom.test.ts). Closing there pulls the
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
  const scroller = ctx.document.querySelector<HTMLElement>(".acpmux-scroll");
  if (scroller) scroller.scrollTop = scroller.scrollHeight;
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

/// At the bottom: opens "Ran 2 commands", which keeps the bottom and pushes the text above up.
const expandAtBottom: Play = async (ctx) => {
  await atBottom(ctx);
  await settle(ctx);
  const group = ctx.document.querySelector<HTMLElement>(GROUP)!;
  const before = measure(ctx, group);
  expect(before.fromEnd <= 2, "not at the bottom before the click", before);
  await toggleAndSettle(ctx, group, "true");
  const after = measure(ctx, group);
  pinned(before, after, "opening at the bottom");
  expect(before.line - after.line > 40, "opening at the bottom did not push the line up", { before, after });
};

/// At the bottom: opens the group and its last command (a Shell card with its output), then closes
/// the command. The text above comes down by what closed; no blank room is left under the rows.
const collapseAtBottom: Play = async (ctx) => {
  await expandAtBottom(ctx);
  const command = [
    ...ctx.document.querySelectorAll<HTMLElement>(
      '[data-row-id="expand-at-bottom-run"] button.cv-tool.is-toggle[aria-expanded="false"]',
    ),
  ].at(-1)!;
  await toggleAndSettle(ctx, command, "true");
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

export default agentPaneEntry({
  id: "agent-pane.expand-at-bottom",
  title: "Opening a line at the bottom",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
    "agent-session/acpmux/conversation/foldAnchor.ts",
  ],
  variants: {
    shipped: {
      note: "Scrolled to the very bottom with “Ran 2 commands” closed. Opening it keeps the bottom pinned and pushes the text above up; away from the bottom it opens down and nothing moves.",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: atBottom,
    },
    prompt: {
      note: "Scrolled to the very bottom under a long prompt cut to its first lines. Its Show more opens the whole prompt by pushing the text above up; the reply under it stays where it was.",
      snapshot: chat(promptRows, { title: "Fetch tests" }),
      play: atBottom,
    },
    "expand-at-bottom": {
      note: "Scrolled to the very bottom, “Ran 2 commands” opened: the bottom stays where it was and the text above moves up.",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: expandAtBottom,
    },
    "collapse-at-bottom": {
      note: "Scrolled to the very bottom with a command's Shell card open, then closed: the text above comes down and no blank room is left under the reply (Leo, 2026-11-03).",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: collapseAtBottom,
    },
    "collapse-tall-group": {
      note: "Scrolled to the very bottom with a tall group open (a 40-line log), then the group closed: the bottom stays pinned and the text above comes down.",
      snapshot: chat(tallRows, { title: "Fetch tests" }),
      play: collapseTallGroup,
    },
    "expand-away": {
      note: "Away from the bottom an earlier turn's “Worked for” line opens down: the line and the view stay where they were.",
      snapshot: chat(rows, { title: "Fetch tests" }),
      play: expandAway,
    },
  },
});
