// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The transcript's row kinds and states (conversation/*, App.tsx VirtualTranscript), each as the
// snapshot the pane bridge would deliver. src/gallery/format.ts describes the format.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import { SUBAGENTS } from "../subagents/subagentFold";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { childRows } from "../subagents/childRows";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { workedTurnRows } from "../workedTurn";
import { checkRunningLineLoops, hasCompleteRunningLineShimmer } from "./runningLineMotion";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import {
  BUILD_REPORT_PDF_PAGE_PNG,
  BUILD_TIMES_PNG,
  LOGIN_SCREENSHOT_PNG,
  LOGIN_TESTS_MP4,
} from "../../../gallery/fixtures/toolImages";

const prompt = "Add retries with backoff to the fetch helper";

/// A turn's rows as the transcript maps its ACP updates (subagents/childRows.ts, the parent
/// transcript's rules): Claude Code's ToolSearch, then a Read and a command, then the reply.
function toolSearchTurn(): AcpmuxRow[] {
  const call = (id: string, tool: string, title: string, kind: string, extra: Record<string, unknown> = {}) => ({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title,
    kind,
    status: "completed",
    _meta: { claude: { tool } },
    ...extra,
  });
  const updates = [
    call("ts-search", "ToolSearch", "ToolSearch", "other", { rawInput: { query: "select:Grep" } }),
    call("ts-read", "Read", "Read src/net/retry.ts", "read", {
      locations: [{ path: "/Users/you/src/atlas-web/src/net/retry.ts" }],
    }),
    call("ts-test", "Bash", "bun test src/net", "execute", {
      rawInput: { command: "bun test src/net" },
      rawOutput: { exit_code: 0 },
    }),
    {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: "The retry helper backs off and its tests pass." },
    },
  ];
  const turn = childRows(
    "gallery-toolsearch",
    updates.map((update, index) => ({ event: { seq: index + 1, at: minutesAgo(1.9 - index * 0.2) }, update })),
    new Map(),
    1,
  );
  const toolCount = turn.reduce((sum, item) => sum + (item.kind === "activity" ? (item.toolCount ?? 0) : 0), 0);
  return [
    user("Find the retry helper and run its tests", 2, { id: "gallery-toolsearch-user" }),
    ...turn,
    summary(1.1, { id: "gallery-toolsearch-summary", status: "completed", toolCount, durationMs: 54_000 }),
  ];
}

/// Pull requests a leo-workspace chat names by bare number, as the App's cache has them
/// (`pr.inspect`): five of manaflow-ai/cmux, and #843 in both repositories.
const LANE_NUMBERS = [24175, 23959, 24197, 23880, 23027];
const LANE_LIST = "gh pr list -R manaflow-ai/cmux --author @me";
const LANE_OUTPUT = "https://github.com/manaflow-ai/cmux/pull/24100\tagent pane: chips\n";
const cached = (repo: string, number: number, title: string) => [
  `https://github.com/${repo}/pull/${number}`,
  {
    pullRequest: {
      url: `https://github.com/${repo}/pull/${number}`,
      number,
      title,
      state: "merged",
      author: "teamleaderleo",
    },
    fetchedAt: GALLERY_NOW / 1000,
  },
];
const LANE_PULL_REQUESTS = Object.fromEntries([
  ...LANE_NUMBERS.map((number) => cached("manaflow-ai/cmux", number, `Agent pane fix ${number}`)),
  cached("teamleaderleo/leo-workspace", 843, "rulebook: a bare #N links by evidence"),
  cached("manaflow-ai/cmux", 843, "Agent pane: older fix with the same number"),
]);
/// Hovers the chip whose address ends `/<number>` and waits for `card` in its card.
const hoverReference = (number: number, card: string) => async (ctx: PlayContext) => {
  const chip = `a.cv-chip.is-ref[href$="/${number}"]`;
  await ctx.waitFor(() => ctx.document.querySelector(chip), { capMs: 10_000 });
  await ctx.hover({ selector: chip });
  await ctx.waitFor(() => ctx.document.querySelector(card), { capMs: 10_000 });
};
/// A chat whose folder is leo-workspace.
const LEO_WORKSPACE = {
  ready: { githubRepository: "teamleaderleo/leo-workspace" },
  native: { "git.githubRepository": { repository: "teamleaderleo/leo-workspace" } },
  chipHost: { pullRequests: LANE_PULL_REQUESTS },
};

const selectionRows = [
  user("Select this prompt to copy it into a bug report", 5, { id: "gallery-selection-user" }),
  assistant(
    "The response stays selectable while controls keep their keyboard focus.\n\nUse the highlighted prose to compare the real transcript against the reference.",
    4.9,
    { id: "gallery-selection-answer" },
  ),
  summary(4.9, { id: "gallery-selection-summary", status: "completed" }),
];

// Message-surface review fixture: the same prompt, background work, assistant answer and a long
// received peer message are captured over busy wallpaper and a plain dark surface. The `bordered`
// arm preserves the earlier look; `soft` keeps a quiet fill only behind an agent-message card; the
// selected default is borderless.
const messageSurfaceChat = chat([
  user("Review the release notes and tell the lane what changed", 7, { id: "message-surface-user" }),
  activity(
    [
      tool("Read CHANGELOG.md", "read", "completed", { locations: [{ path: "CHANGELOG.md" }] }),
      tool("Run transcript checks", "execute", "completed", { command: "bun test conversation" }),
    ],
    6.8,
    { id: "message-surface-tools" },
  ),
  assistant("The release notes are updated and the transcript remains readable.", 6.4, {
    id: "message-surface-answer",
  }),
  user(
    "The lane sent a review report. It stays readable without a second message plate.\n\n" +
      "The report includes the changed files, test result, and the final verification notes.",
    5.8,
    {
      id: "message-surface-peer",
      incoming: {
        kind: "message",
        message: {
          name: "review-lane",
          text: "The lane sent a review report.\n\n- CHANGELOG.md updated\n- Transcript checks pass\n- Light and dark captures are ready\n\nThe full report remains available with Show more.",
          raw: "[review-lane] The lane sent a review report.",
        },
      },
      untyped: true,
    },
  ),
  summary(5.7, { status: "completed", durationMs: 78_000, toolCount: 2 }),
]);

const keyboardRows = [
  user("Open the work details with the keyboard", 4, { id: "gallery-keyboard-user" }),
  activity(
    [
      thought("The disclosure should keep its focus while the tool list opens."),
      tool("Read src/net/client.ts", "read", "completed"),
      tool("bun test src/net", "execute", "completed"),
    ],
    3.9,
    { id: "gallery-keyboard-activity" },
  ),
  assistant("The work details are open without moving the transcript column.", 3.8, {
    id: "gallery-keyboard-answer",
  }),
  summary(3.8, { id: "gallery-keyboard-summary", status: "completed", toolCount: 2 }),
];

const shellRows = (id: string, title: string, command: string, fields: Parameters<typeof tool>[3] = {}) => [
  user(title, 3, { id: `${id}-user` }),
  activity([tool(title, "execute", fields.status ?? "completed", { command, ...fields })], 2.8, {
    id: `${id}-activity`,
  }),
  assistant("The command details stay inside the transcript row.", 2.6, { id: `${id}-answer` }),
  summary(2.6, { id: `${id}-summary`, status: "completed", toolCount: 1 }),
];

const groupedShellRows = [
  user("Run the focused tests and inspect the failure", 3, { id: "gallery-shell-group-user" }),
  activity(
    [
      tool("bun test src/net --filter retry", "execute", "completed", {
        command: "bun test src/net --filter retry",
        output: "3 pass\n0 fail",
        exitCode: 0,
        startedAt: minutesAgo(2.9),
        endedAt: minutesAgo(2.8),
      }),
      tool("bun test src/net --filter retry --watch", "execute", "failed", {
        command: "bun test src/net --filter retry --watch",
        output: "1 failing test\nExpected the retry delay to increase",
        exitCode: 2,
        startedAt: minutesAgo(2.7),
        endedAt: minutesAgo(2.5),
      }),
    ],
    2.8,
    { id: "gallery-shell-group-activity" },
  ),
  assistant("The first command passed; the second shows its nonzero exit inline.", 2.4, {
    id: "gallery-shell-group-answer",
  }),
  summary(2.4, { id: "gallery-shell-group-summary", status: "completed", toolCount: 2 }),
];

const LONG_CP =
  "cp /private/tmp/claude-501/-Users-leo-Projects/scratch/transcript/before-after/ellipsis-before.png /Users/leo/Projects/cmux/docs/media/ellipsis-after.png";
// Not an acpmux send: a send draws as its own "Sent message to" row (SentMessageLine.tsx).
const LONG_GH =
  "gh pr comment 4182 --body '[transcript-parity] tool rows use the full width and end in an ellipsis at the right edge'";
const longCommandRows = [
  user("Copy the screenshots over and comment on the PR", 3, { id: "gallery-long-commands-user" }),
  activity(
    [LONG_CP, LONG_GH].map((command, at) =>
      tool("Run", "execute", "completed", {
        command,
        output: "",
        exitCode: 0,
        startedAt: minutesAgo(2.9 - at * 0.1),
        endedAt: minutesAgo(2.85 - at * 0.1),
      }),
    ),
    2.8,
    { id: "gallery-long-commands-activity" },
  ),
  assistant("Copied both screenshots and commented on the PR.", 2.6, { id: "gallery-long-commands-answer" }),
  summary(2.6, { id: "gallery-long-commands-summary", status: "completed", toolCount: 2 }),
];

/// One call in the gallery's log: a host bridge call, or `acpmux <method>` for a request the page
/// sent to the in-page mock daemon (mock.ts).
type GalleryCall = {
  method: string;
  params?: { id?: string; sessionId?: string; archived?: unknown };
};
/// The pane's client attached the mock daemon's chat (the menu can show before, from the stage's
/// snapshot), and its header offers the chat menu.
const chatMenuReady = async (ctx: PlayContext) => {
  const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: GalleryCall[] }).cmuxGalleryLog;
  await ctx.waitFor(() => log.some(({ method }) => method === "acpmux _acpmux/attach"), {
    capMs: 10_000,
  });
  await ctx.waitFor(() => ctx.document.querySelector('[aria-label="Chat actions"]'), {
    capMs: 10_000,
  });
};
/// The plays that run the pane's real client against the in-page mock daemon.
const mockDaemonFrames = {
  longFrameFailMs: {
    value: 150,
    reason:
      "The mock daemon's attach and the first transcript mount share the menu's first frame on the CPU-only gallery VM (51-78 ms measured); these plays gate which requests reach acpmux, not frame time.",
  },
  layoutShiftMax: {
    value: 0.05,
    reason:
      "The mock daemon's answer swaps the stage's snapshot for the client's own chat (0.013 measured); the transcript plays above gate layout shift.",
  },
  settleMaxMs: {
    value: 1000,
    reason:
      "A menu pick waits for the in-page mock daemon's round trip and its session change (268 ms measured on the CPU-only VM); this play gates the request, not latency.",
  },
};

const openWorked = async (ctx: PlayContext) => {
  await ctx.click({ selector: ".cv-worked" });
  await ctx.waitFor(() => ctx.find({ selector: ".cv-worked" }).getAttribute("aria-expanded") === "true");
};

const openSingleShell = async (ctx: PlayContext) => {
  await openWorked(ctx);
  await ctx.click({ selector: ".cv-tool.is-toggle" });
  await ctx.waitFor(() => ctx.find({ selector: ".cv-tool.is-toggle" }).getAttribute("aria-expanded") === "true");
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-shell__command")));
};

/// Opens a finished run's folded line ("Ran 2 commands", "Read 2 files, ran 3 commands").
const openFoldedRun = async (ctx: PlayContext) => {
  await ctx.click({ selector: ".cv-tools > .cv-tool.is-toggle" });
  await ctx.waitFor(
    () => ctx.find({ selector: ".cv-tools > .cv-tool.is-toggle" }).getAttribute("aria-expanded") === "true",
  );
};

const openGroupedShells = async (ctx: PlayContext) => {
  await openWorked(ctx);
  // A finished run that is one group folds to its line ("Ran 2 commands"); opened, it lists its calls.
  await openFoldedRun(ctx);
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-command").length === 2);
  await ctx.click({ selector: ".cv-command" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-shell__command").length === 1);
  // Each command is a step of the opened group (ToolGroupRow.tsx), so the second is the second step.
  await ctx.click({ selector: ".cv-step:nth-of-type(2) > .cv-command" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-shell__command").length === 2);
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-shell__exit")));
};

/// Clicks the disclosure line `selector` finds and fails when the line moved once its fold settled:
/// opening or closing never moves the reader's view (foldAnchor.ts, Leo 2026-10-20).
const clickHoldsLine = async (ctx: PlayContext, selector: string, expanded: boolean) => {
  const top = () => ctx.find({ selector }).getBoundingClientRect().top;
  const before = top();
  await ctx.click({ selector });
  await ctx.waitFor(
    () =>
      ctx.find({ selector }).getAttribute("aria-expanded") === String(expanded) &&
      [...ctx.document.querySelectorAll(".cv-fold")].every((fold) => fold.getAnimations().length === 0),
  );
  const moved = top() - before;
  if (Math.abs(moved) > 1) throw new Error(`the clicked line moved ${moved.toFixed(1)}px`);
};

/// A turn that wrote one file whole: its Edited card opens to the file's diff (EditedFilesCard.tsx).
const editedRows = (id: string, path: string, text: string) => [
  user(`Write ${path}`, 3, { id: `${id}-user` }),
  activity(
    [tool(`Write ${path}`, "edit", "completed", { diffs: [{ path, oldText: undefined, newText: text }] })],
    2.8,
    {
      id: `${id}-activity`,
    },
  ),
  assistant("The file is written.", 2.6, { id: `${id}-answer` }),
  summary(2.6, { id: `${id}-summary`, status: "completed", toolCount: 1 }),
];

const openEditedDiff = async (ctx: PlayContext) => {
  await ctx.click({ selector: ".acpmux-edited-toggle" });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-edit-diff")));
};

const EDIT_LONG_CODE =
  [
    'import { backoff } from "./backoff";',
    "",
    'export const retryPolicy = { tries: 5, baseDelayMs: 250, maxDelayMs: 30_000, jitter: "full", retryOn: [408, 425, 429, 500, 502, 503, 504] } as const;',
    "export async function withRetry<T>(run: () => Promise<T>, policy = retryPolicy, onRetry?: (attempt: number, error: unknown) => void): Promise<T> {",
    "  for (let attempt = 1; ; attempt++) {",
    "    try { return await run(); } catch (error) { if (attempt >= policy.tries) throw error; onRetry?.(attempt, error); await backoff(attempt, policy); }",
    "  }",
    "}",
  ].join("\n") + "\n";

/// Code past the eight-line preview, every line wider than the column.
const EDIT_LONG_CODE_CUT =
  Array.from(
    { length: 14 },
    (_, index) =>
      `export const uploadRoute${index + 1} = { path: "/v2/uploads/:id/parts/${index + 1}", method: "PUT", timeoutMs: 30_000, retry: retryPolicy, headers: { "content-type": "application/octet-stream" } } as const;`,
  ).join("\n") + "\n";

const EDIT_LONG_PROSE =
  Array.from({ length: 21 }, (_, index) =>
    index % 4 === 0
      ? `## Excursion ${index / 4 + 1}`
      : `- Day ${index}: the trail climbs past the old lighthouse and the tide pools, then follows the ridge back to the harbour, where the ferry waits until the last walkers are on board.`,
  ).join("\n") + "\n";

const shellLogLine = (index: number) =>
  `2026-10-21T09:${String(index).padStart(2, "0")}:12.481Z retry attempt=${index + 1} url=https://api.example.test/v2/uploads/9f3c2a71/parts?part=${index + 1}&checksum=sha256-4b1f0c9e2d7a6b5c status=503 delayMs=${250 * 2 ** (index % 6)}`;
const SHELL_LONG_LOG = Array.from({ length: 6 }, (_, index) => shellLogLine(index)).join("\n");
/// A log past the eight-line preview, every line wider than the column.
const SHELL_LONG_LOG_CUT = Array.from({ length: 14 }, (_, index) => shellLogLine(index)).join("\n");

/// A command still running, its output streaming in, in its own row: the turn went on past it
/// (a lone running call reads only on the turn's live line).
const liveShellRows = (id: string, output: string) => [
  user("Follow the retry log", 1, { id: `${id}-user` }),
  activity(
    [
      tool("tail -f logs/retry.log", "execute", "in_progress", {
        command: "tail -f logs/retry.log",
        output,
        startedAt: minutesAgo(0.9),
      }),
    ],
    0.8,
    { id: `${id}-activity` },
  ),
  activity([tool("Read retryPolicy.ts", "read", "in_progress")], 0.5, { id: `${id}-read` }),
];

/// Opens the one call's row (inside the turn's fold once it is done; a running turn shows it) and
/// turns its Wrap lines off.
const unwrapCall = (body: string, actions: string) => async (ctx: PlayContext) => {
  if (!ctx.document.querySelector(".cv-tool.is-toggle")) await openWorked(ctx);
  await ctx.click({ selector: ".cv-tool.is-toggle" });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(body)));
  await ctx.click({ selector: `${actions} button[aria-label="Wrap lines"]` });
  await ctx.waitFor(() => ctx.document.querySelector(body)?.getAttribute("data-wrap") === "false");
};

const shellDisclosureChecks = {
  layoutShiftMax: {
    value: 0.25,
    reason: "Opening command details intentionally reveals the shell block below its focused row.",
  },
};

/// A search call whose label (a long alternation) is cut at the row's edge until it is opened
/// (ToolRow.tsx `is-whole-open`; Leo, ask-486cb2cec3: "why the fuck did you guys ffucking ellipsis
/// EVERYTHING WITH NO WAY TO EXPAND WHAT WAS SAID TO SEE").
const CUT_PATTERN =
  "useAnchoredCollapse|useTranscriptDisclosure|holdFold|keepFold|foldToggleAt|ANCHORED_COLLAPSE_EVENT|trimmedFoldRoom";
const cutLineRows = [
  user("Find every place that holds a fold", 3, { id: "gallery-cut-line-user" }),
  activity(
    [
      tool(`Grep ${CUT_PATTERN}`, "search", "completed", {
        output: "src/agent-session/acpmux/App.tsx:4268: const line = foldHoldTarget(toggle, node);",
      }),
    ],
    2.8,
    { id: "gallery-cut-line-activity" },
  ),
  assistant("Two places hold a fold: the click and the anchored-collapse event.", 2.6, {
    id: "gallery-cut-line-answer",
  }),
  summary(2.6, { id: "gallery-cut-line-summary", status: "completed", toolCount: 1 }),
];
const cutLine = ".cv-tool.is-toggle";
/// Opens Worked for, and with `open` the cut line too; fails when the opened label is still cut.
const showCutLine = (open: boolean) => async (ctx: PlayContext) => {
  await openWorked(ctx);
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(cutLine)));
  if (!open) return;
  await ctx.click({ selector: cutLine });
  await ctx.waitFor(() => ctx.find({ selector: cutLine }).getAttribute("aria-expanded") === "true");
  const text = ctx.find({ selector: `${cutLine} > .cv-tool__text` }) as HTMLElement;
  if (text.scrollWidth > text.clientWidth + 1) throw new Error("the opened line's label is still cut");
};

/// A long command output at the transcript's end, opened with Show all: closing it from its Show
/// less, scrolled down to, leaves the reader at the control they clicked, never on a view of blank
/// room under rows that closed up above it (foldAnchor.ts `foldHoldTarget`, review BLOCK at 5e59e449).
const SHOW_LESS_LOG = Array.from(
  { length: 160 },
  (_, index) => `(pass) retry backoff case ${index + 1} [0.${index % 10}ms]`,
).join("\n");
const showLessAtEnd = async (ctx: PlayContext) => {
  await openSingleShell(ctx);
  const more = { selector: ".cv-shell .cv-output-more" };
  await ctx.click(more);
  await ctx.waitFor(() => ctx.find(more).getAttribute("aria-expanded") === "true");
  // The opened output lands first: its fold plays and the rows under it place by their drawn
  // heights, so the content stops growing (three frames at one height, nothing animating).
  const scroller = ctx.find({ selector: ".acpmux-scroll" }) as HTMLElement;
  let height = -1;
  let still = 0;
  await ctx.waitFor(() => {
    still = scroller.scrollHeight === height ? still + 1 : 0;
    height = scroller.scrollHeight;
    return still >= 3 && scroller.getAnimations({ subtree: true }).every((a) => a.playState !== "running");
  });
  // The reader scrolls down to Show less, under the opened output, at the view's foot. A reader's
  // scroll is a wheel, which lets go of the hold Show all's click started (App.tsx `release`); an
  // offset set alone, inside that hold, is put back where the click held the row. The wheel is a
  // pixel, so its own glide moves nothing that matters.
  scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true, cancelable: true }));
  (ctx.find(more) as HTMLElement).scrollIntoView({ block: "end" });
  scroller.dispatchEvent(new Event("scroll"));
  const view = () => scroller.getBoundingClientRect();
  await ctx.waitFor(() => (ctx.find(more) as HTMLElement).getBoundingClientRect().bottom <= view().bottom + 1);
  const row = ctx.find(more).closest(".acpmux-row")!;
  if (row.getBoundingClientRect().top >= view().top) throw new Error("the opened output's row top is still in view");
  await ctx.click(more);
  const clicked = performance.now();
  // The hold is over well before 1.7 s (FOLD_HOLD_MIN_MS, or the fold and its settle); the view is the reader's after it.
  await ctx.waitFor(
    () => ctx.find(more).getAttribute("aria-expanded") === "false" && performance.now() - clicked > 1700,
    { capMs: 5000 },
  );
  const control = (ctx.find(more) as HTMLElement).getBoundingClientRect();
  if (control.bottom <= view().top || control.top >= view().bottom)
    throw new Error("closing the output left the view on blank room: the control the reader clicked is out of view");
};

/// One long finished turn, shaped like the ones Lawrence and Leo pasted (synthetic text): runs of
/// commands, short narration, a compaction and a subagent ending, two answers to the person, a
/// command after the second and a closing line. Once complete, everything before the closing
/// answer folds under the turn's one Worked-for line.
const takeawayTurnRows = [
  user("Why is the agent pane slow, and what should we fix first?", 12, { id: "gallery-takeaway-user" }),
  activity(
    [
      tool("rg -n useLayoutEffect src", "execute", "completed", { command: "rg -n useLayoutEffect src", exitCode: 0 }),
      tool("bun run bench:transcript", "execute", "completed", { command: "bun run bench:transcript", exitCode: 0 }),
    ],
    11.8,
    { id: "gallery-takeaway-run-1" },
  ),
  assistant("Both audits are still running.", 11.5, { id: "gallery-takeaway-narration" }),
  row("compaction", 11.2, {
    id: "gallery-takeaway-compaction",
    compaction: { state: "completed", preTokens: 123_000, postTokens: 13_000 },
  }),
  activity(
    [
      tool("Read src/transcript/VirtualList.tsx", "read", "completed"),
      tool("bun test src/transcript", "execute", "completed", { command: "bun test src/transcript", exitCode: 0 }),
    ],
    10.4,
    { id: "gallery-takeaway-run-2" },
  ),
  assistant(
    "The first audit is done. Most of the time goes to measuring rows twice:\n\n1. Every new token re-measures the whole visible list.\n2. Opening a fold re-lays out the rows above it.\n\nShould I start with the first one?",
    9,
    { id: "gallery-takeaway-first" },
  ),
  activity(
    [
      tool("git diff --stat", "execute", "completed", { command: "git diff --stat", exitCode: 0 }),
      tool("bun run typecheck", "execute", "completed", { command: "bun run typecheck", exitCode: 0 }),
    ],
    6,
    { id: "gallery-takeaway-run-3" },
  ),
  assistant(
    "Why it is slow, and the fixes:\n\n- Measure only the row that changed, not the visible list.\n- Keep the fold's header in place and grow its content downward.\n- Cache each row's height by its version.\n\nThe first fix is on the branch; the other two follow.",
    4.6,
    { id: "gallery-takeaway-second" },
  ),
  activity([tool("git push", "execute", "completed", { command: "git push", exitCode: 0 })], 4.4, {
    id: "gallery-takeaway-push",
  }),
  assistant("Pushed.", 4.3, { id: "gallery-takeaway-pushed" }),
  summary(4.3, { id: "gallery-takeaway-summary", status: "completed", durationMs: 456_000, toolCount: 7 }),
];

/// A finished turn whose "Worked for" folds four calls, then a later turn below it: opening or
/// closing the line slides the rows below and fades what it shows or hides (turnFold.ts).
const turnFoldRows = [
  user("Add retries with backoff to the fetch helper", 8, { id: "gallery-turnfold-user" }),
  activity(
    [
      thought("The retry wrapper swallows the status code, so check how the helper parses errors first."),
      tool("Read src/net/client.ts", "read", "completed"),
      tool("Search for fetchWithRetry", "search", "completed"),
      tool("bun test src/net", "execute", "completed", { command: "bun test src/net", output: "12 pass", exitCode: 0 }),
      tool("bun run typecheck", "execute", "completed", { command: "bun run typecheck", exitCode: 0 }),
    ],
    7.9,
    { id: "gallery-turnfold-activity" },
  ),
  assistant(
    "Retries now back off from 200 ms, doubling up to three tries.\n\nOnly timeouts and 5xx answers retry; a 4xx fails at once.",
    7.5,
    { id: "gallery-turnfold-answer" },
  ),
  summary(7.5, { id: "gallery-turnfold-summary", status: "completed", toolCount: 4 }),
  user("Now cover it with a test that fakes two timeouts", 6, { id: "gallery-turnfold-next-user" }),
  assistant("Added `client.retry.test.ts`: it passes, and fails with the retry taken out.", 5.5, {
    id: "gallery-turnfold-next-answer",
  }),
  summary(5.5, { id: "gallery-turnfold-next-summary", status: "completed" }),
];

/// Holds every running animation halfway, so the still shows the fold mid-motion (a base that
/// plays none shows the line already open or closed).
const holdFoldHalfway = (ctx: PlayContext) => {
  for (const animation of ctx.document.getAnimations()) {
    const duration = Number(animation.effect?.getComputedTiming().duration) || 0;
    animation.pause();
    animation.currentTime = duration / 2;
  }
};

/// Clicks "Worked for" so it ends `expanded`, and holds its fold halfway.
const toggleWorkedHalfway = async (ctx: PlayContext, expanded: boolean) => {
  const line = ctx.find({ selector: ".cv-worked" }) as HTMLElement;
  // A plain click: a play step waits for the page to settle, which would let the fold finish.
  line.click();
  await ctx.waitFor(() => line.getAttribute("aria-expanded") === String(expanded));
  holdFoldHalfway(ctx);
};

const longChatRows = Array.from({ length: 24 }, (_, index) => {
  const at = 3000 - index * 120;
  return [
    user(`Question ${index + 1}: how does part ${index + 1} of the retry flow work?`, at),
    assistant(
      `Part ${index + 1} waits, then calls the task again. ${"It is covered by a test. ".repeat(1 + (index % 4))}`,
      at - 1,
    ),
    summary(at - 1, { status: "completed" }),
  ];
}).flat();

/// A thought of a few lines, and a live turn whose step holds `items` and a call, then `after` and a
/// second call (ThoughtRow.tsx, thoughts.ts).
const SHORT_THOUGHT =
  "Check how the helper parses errors first.\n\nThe retry wrapper in src/net/client.ts swallows the status code, so a 429 looks like a network failure.\n\nRetry only on 429 and 5xx, with jittered backoff capped at three attempts.";
const thoughtChat = (items: AcpmuxActivity[], after: AcpmuxActivity[] = []) =>
  chat(
    [
      user(prompt, 2),
      activity(
        [
          ...items,
          tool("Read client.ts", "read", "completed", {
            locations: [{ path: "/Users/you/src/atlas-web/src/net/client.ts" }],
          }),
          ...after,
          ...(after.length ? [tool("Search for parseError", "search", "completed")] : []),
        ],
        1.5,
      ),
    ],
    { isWorking: true },
  );

/// A thought taller than the transcript's view (ThoughtRow.tsx folds it once done).
const LONG_THOUGHT = [
  "**Planning the retry fix**",
  "",
  ...Array.from(
    { length: 40 },
    (_, index) =>
      `${index + 1}. ${["Read how the helper parses errors", "Check which statuses reach the retry loop", "Compare the jitter with the backoff cap", "Note what the tests already cover"][index % 4]} (step ${index + 1}).`,
  ),
].join("\n");

const LONG_CODE = [
  "Here is the whole retry module after the change:",
  "",
  "```ts",
  ...Array.from({ length: 60 }, (_, index) =>
    index % 10 === 0
      ? `// ---- section ${index / 10 + 1}: a deliberately long line that does not wrap in a code card, so the card scrolls sideways ----`
      : `export const step${index} = (input: number): number => input * ${index} + Math.floor(${index} / 3);`,
  ),
  "```",
  "",
  "And the shell commands I ran:",
  "",
  "```sh",
  "bun test src/net --filter retry",
  "bun run typecheck",
  "```",
].join("\n");

const MATH = [
  "The backoff after attempt $n$ is $d_n = \\min(d_{\\max},\\ d_0 \\cdot 2^{n-1}) + U(0, d_0)$, so the expected total wait is",
  "",
  "$$",
  "E[W] = \\sum_{n=1}^{N-1} \\left( \\min(d_{\\max}, d_0 2^{n-1}) + \\frac{d_0}{2} \\right)",
  "$$",
  "",
  "With $d_0 = 250\\,\\text{ms}$, $d_{\\max} = 4\\,\\text{s}$ and $N = 3$ that is $E[W] = 1000\\,\\text{ms}$.",
].join("\n");

const MATH_DELIMITERS = [
  "Every delimiter typesets: $\\lambda = 1/\\bar{d}$ and \\(p = 1 - e^{-\\lambda t}\\) inline,",
  "",
  "\\[",
  "P(T \\le t) = \\int_0^t \\lambda e^{-\\lambda s}\\,ds",
  "\\]",
  "",
  "and $$\\textstyle\\sum_i p_i = 1$$ inside a sentence.",
  "",
  "Prices and shell text stay text: the runner costs $5 and $10 an hour, $5-$10 on spot, US$40 a month, and echo $$ and $$ print the shell's PID.",
].join("\n");

const WEB_VIDEO = "https://github.com/user-attachments/assets/7d3f2c1a-58b4-4e0f-9a61-2c8e5b0d4f17";
const WEB_VIDEO_REPLY = [
  "Yes. The recording attached to the PR shows all six login tests passing:",
  "",
  WEB_VIDEO,
].join("\n");

const BUILD_CHART = [
  "The app target dominates the build. Per-target wall time from the last 20 CI runs on main:",
  "",
  "```vega-lite",
  JSON.stringify(
    {
      $schema: "https://vega.github.io/schema/vega-lite/v5.json",
      width: 420,
      height: 180,
      data: {
        values: [
          { target: "app", p50: 312, p90: 371 },
          { target: "api", p50: 204, p90: 229 },
          { target: "worker", p50: 171, p90: 190 },
          { target: "ui-kit", p50: 122, p90: 140 },
          { target: "docs", p50: 88, p90: 97 },
          { target: "e2e", p50: 64, p90: 82 },
          { target: "lint", p50: 41, p90: 45 },
        ],
      },
      layer: [
        {
          mark: { type: "bar", color: "#3b6fd8" },
          encoding: {
            y: { field: "target", type: "nominal", sort: "-x", title: null },
            x: { field: "p50", type: "quantitative", title: "seconds (p50, tick = p90)" },
            tooltip: [{ field: "target" }, { field: "p50" }, { field: "p90" }],
          },
        },
        {
          mark: { type: "tick", color: "#e8a33d", thickness: 2 },
          encoding: {
            y: { field: "target", type: "nominal", sort: "-x" },
            x: { field: "p90", type: "quantitative" },
          },
        },
      ],
    },
    null,
    2,
  ),
  "```",
  "",
  "Splitting the app target's type check (41% of its time) is the biggest win.",
].join("\n");

const MARKDOWN_MIX = [
  "## What changed",
  "",
  "- **GETs** retry `408`, `429` and gateway `5xx` errors.",
  "- **POSTs** retry only with a policy:",
  "  1. pass `retry: { attempts: 5 }`;",
  "  2. or wrap the call in `withRetry`.",
  "",
  "> The jitter keeps a fleet of clients from retrying in lockstep.",
  "",
  "| Status | Retried | Note |",
  "| --- | --- | --- |",
  "| 408 | yes | request timeout |",
  "| 429 | yes | honors `Retry-After` later |",
  "| 500 | no | a server bug, not a blip |",
  "",
  "See [the retry module](src/net/retry.ts) and https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/429.",
].join("\n");

const GALLERY_IMAGE =
  "data:image/svg+xml," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" width="96" height="56"><rect width="96" height="56" fill="#6b7280"/><circle cx="28" cy="28" r="14" fill="#f2cc8f"/><path d="M54 43l12-16 18 16" fill="#81b29a"/></svg>',
  );
const TOO_LARGE_IMAGE = `data:image/png;base64,${"A".repeat(2_000_001)}`;
const CHIP_PREVIEW_MIX = [
  "## Reply links and images",
  "",
  "A globe URL: https://example.test/docs and a cached site: https://docs.example.test/guide.",
  "The long address is https://example.test/research/2026/agent-session/gallery/fixtures?view=transcript&sort=recent&filter=public.",
  "Inside the project: [retry.ts](/Users/you/src/atlas-web/src/net/retry.ts) and [net/](/Users/you/src/atlas-web/src/net/).",
  "Outside the project: [notes](/Users/you/Documents/notes.md); the deny-listed `/Users/you/.ssh/id_ed25519.pem` stays text.",
  "",
  "Remote image (click to load): ![remote](https://images.example.test/gallery/remote.png)",
  "A local image loads through the host: ![diagram](/Users/you/src/atlas-web/assets/diagram.png)",
  `An oversized inline image stays safe: ![too large](${TOO_LARGE_IMAGE})`,
  "",
  "The local preview card is at http://localhost:5173/preview.html?tab=gallery.",
].join("\n");

const TASKS_REPLY = [
  "- [x] Checked task",
  "- [ ] Unchecked task",
  "- [x] Nested checklist",
  "  - [ ] Nested unchecked item",
  "  - [x] Nested checked item",
  "- [ ] This long task title wraps across several lines in a narrow agent pane so the checkbox stays aligned with the first line.",
].join("\n");

const CHIP_HOST = {
  paths: {
    "/Users/you/src/atlas-web/src/net/retry.ts": { place: "root" as const, folder: false },
    "/Users/you/src/atlas-web/src/net/": { place: "root" as const, folder: true },
    "/Users/you/Documents/notes.md": { place: "outside" as const, folder: false },
  },
  sites: {
    "https://docs.example.test/guide": {
      title: "Example docs",
      icon:
        "data:image/svg+xml," +
        encodeURIComponent(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" rx="4" fill="#e07a5f"/><path d="M4 8h8M8 4v8" stroke="#fff" stroke-width="2"/></svg>',
        ),
    },
  },
  policy: { outsideRoots: "confirm" as const, remoteImages: "click" as const },
  images: {
    "https://images.example.test/gallery/remote.png": GALLERY_IMAGE,
    "/Users/you/src/atlas-web/assets/diagram.png": GALLERY_IMAGE,
  },
};

const completedFooterSnapshot = chat([
  user(prompt, 30),
  assistant(MARKDOWN_MIX, 29),
  summary(29, { status: "completed", durationMs: 41_000, seq: 2 }),
]);

const footerActionsPlacement = (placement: "left" | "right") => async (ctx: PlayContext) => {
  await ctx.waitFor(() => {
    const group = ctx.document.querySelector<HTMLElement>(".cv-turn-action-group");
    const datasetPlacement = ctx.document.documentElement.dataset.turnActionsPlacement;
    // Left is the stylesheet default, so the bridge removes its data attribute for that side.
    const datasetMatches = placement === "left" ? datasetPlacement === undefined : datasetPlacement === placement;
    return (
      datasetMatches &&
      group !== null &&
      group.querySelector('button[aria-label="Copy"]') !== null &&
      group.querySelector('button[aria-label="Retry"]') !== null
    );
  });
  const footer = ctx.document.querySelector<HTMLElement>(".cv-turn-actions");
  const group = ctx.document.querySelector<HTMLElement>(".cv-turn-action-group");
  const copy = group?.querySelector('button[aria-label="Copy"]');
  const retry = group?.querySelector('button[aria-label="Retry"]');
  if (!footer || !group || !copy || !retry) throw new Error("turn footer actions did not render");
  await ctx.focus({ selector: 'button[aria-label="Copy"]' });
  const footerBox = footer.getBoundingClientRect();
  const groupBox = group.getBoundingClientRect();
  const footerMid = (footerBox.left + footerBox.right) / 2;
  const groupMid = (groupBox.left + groupBox.right) / 2;
  if (placement === "left" ? groupMid >= footerMid : groupMid <= footerMid)
    throw new Error(`turn footer actions are not ${placement}-aligned`);
};

/// The live line at the bottom of a running turn stands clear of the row over it, never flush
/// under it (Leo, 2026-10-21: "THE RUNNING A COMMAND IS WAY TOO CLOSE"); its words shimmer, and
/// its "⌃B to run in background" waits for the pointer.
const liveLineClear = async (ctx: PlayContext) => {
  const doc = ctx.document;
  await ctx.waitFor(() => doc.querySelector(".cv-worked.is-below .cv-thinking"));
  const words = doc.querySelector<HTMLElement>(".cv-worked.is-below .cv-thinking")!.getBoundingClientRect();
  const over = [...doc.querySelectorAll(".cv-tool, .cv-md")]
    .map((node) => node.getBoundingClientRect().bottom)
    .filter((bottom) => bottom <= words.top + 1);
  if (!over.length) throw new Error("no tool row or reply draws over the live line");
  const gap = words.top - Math.max(...over);
  if (!(gap >= 14)) throw new Error(`the live line sits ${gap.toFixed(1)}px under the row over it, not 14px or more`);
  const hint = doc.querySelector<HTMLElement>(".cv-worked.is-below .cv-command__bg");
  if (hint && getComputedStyle(hint).opacity !== "0")
    throw new Error("the ⌃B hint shows before the pointer is on the line");
  if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
    const line = doc.querySelector<HTMLElement>(".cv-worked.is-below .cv-thinking")!;
    const loops = line
      .getAnimations({ subtree: true })
      .filter((animation) => animation.effect?.getTiming().iterations === Infinity)
      .map((animation) => {
        const effect = animation.effect as KeyframeEffect | null;
        return {
          name: (animation as CSSAnimation).animationName,
          target: effect?.target instanceof Element ? effect.target : null,
          playState: animation.playState,
          playbackRate: animation.playbackRate,
          currentTime: animation.currentTime,
          duration: Number(effect?.getTiming().duration),
          progress: effect?.getComputedTiming().progress ?? null,
        };
      });
    const check = checkRunningLineLoops(loops);
    if (check.unapproved.length || check.duplicateTargets.length || !hasCompleteRunningLineShimmer(check))
      throw new Error("the live line's words do not shimmer as one loop per text layer");
  }
  await ctx.hover({ selector: ".cv-worked.is-below" });
  if (hint) await ctx.waitFor(() => getComputedStyle(hint).opacity === "1");
};

/// The selected borderless message arm is a real rendered contract: the prompt keeps liquid glass
/// without an edge, received/agent bodies have no box shadow, and the assistant prose stays plain.
const messageSurfaceComputedStyle = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="message-surface-peer"] .cv-received'));
  const view = ctx.document.defaultView!;
  const prompt = ctx.document.querySelector<HTMLElement>('[data-row-id="message-surface-user"] .cv-user__bubble');
  const peer = ctx.document.querySelector<HTMLElement>('[data-row-id="message-surface-peer"] .cv-received');
  const assistant = ctx.document.querySelector<HTMLElement>('[data-row-id="message-surface-answer"] .cv-md');
  if (!prompt || !peer || !assistant) throw new Error("message surface fixture did not render");
  const promptStyle = view.getComputedStyle(prompt);
  const peerStyle = view.getComputedStyle(peer);
  if (promptStyle.getPropertyValue("--glass-edge").trim() !== "transparent")
    throw new Error("the selected user bubble still has a glass edge");
  // Every glass mode: Lens and Spectrum draw a specular line, a lower shade and fringes from
  // --glass-rim, so the bubble's whole rim shadow must be clear under each, not only Plain's edge.
  const root = ctx.document.documentElement;
  const savedGlass = root.getAttribute("data-glass");
  try {
    for (const mode of ["plain", "lens", "spectrum"]) {
      root.setAttribute("data-glass", mode);
      const shadow = view.getComputedStyle(prompt).boxShadow;
      const opaque = (shadow.match(/rgba?\([^)]*\)|color\([^)]*\)/g) ?? []).filter(
        (color) => !/,\s*0\)$|\/\s*0\)$/.test(color),
      );
      if (opaque.length) throw new Error(`the user bubble draws a rim under ${mode} glass: ${shadow}`);
    }
  } finally {
    if (savedGlass === null) root.removeAttribute("data-glass");
    else root.setAttribute("data-glass", savedGlass);
  }
  if (peerStyle.boxShadow !== "none" || peerStyle.backgroundColor !== "rgba(0, 0, 0, 0)")
    throw new Error(`the peer message is boxed: ${peerStyle.boxShadow} / ${peerStyle.backgroundColor}`);
  const assistantStyle = view.getComputedStyle(assistant);
  if (assistantStyle.backgroundColor !== "rgba(0, 0, 0, 0)" || assistantStyle.boxShadow !== "none")
    throw new Error("assistant prose picked up a message container surface");
};

/// The running line ("Thinking", "Working for") holds still: no mark blinks before its words and
/// nothing on it loops (Leo, 2026-10-20, "the blinking ascii").
/// The running line starts with its words, with no mark before them. Only the word Thinking may
/// loop (its shimmer, `shimmers`); nothing else on the line does.
const runningLineStill =
  (label: RegExp, shimmers = false) =>
  async (ctx: PlayContext) => {
    await ctx.waitFor(() => label.test(ctx.document.querySelector(".cv-worked")?.textContent ?? ""));
    const line = ctx.document.querySelector<HTMLElement>(".cv-worked")!;
    if (line.querySelector(".cv-working-mark, .cv-activity__dots")) throw new Error("a working mark draws on the line");
    const first = line.firstElementChild?.textContent?.trim() ?? "";
    if (!label.test(first)) throw new Error(`the line starts with ${JSON.stringify(first)}, not its words`);
    const loops = line
      .getAnimations({ subtree: true })
      .filter((animation) => animation.effect?.getTiming().iterations === Infinity);
    const check = checkRunningLineLoops(
      loops.map((animation) => {
        const effect = animation.effect as KeyframeEffect | null;
        return {
          name: (animation as CSSAnimation).animationName,
          target: effect?.target instanceof Element ? effect.target : null,
          playState: animation.playState,
          playbackRate: animation.playbackRate,
          currentTime: animation.currentTime,
          duration: Number(effect?.getTiming().duration),
          progress: effect?.getComputedTiming().progress ?? null,
        };
      }),
    );
    if (check.unapproved.length || check.duplicateTargets.length)
      throw new Error(
        `${check.unapproved.length + check.duplicateTargets.length} unapproved or duplicate animations loop on the running line`,
      );
    // Motion allowed (the gallery stage), the word Thinking sweeps; Reduce Motion stills it (CSS).
    if (shimmers && !hasCompleteRunningLineShimmer(check))
      throw new Error(`Thinking shimmers ${check.shimmer.length} times, not one loop per text layer`);
    if (!shimmers && check.shimmer.length) throw new Error("a line other than Thinking shimmers");
  };

/// A run of commands longer than a group shows at once (ToolGroupRow.tsx GROUP_TAIL).
/// A finished command that says what it does (Claude Code's Bash description), as its row reads it.
const describedShell = (command: string, description: string, fields: Parameters<typeof tool>[3] = {}) =>
  tool(description, "execute", "completed", {
    command,
    description,
    exitCode: 0,
    output: "",
    startedAt: minutesAgo(3),
    endedAt: minutesAgo(2.98),
    ...fields,
  });

/// A finished command written the way agents write them, behind a PATH export, with no description.
const envShell = (command: string) =>
  tool(command, "execute", "completed", {
    command: `export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"\n${command}`,
    exitCode: 0,
    output: "",
    startedAt: minutesAgo(1.9),
    endedAt: minutesAgo(1.88),
  });

/// An ended turn with one call per run, none a shell: a finished fetch and a failed one (Leo,
/// 2026-10-21: "only show the green/red checkmark + time on hover for ours"). A running call keeps
/// its spinner (transcript-codex-turn.test.tsx).
const loneToolCalls = () =>
  chat([
    user("Read the API docs and the reference.", 3),
    activity(
      [
        tool("Fetch https://example.com/docs", "fetch", "completed", {
          startedAt: minutesAgo(2.9),
          endedAt: minutesAgo(2.88),
        }),
      ],
      2.9,
    ),
    assistant("The docs page loaded; the API reference is next.", 2.8),
    activity(
      [
        tool("Fetch https://example.com/api", "fetch", "failed", {
          startedAt: minutesAgo(2.7),
          endedAt: minutesAgo(2.69),
        }),
      ],
      2.7,
    ),
    assistant("The reference page is gone; the docs cover what we need.", 2.6),
    summary(2.6, { status: "completed", toolCount: 2, durationMs: 24_000 }),
  ]);

/// Opens the turn's Worked for and its folded run ("Searched the web"). At rest the finished
/// call's check and time are hidden and keep their room; the failure's red word shows.
const loneToolMetaAtRest = async (ctx: PlayContext) => {
  await openGroupedRun(ctx);
  await ctx.waitFor(() => ctx.document.querySelector(".cv-tool .cv-command__ok"));
  const view = ctx.document.defaultView!;
  for (const node of ctx.document.querySelectorAll(".cv-tool .cv-command__ok, .cv-tool .cv-command__time"))
    if (view.getComputedStyle(node).opacity !== "0") throw new Error("a finished call's check or time shows at rest");
  const failed = ctx.find({ selector: ".cv-tool__failed" });
  const style = view.getComputedStyle(failed);
  if (style.opacity !== "1" || style.color === view.getComputedStyle(failed.parentElement!).color)
    throw new Error("the failed call's mark is not red at rest");
};

/// A quiet turn under a second with no answer, a sub-second answer, then a 5s one (sub-second-turns).
const subSecondTurns = () =>
  chat([
    user("Note for later: the deploy key rotates Friday.", 9),
    summary(9, { status: "completed", durationMs: 300 }),
    user("Is CI green?", 6),
    assistant("Yes, all checks passed.", 6),
    summary(6, { status: "completed", durationMs: 800 }),
    user("Summarize the failing test", 3),
    assistant("The retry test times out: the mock server never answers the second request.", 2.9),
    summary(2.9, { status: "completed", durationMs: 5_000 }),
  ]);

/// Opens the turn's Worked for, then its one run's folded line.
const openGroupedRun = async (ctx: PlayContext) => {
  await openWorked(ctx);
  await openFoldedRun(ctx);
};

const DENSE_COMMANDS = [
  "cd ~/Projects/cmux && git log --oneline -5 -- Sources/Sidebar",
  "rg -n 'onDrop' webviews/src/sidebar",
  "rg -n 'dragIndex' webviews/src/sidebar",
  "git diff origin/feat-cmux-next -- webviews/src/sidebar/SidebarDrag.tsx",
  "bun test test/sidebar-drag.test.tsx",
  "rg -n 'reorder' webviews/src/sidebar/sidebarStore.ts",
  "git log -3 --format='%h %s' -- webviews/src/sidebar/sidebarStore.ts",
];
const shellTool = (command: string) =>
  tool(command, "execute", "completed", {
    command,
    exitCode: 0,
    output: "",
    startedAt: minutesAgo(2.8),
    endedAt: minutesAgo(2.79),
  });

/// A running turn with a run of mixed work between two messages, then the run it works in now: the
/// first run collapses to one line (Leo 2026-10-22: "this is pretty good ui: … the collapsing i
/// mean"). `extra` joins that run's calls (a failed one).
const collapsedRunChat = (extra: AcpmuxActivity[] = []) =>
  chat(
    [
      user("Retries for the net client, then run its tests.", 4),
      assistant("I'll add a retry helper around fetchJson and wire it into the client.", 3.9),
      activity(
        [
          tool("Edit retry.ts", "edit", "completed", {
            locations: [{ path: "src/net/retry.ts" }],
            diffs: [{ path: "src/net/retry.ts", oldText: "", newText: "export async function withRetry() {}\n" }],
          }),
          tool("Read client.ts", "read", "completed", { locations: [{ path: "src/net/client.ts" }] }),
          tool("Edit client.ts", "edit", "completed", {
            locations: [{ path: "src/net/client.ts" }],
            diffs: [
              {
                path: "src/net/client.ts",
                oldText: "  return request(url);\n",
                newText: "  return withRetry(() => request(url));\n",
              },
            ],
          }),
          tool("Read errors.ts", "read", "completed", { locations: [{ path: "src/net/errors.ts" }] }),
          shellTool("bun test src/net"),
          shellTool("git diff --stat"),
          ...extra,
        ],
        3.5,
      ),
      assistant(
        "The helper is in and the client uses it. Next I check that nothing else in src/net already retries, so a failing request never backs off twice.",
        3,
      ),
      activity(
        [
          shellTool("rg -n retry src/net"),
          tool("bun run typecheck", "execute", "in_progress", {
            command: "bun run typecheck",
            startedAt: minutesAgo(0.2),
          }),
        ],
        0.3,
      ),
    ],
    { isWorking: true },
  );

/// A running turn whose first run did one kind of work, two web fetches, between two messages: its
/// collapsed line keeps that kind's glyph, the globe.
const oneKindRunChat = () =>
  chat(
    [
      user("Check what the two retry guides say, then run the tests.", 3),
      assistant("I'll read both guides first.", 2.9),
      activity(
        [
          tool("Fetch https://example.com/retries", "fetch", "completed"),
          tool("Fetch https://example.com/backoff", "fetch", "completed"),
        ],
        2.8,
      ),
      assistant("Both guides cap retries at three with jittered backoff. Next I run the tests.", 2.5),
      activity(
        [
          tool("bun test src/net", "execute", "in_progress", {
            command: "bun test src/net",
            startedAt: minutesAgo(0.2),
          }),
        ],
        0.3,
      ),
    ],
    { isWorking: true },
  );

const MCP_THREAD = "01a14822-c01a-76a1-9fc5-1268687464d4";
/// Codex's MCP call shape: `<server>.<tool> call`, arguments nested under `arguments`.
const mcpTool = (name: string, args: unknown, output: string) =>
  tool(`codex_apps.${name} call`, "execute", "completed", {
    inputSummary: JSON.stringify({ server: "codex_apps", tool: name, arguments: args }),
    output,
  });
const MCP_SENDS = ["READY #22338", "MERGED #22283", "CI armed", "Previews saved"].map((message) =>
  mcpTool("send_message", { threadId: MCP_THREAD, message }, JSON.stringify({ ok: true })),
);
const MCP_READ = mcpTool(
  "read_thread",
  { threadId: MCP_THREAD },
  JSON.stringify({
    content: [
      {
        type: "text",
        text: JSON.stringify({
          thread: {
            id: MCP_THREAD,
            title: "Coordination hub",
            preview:
              '<in-app-browser-context source="ambient-ui-state">\nActive tab\n</in-app-browser-context>\nship it',
          },
        }),
      },
    ],
  }),
);

/// Results a harness passes on as JSON text (toolResult.ts): a one-line JSON object, an MCP
/// content list whose text is Markdown, a `{result, error}` envelope, Codex's `{output, metadata}`,
/// and a JSON file a tool read, which stays JSON as printed.
const ENVELOPE_TOOLS = [
  tool("TaskStop", "other", "completed", {
    output: JSON.stringify({
      message: "Successfully stopped task: b5muqfh92 (bun test src/net --watch)",
      task_id: "b5muqfh92",
      task_type: "local_bash",
      command: "bun test src/net --watch",
    }),
  }),
  tool("Search open issues", "search", "completed", {
    output: JSON.stringify([
      {
        type: "text",
        text: "## Open issues\n\n- **#12** Crash on launch when the cache is empty\n- **#14** Slow scroll in long chats\n- **#19** Retry button stays disabled",
      },
    ]),
  }),
  tool("Review gate", "other", "failed", {
    output: JSON.stringify({
      error: null,
      result: {
        _meta: null,
        content: [{ type: "text", text: "Tool call rejected by review. Continue without it." }],
        structuredContent: null,
      },
    }),
  }),
  tool("Run focused tests", "other", "completed", {
    output: JSON.stringify({
      output: "3 pass\n0 fail\nRan 3 tests across 1 file. [118.00ms]\n",
      metadata: { exit_code: 0, duration_seconds: 0.4 },
    }),
  }),
  // An MCP result whose text repeats its structured content: the sentence, then the payload once.
  tool("Look up the forecast", "fetch", "completed", {
    output: JSON.stringify({
      content: [
        { type: "text", text: "Sunny in Lisbon, 21 °C, wind 12 km/h from the north." },
        { type: "text", text: JSON.stringify({ city: "Lisbon", tempC: 21, sky: "sunny", windKmh: 12 }) },
      ],
      structuredContent: { city: "Lisbon", tempC: 21, sky: "sunny", windKmh: 12 },
      isError: false,
    }),
  }),
  // A JSON-RPC error: its message, then its data.
  tool("Create issue", "other", "failed", {
    output: JSON.stringify({
      jsonrpc: "2.0",
      id: 7,
      error: { code: -32602, message: "Invalid params: a title is required.", data: { field: "title", got: "" } },
    }),
  }),
  // An MCP screenshot: its sentence, and its image in the call's strip instead of base64 JSON.
  tool("Take a screenshot", "other", "completed", {
    output: JSON.stringify({
      content: [
        { type: "text", text: "Captured the build-times chart." },
        { type: "image", mimeType: "image/png", data: BUILD_TIMES_PNG },
      ],
    }),
  }),
  tool("Read package.json", "read", "completed", {
    output:
      '{\n  "name": "@cmux/webviews",\n  "private": true,\n  "type": "module",\n  "scripts": {\n    "test": "bun test"\n  }\n}\n',
  }),
];

/// A render call (renderCall.ts); one with `update` redraws the card it names and draws nothing itself.
function renderTool(page: string, update?: string) {
  return tool("mcp__cmux__render", "other", "completed", {
    inputSummary: JSON.stringify({ html: `<title>Batch report</title><p>${page}</p>`, ...(update && { id: update }) }),
    output: '{"rendered": true}',
  });
}

/// Short thoughts that draw no row once done (thoughts.ts isQuietThought).
const quietThoughts = (count: number) => Array.from({ length: count }, () => thought("ok"));

/// A person's turn, then two turns the agent ran on its own (backgroundTurns.ts): a quiet one, one
/// muted line that opens to its rows, and one with something to say, whose rows draw as they came.
const backgroundTurnRows = [
  user("Run the migration tests in the background and tell me if anything breaks", 9),
  assistant("Started the migration tests in the background.", 8.9),
  summary(8.9, { status: "completed", durationMs: 3_000 }),
  row(BACKGROUND_TURN, 7, {
    id: backgroundTurnRowId("gallery-bg-quiet"),
    background: { id: "gallery-bg-quiet", trigger: "task_notification", running: false, quiet: true },
  }),
  activity(
    [tool("tail -n 5 out.log", "execute", "completed", { command: "tail -n 5 out.log", output: "12 passed" })],
    6.9,
    { inBackground: "gallery-bg-quiet" },
  ),
  assistant("Nothing new for you yet.", 6.8, { inBackground: "gallery-bg-quiet" }),
  row(BACKGROUND_TURN, 5, {
    id: backgroundTurnRowId("gallery-bg-loud"),
    background: { id: "gallery-bg-loud", trigger: "task_notification", running: false, quiet: false },
  }),
  assistant(
    "The migration tests finished: 2 of 14 failed in `orders_backfill`. Want me to look at the failures?",
    4.9,
    { inBackground: "gallery-bg-loud" },
  ),
];

/// A long turn among turns opened by what the person never typed (incomingMessage.ts): a background
/// task's notification, a system reminder alone (no row) and another agent's message.
const foldNoBlankRows = [
  user("<task-notification><summary>Background build finished</summary></task-notification>", 9, {
    incoming: { kind: "notice", text: "Background build finished" },
  }),
  assistant("The background build finished cleanly.", 8.9),
  summary(8.9, { status: "completed", durationMs: 4_000 }),
  user("<system-reminder>bookkeeping</system-reminder>", 8, { incoming: { kind: "hidden" } }),
  activity([tool("git status", "execute", "completed", { command: "git status", output: "clean" })], 7.9),
  assistant("The tree is clean.", 7.8),
  summary(7.8, { status: "completed", toolCount: 1, durationMs: 6_000 }),
  user("[coord-deputy] The batch is next.", 7, {
    incoming: {
      kind: "message",
      message: { name: "coord-deputy", text: "The batch is next.", raw: "[coord-deputy] The batch is next." },
    },
  }),
  user("Run the batch and report what it changed", 6, { id: "fold-no-blank-user" }),
  activity(
    [
      thought("Check how the batch script is laid out before running it, then run it once."),
      tool("ls /tmp/batch", "execute", "completed", { command: "ls /tmp/batch", output: "batch32.sh\nout.log" }),
      tool("cat /tmp/batch/batch32.sh", "execute", "completed", {
        command: "cat /tmp/batch/batch32.sh",
        output: "set -e",
      }),
    ],
    5.8,
  ),
  activity(quietThoughts(6), 5.6),
  activity(
    [
      tool("Edit batch32.sh", "edit", "completed", {
        diffs: [{ path: "/tmp/batch/batch32.sh", oldText: "set -e\n", newText: "set -e\necho one\necho two\n" }],
      }),
      tool("bash /tmp/batch/batch32.sh", "execute", "completed", {
        command: "bash /tmp/batch/batch32.sh",
        output: Array.from({ length: 40 }, (_, index) => `step ${index + 1}: ok`).join("\n"),
      }),
      renderTool("first page"),
      renderTool("second page", "batch-report"),
      renderTool("third page", "batch-report"),
    ],
    4,
  ),
  activity(quietThoughts(4), 3.2),
  assistant("The batch ran. It changed three files:\n\n- one\n- two\n- three", 3),
  summary(3, { status: "completed", toolCount: 6, durationMs: 132_000 }),
];

// A Claude Bash call's permission as claude-agent-acp sends it: its title is the command line (so
// its first line reads "bash -c '"), its description says what it does, and the script runs long.
const BASH_SCRIPT = [
  "bash -c '",
  "# Rebuild the pane bundle and check it before the push",
  "set -euo pipefail",
  "cd webviews",
  "bun install --frozen-lockfile",
  "bun run check",
  "bun run build:agent-pane",
  "git status --short",
  "'",
].join("\n");
const BASH_PERMISSION = chat(
  [
    user("Rebuild the pane and check it", 1),
    activity([tool("bash -c '", "execute", "pending", { command: BASH_SCRIPT })], 0.9),
  ],
  {
    isWorking: true,
    permission: {
      permissionId: "gallery-permission",
      title: "`bash -c '",
      kind: "execute",
      command: BASH_SCRIPT,
      description: "Rebuild the pane bundle and run its checks",
      rule: "Allow bun run check:* for this session",
      pending: true,
      options: [
        { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
        { id: "allow_always", name: "Always Allow", kind: "allow_always", allow: true },
        { id: "reject_once", name: "Reject", kind: "reject_once", allow: false },
      ],
    },
  },
);

export default agentPaneEntry({
  id: "agent-pane.transcript",
  title: "Transcript rows",
  area: "Agent pane",
  height: 560,
  checks: {
    longFrameFailMs: {
      value: 33,
      reason: "Transcript disclosures should settle without a frame longer than two display frames.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Opening a shell disclosure is a local interaction and should settle within a quarter second.",
    },
  },
  covers: [
    "page:cmux.agent",
    "agent-session/acpmux/App.tsx#VirtualTranscript",
    "agent-session/acpmux/App.tsx#AcpmuxApp",
    "agent-session/acpmux/SecretCard.tsx#SecretCard",
    "agent-session/acpmux/conversation/ChatFindScope.tsx#ChatFindScope",
    "agent-session/acpmux/conversation/MessageCard.tsx",
    "agent-session/acpmux/conversation/ThoughtRow.tsx#ThoughtRow",
    "agent-session/acpmux/conversation/Markdown.tsx",
    "agent-session/acpmux/conversation/RevealedMarkdown.tsx",
    "agent-session/acpmux/conversation/CodeBlock.tsx",
    "agent-session/acpmux/conversation/HighlightedCode.tsx",
    "agent-session/acpmux/conversation/DiagramBlock.tsx",
    "agent-session/acpmux/conversation/StreamingCode.tsx",
    "agent-session/acpmux/conversation/Math.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/conversation/BlockParts.tsx",
    "agent-session/acpmux/chips/ReplyMedia.tsx",
    "agent-session/acpmux/conversation/icons.tsx#Expand",
    "agent-session/acpmux/conversation/ToolRun.tsx",
    "agent-session/acpmux/conversation/transcriptDisclosure.tsx#TranscriptDisclosureProvider",
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
    "agent-session/acpmux/conversation/McpCallRows.tsx#McpCallRows",
    "agent-session/acpmux/conversation/CommandRow.tsx",
    "agent-session/acpmux/conversation/ShellBlock.tsx#ShellBlock",
    "agent-session/acpmux/conversation/CopyButton.tsx#CopyButton",
    "agent-session/acpmux/conversation/toolOutput.tsx#OutputMore",
    "agent-session/acpmux/conversation/EditDiff.tsx",
    "agent-session/acpmux/conversation/EditDiffHunks.tsx",
    "agent-session/acpmux/conversation/EditedFilesCard.tsx",
    "agent-session/acpmux/conversation/PreviewCard.tsx",
    "agent-session/acpmux/conversation/Thinking.tsx",
    "agent-session/acpmux/conversation/WorkingFor.tsx",
    "agent-session/acpmux/conversation/TurnRows.tsx",
    "agent-session/acpmux/conversation/DateLine.tsx",
    "agent-session/acpmux/conversation/PromptDelivery.tsx#DeliveryFailure",
    "agent-session/acpmux/conversation/PromptDelivery.tsx#DeliveryMark",
    "agent-session/acpmux/conversation/PromptDelivery.tsx#FailedSendsContext",
    "agent-session/acpmux/conversation/icons.tsx#Clock",
    "agent-session/acpmux/conversation/icons.tsx#DoubleCheck",
    "agent-session/acpmux/conversation/icons.tsx#MultiTool",
    "agent-session/acpmux/PermissionCard.tsx",
    "agent-session/acpmux/chips/BareReferenceChip.tsx#BareReferenceChip",
  ],
  variants: {
    "activity-tone-secondary": {
      note: "Selected activity hierarchy: tool calls, Worked for and received peer messages (their Markdown too) use one AA-readable secondary tone; prompts and assistant text stay primary. Capture in light and dark.",
      snapshot: messageSurfaceChat,
    },
    "activity-tone-tertiary": {
      note: "Gallery arm: a stronger tertiary dimming for background activity, checked against the same light/dark fixture.",
      snapshot: messageSurfaceChat,
      documentAttributes: { "transcript-activity-tone": "tertiary" },
    },
    "activity-tone-readable": {
      note: "Gallery arm: the most readable secondary tone, compared with the selected middle value before landing.",
      snapshot: messageSurfaceChat,
      documentAttributes: { "transcript-activity-tone": "readable" },
    },
    "message-surfaces-bordered": {
      note: "Before arm: the bordered user bubble and agent-message cards, captured on busy wallpaper and plain dark surfaces in light and dark themes.",
      documentAttributes: { "message-surfaces": "bordered" },
      snapshot: messageSurfaceChat,
    },
    "message-surfaces-soft": {
      note: "Gallery arm: borderless, with a soft fill only behind an opened agent-message card, and no rim.",
      documentAttributes: { "message-surfaces": "soft" },
      snapshot: messageSurfaceChat,
    },
    "message-surfaces-borderless": {
      note: "Selected arm: stronger glass fill and no rim (Plain, Lens or Spectrum) for the user's prompt, borderless agent-message cards, no layout changes.",
      snapshot: messageSurfaceChat,
      play: messageSurfaceComputedStyle,
    },
    conversation: {
      note: "A finished exchange: prompt, markdown reply, turn footer.",
      snapshot: completedFooterSnapshot,
    },
    "footer-actions-left": {
      note: "A completed answer keeps Copy and Retry at the transcript's left edge.",
      theme: { turnActionsPlacement: "left" },
      snapshot: completedFooterSnapshot,
      play: footerActionsPlacement("left"),
    },
    "footer-actions-right": {
      note: "A completed answer keeps Copy and Retry at the transcript's right edge.",
      theme: { turnActionsPlacement: "right" },
      snapshot: completedFooterSnapshot,
      play: footerActionsPlacement("right"),
    },
    "github-references": {
      note: "Issue and pull request references link in prose while code stays untouched.",
      ready: { githubRepository: "manaflow-ai/cmux" },
      native: { "git.githubRepository": { repository: "manaflow-ai/cmux" } },
      snapshot: chat([
        user("Please review #18325 and manaflow-ai/cmux#18321", 3),
        assistant(
          "The fixes are in #18325.\n\n`#18325` stays code, and fenced examples stay code too:\n\n```text\n#18321\n```",
          2,
        ),
        summary(2, { status: "completed", durationMs: 12_000 }),
      ]),
    },
    "github-references-other-repo": {
      note: "A chat whose folder is leo-workspace names cmux pull requests by bare number: each chip links to the repository the transcript and the App's pull request cache say has it, not the folder's. Hover #24175 for its card.",
      ...LEO_WORKSPACE,
      snapshot: chat([
        user("Where are the agent pane fixes?", 6),
        activity(
          [tool(LANE_LIST, "execute", "completed", { command: LANE_LIST, output: LANE_OUTPUT, exitCode: 0 })],
          5.8,
        ),
        assistant(
          `Merged ${LANE_NUMBERS.map((number) => `#${number}`).join(", ")}. The rulebook change is still open.`,
          5.6,
        ),
        summary(5.6, { status: "completed", durationMs: 14_000 }),
      ]),
      play: hoverReference(24175, ".cv-link-preview.acpmux-pr-card"),
    },
    "github-references-same-number": {
      note: "A bare #843 is a pull request in both leo-workspace (the folder's) and cmux (which the chat linked): the chip names its repository.",
      ...LEO_WORKSPACE,
      snapshot: chat([
        user("Compare with https://github.com/manaflow-ai/cmux/pull/24175", 4),
        assistant("#843 has the rule; the app change follows it.", 3.8),
        summary(3.8, { status: "completed", durationMs: 6_000 }),
      ]),
      play: hoverReference(843, ".cv-link-preview.acpmux-pr-card"),
    },
    "github-references-quoted-numbers": {
      note: 'Leo 2026-10-29: "these auto render to the pr instead of just #1 #2...". The reply quotes his "what is #1 / #2": in the quote and in prose they stay text (the chat named #27262, so a one-digit number is no cmux pull request); #27262 and manaflow-ai/cmux#27262 stay chips.',
      ready: { githubRepository: "manaflow-ai/cmux" },
      native: { "git.githubRepository": { repository: "manaflow-ai/cmux" } },
      snapshot: chat([
        user("Is https://github.com/manaflow-ai/cmux/pull/27262 green? Also what is #1 / #2", 3),
        assistant(
          "> what is #1 / #2\n\nThose are the two options I listed: #1 keeps the dock, #2 drops it. #27262 (manaflow-ai/cmux#27262) is green.",
          2,
        ),
        summary(2, { status: "completed", durationMs: 9_000 }),
      ]),
    },
    tasks: {
      note: "Checked, unchecked, nested and wrapping task-list items.",
      snapshot: chat([user("Review the release checklist", 4), assistant(TASKS_REPLY, 3)]),
    },
    thinking: {
      note: "A turn that started and has no output yet: Thinking alone, with no blinking dots before it; the word itself shimmers in the theme accent, as in the Codex app (still under Reduce Motion). Play: the shimmer is the line's only loop.",
      snapshot: chat([user(prompt, 0.2)], { isWorking: true }),
      play: runningLineStill(/^Thinking/, true),
    },
    streaming: {
      note: "A reply still streaming (its last block still open).",
      snapshot: chat(
        [
          user(prompt, 1),
          assistant(
            "I'll start with the retry policy type, then wire it into `request`:\n\n```ts\nexport type RetryPolicy = {\n  attempts?: number;",
            0.5,
            {
              streaming: true,
            },
          ),
        ],
        { isWorking: true },
      ),
    },
    "copy-last-code-block": {
      note: "Play: Copy Last Code Block (cx-ncc.72, Codex parity) hands the app the last fenced block of the latest reply, not an earlier one.",
      snapshot: chat([
        user(prompt, 6),
        assistant("First try:\n\n```ts\nretry(fetch, 3);\n```", 5),
        summary(4.9, { status: "completed" }),
        user("Cap the backoff too", 3),
        assistant(
          "Two changes:\n\n```ts\nconst delay = Math.min(cap, base * 2 ** attempt);\n```\n\nand the call:\n\n```ts\nretry(fetch, { attempts: 3, cap: 8000 });\n```\n\nDone.",
          2,
        ),
        summary(1.9, { status: "completed" }),
      ]),
      play: async (ctx) => {
        await ctx.focus({ selector: "[contenteditable='true']" });
        const page = ctx.document.defaultView as unknown as {
          cmuxAcpmuxBridge?: { lastCodeBlock?(): string | null };
        };
        await ctx.waitFor(() => page.cmuxAcpmuxBridge?.lastCodeBlock !== undefined);
        const copied = page.cmuxAcpmuxBridge?.lastCodeBlock?.();
        if (copied !== "retry(fetch, { attempts: 3, cap: 8000 });") throw new Error(`copied ${JSON.stringify(copied)}`);
      },
    },
    "archive-chat-key": {
      note: "Play: Archive Chat (cx-ncc.72) archives the chat over the pane's own acpmux connection (cx-jlzsf), then asks the app to close its tab.",
      ready: { transport: "mock" },
      snapshot: chat([user(prompt, 2), assistant("Done.", 1), summary(0.9, { status: "completed" })]),
      checks: mockDaemonFrames,
      play: async (ctx) => {
        const page = ctx.document.defaultView as unknown as {
          cmuxAcpmuxBridge?: { command?(name: string): void };
          cmuxGalleryLog: GalleryCall[];
        };
        await chatMenuReady(ctx);
        await ctx.focus({ selector: "[contenteditable='true']" });
        page.cmuxAcpmuxBridge?.command?.("archiveChat");
        // The tab closes only after acpmux took the tag.
        await ctx.waitFor(() =>
          page.cmuxGalleryLog.some(({ method, params }) => method === "pane.action" && params?.id === "closeTab"),
        );
        const archived = page.cmuxGalleryLog.find(({ method }) => method === "acpmux _acpmux/archive");
        if (archived?.params?.archived !== true || !archived.params.sessionId)
          throw new Error(`Archive did not go to acpmux: ${JSON.stringify(archived)}`);
        if (page.cmuxGalleryLog.some(({ method }) => method === "chat.archive"))
          throw new Error("archive went to the host bridge");
      },
    },
    "fork-any-turn": {
      note: "Play: a Claude chat offers Fork under every completed turn (cx-yqiv, Codex parity); an earlier turn's forks through that turn.",
      snapshot: forkTurns("claude"),
      play: forkEarlierTurn,
    },
    "fork-any-turn-codex": {
      note: "Play: a Codex chat offers Fork under every completed turn too (cx-a7r); an earlier turn's forks through that turn.",
      snapshot: forkTurns("codex"),
      play: forkEarlierTurn,
    },
    "fork-latest-turn-only": {
      note: "Play: another agent forks only at a chat's end, so only the latest turn offers Fork.",
      snapshot: forkTurns(undefined),
      play: async (ctx) => {
        await ctx.focus({ selector: "[contenteditable='true']" });
        await ctx.waitFor(
          () => ctx.document.querySelectorAll('.cv-turn-actions button[aria-label="Fork from here"]').length === 1,
        );
      },
    },
    "mark-unread-menu": {
      note: "Play: the chat menu's Mark as Unread (cx-ncc.78, Codex parity) asks acpmux on the pane's own connection (cx-jlzsf), never the host.",
      // The whole chat menu fits, so its last rows are on screen for the click.
      height: 900,
      ready: { transport: "mock" },
      snapshot: chat([user(prompt, 2), assistant("Done.", 1), summary(0.9, { status: "completed" })]),
      checks: mockDaemonFrames,
      play: async (ctx) => {
        const page = ctx.document.defaultView as unknown as { cmuxGalleryLog: GalleryCall[] };
        await chatMenuReady(ctx);
        await ctx.click({ role: "button", name: "Chat actions" });
        await ctx.click({ role: "menuitem", name: "Mark as Unread" });
        await ctx
          .waitFor(() =>
            page.cmuxGalleryLog.some(
              ({ method, params }) => method === "acpmux _acpmux/markUnread" && params?.sessionId,
            ),
          )
          .catch((error: unknown) => {
            throw new Error(
              `${String(error)}; calls: ${JSON.stringify(page.cmuxGalleryLog.slice(-12).map((c) => c.method))}`,
            );
          });
        if (page.cmuxGalleryLog.some(({ method }) => method === "chat.markUnread"))
          throw new Error("mark unread went to the host bridge");
      },
    },
    "harness-health-acpmux": {
      note: "Play: the chat's agent CLI health (cx-ny85) is read from acpmux on the pane's own connection (cx-jlzsf), never the host.",
      ready: { transport: "mock" },
      snapshot: chat([user(prompt, 2), assistant("Done.", 1), summary(0.9, { status: "completed" })]),
      checks: mockDaemonFrames,
      play: async (ctx) => {
        const page = ctx.document.defaultView as unknown as { cmuxGalleryLog: GalleryCall[] };
        await chatMenuReady(ctx);
        await ctx.focus({ selector: "[contenteditable='true']" });
        await ctx.waitFor(() => page.cmuxGalleryLog.some(({ method }) => method === "acpmux _acpmux/harness/health"));
        if (page.cmuxGalleryLog.some(({ method }) => method === "harness.health"))
          throw new Error("harness health went to the host bridge");
      },
    },
    "toolsearch-hidden": {
      note: "A worked turn whose agent called Claude Code's ToolSearch (it only loads deferred tools' schemas) before a Read and a command, its fold open. The rows come from the transcript's own ACP-to-row mapping (childRows), so ToolSearch draws no row and the summary counts two calls.",
      snapshot: chat(toolSearchTurn()),
      play: openWorked,
    },
    "side-chat-acpmux": {
      note: "Play: New side chat (the chat menu's chat.side action) forks the chat, has acpmux tag the fork the chat's side chat on the pane's own connection (cx-jlzsf), then asks the app only to open it beside the chat.",
      ready: { transport: "mock" },
      snapshot: chat([user(prompt, 2), assistant("Done.", 1), summary(0.9, { status: "completed" })]),
      checks: mockDaemonFrames,
      play: async (ctx) => {
        const page = ctx.document.defaultView as unknown as {
          cmuxGalleryLog: GalleryCall[];
          cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => unknown>;
        };
        await chatMenuReady(ctx);
        await ctx.focus({ selector: "[contenteditable='true']" });
        // The menu row's own call (header/sideChatRow.ts): through the chat's last turn.
        void page.cmuxAcpmuxActions?.["chat.side"]?.({ throughSeq: Number.MAX_SAFE_INTEGER });
        await ctx
          .waitFor(() => page.cmuxGalleryLog.some(({ method }) => method === "chat.sideChat"))
          .catch((error: unknown) => {
            throw new Error(
              `${String(error)}; calls: ${JSON.stringify(page.cmuxGalleryLog.slice(-12).map((c) => c.method))}`,
            );
          });
        const order = page.cmuxGalleryLog.map(({ method }) => method);
        const side = page.cmuxGalleryLog.find(({ method }) => method === "acpmux _acpmux/side");
        if (!side?.params?.sessionId || order.indexOf("acpmux _acpmux/side") > order.indexOf("chat.sideChat"))
          throw new Error(
            `acpmux did not tag the side chat before the app opened it: ${JSON.stringify(order.slice(-8))}`,
          );
      },
    },
    "thought-row": {
      note: 'Play: a finished thought is one quiet row, "Thought for 12s" with none of its text inline and no tooltip, as Claude Desktop and Codex draw it (Leo 2026-10-20: "Thought <first line>" read weird). Debug Settings agentPane.debug.thoughtFoldThreshold "Taller than the transcript" brings back the short thought in full after Thought.',
      snapshot: thoughtChat([thought(SHORT_THOUGHT, { startedAt: 0, endedAt: 12_000 })]),
      play: async (ctx) => {
        const row = () => ctx.document.querySelector<HTMLElement>(".cv-thought");
        await ctx.waitFor(() => row()?.textContent === "Thought for 12s");
        await ctx.hover({ selector: ".cv-thought" });
        if (!row()!.matches("button") || row()!.getAttribute("aria-expanded") !== "false")
          throw new Error("a finished thought is a closed toggle");
        if (Math.round(row()!.getBoundingClientRect().height) !== 22)
          throw new Error("a finished thought uses the compact 22px tool-row rhythm");
        if (ctx.document.querySelector(".cv-thought__text") || ctx.document.body.textContent?.includes("jittered"))
          throw new Error("a folded thought shows none of its text");
        if (row()!.closest("[title]") || row()!.querySelector("[title]")) throw new Error("a thought shows no tooltip");
      },
    },
    "thought-expanded": {
      note: "Play: the folded thought opens to its full text under one left rule; the line still reads Thought for 12s.",
      checks: {
        layoutShiftMax: {
          value: 0.02,
          reason:
            "Opening the thought pushes the rows below it down by its text, on purpose; Chromium measured 0.0103, so the budget leaves room for fractional rounding.",
        },
      },
      snapshot: thoughtChat([thought(SHORT_THOUGHT, { startedAt: 0, endedAt: 12_000 })]),
      play: async (ctx) => {
        await ctx.click({ selector: "button.cv-thought" });
        const body = () => ctx.document.querySelector<HTMLElement>(".cv-thought__body");
        await ctx.waitFor(() => body()?.textContent?.includes("jittered backoff capped at three attempts") ?? false);
        if (ctx.document.querySelector("button.cv-thought")?.getAttribute("aria-expanded") !== "true")
          throw new Error("the opened thought is not expanded");
      },
    },
    "thoughts-merged": {
      note: "Play: two thoughts side by side in one step (as when a call a permission ask holds out of the transcript sat between them) are one row for the sum of their times, 4s and 8s, opening to both texts.",
      checks: {
        layoutShiftMax: {
          value: 0.01,
          reason: "Opening the thought pushes the rows below it down by its text, on purpose.",
        },
      },
      snapshot: thoughtChat([
        thought("Check how the helper parses errors first.", { startedAt: 0, endedAt: 4_000 }),
        thought("On second thought, the retry wrapper swallows the status, so a 429 looks like a network failure.", {
          startedAt: 9_000,
          endedAt: 17_000,
        }),
      ]),
      play: async (ctx) => {
        const rows = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-thought")];
        await ctx.waitFor(() => rows()[0]?.textContent === "Thought for 12s");
        if (rows().length !== 1) throw new Error(`two thoughts side by side draw ${rows().length} rows, not one`);
        await ctx.click({ selector: "button.cv-thought" });
        const body = () => ctx.document.querySelector<HTMLElement>(".cv-thought__body")?.textContent ?? "";
        await ctx.waitFor(() => body().includes("parses errors first") && body().includes("On second thought"));
      },
    },
    "thought-quiet": {
      note: "Play: an empty thought (Claude's omitted or redacted thinking) and a short one done in under a second draw no row; the step shows its calls alone.",
      snapshot: thoughtChat(
        [thought("", { startedAt: 0, endedAt: 0 })],
        [thought("I am here", { startedAt: 0, endedAt: 300 })],
      ),
      play: async (ctx) => {
        // The step draws its calls (a live run may show only its newest), and nothing else.
        await ctx.waitFor(() => ctx.document.querySelector(".cv-tools .cv-tool"));
        await ctx.hover({ selector: ".cv-tools .cv-tool" });
        if (ctx.document.querySelector(".cv-thought")) throw new Error("a quiet thought draws a row");
        if (ctx.document.body.textContent?.includes("I am here")) throw new Error("a quiet thought shows its text");
      },
    },
    "thought-streaming-short": {
      note: 'A short thought still streaming (Debug toggle agentPane.debug.codexToolRuns off, where the live thought draws in the run) reads "Thinking" on its own line with the text under it, never "Thought I am here" as one sentence (Leo 2026-10-21).',
      theme: { codexToolRuns: false },
      snapshot: chat(
        [
          user(prompt, 2),
          activity(
            [thought("I am here, reading the retry helper before changing it.", { startedAt: 0, endedAt: 2_000 })],
            1.5,
          ),
        ],
        { isWorking: true },
      ),
      play: async (ctx) => {
        const label = () => ctx.document.querySelector<HTMLElement>(".cv-thought__label");
        await ctx.waitFor(() => label()?.textContent === "Thinking");
        if (!ctx.document.querySelector(".cv-thought.is-full"))
          throw new Error("the live thought's text is not under its label");
      },
    },
    "thought-codex-headings": {
      note: 'Play: a Codex reasoning summary opened: "Thought for 12s", then each **Heading** as a muted title of its own over its text, never with its marks and never after "Thought".',
      checks: {
        layoutShiftMax: {
          value: 0.01,
          reason: "Opening the thought pushes the rows below it down by its text, on purpose.",
        },
      },
      snapshot: thoughtChat([
        thought(
          "**Planning the retry fix**\n\nThe retry wrapper in src/net/client.ts swallows the status code, so a 429 looks like a network failure.\n\n**Checking the callers**\n\nTwo call sites pass their own timeout; both keep working with a capped backoff.",
          { startedAt: 0, endedAt: 12_000 },
        ),
      ]),
      play: async (ctx) => {
        await ctx.click({ selector: "button.cv-thought" });
        const titles = () => [...ctx.document.querySelectorAll(".cv-thought__title")].map((node) => node.textContent);
        await ctx.waitFor(() => titles().length === 2);
        if (ctx.document.querySelector(".cv-thought__body")?.textContent?.includes("**"))
          throw new Error("a heading shows its ** marks");
      },
    },
    "long-thought-streaming": {
      note: "A long thought still streaming holds a seven-line viewport with its newest line in view (Debug toggle agentPane.debug.liveThoughtViewport) and folds once done; with agentPane.debug.foldLongThoughts off, it shows in full.",
      snapshot: chat([user(prompt, 2), activity([thought(LONG_THOUGHT)], 1.5)], {
        isWorking: true,
      }),
    },
    "long-thought-done": {
      note: 'A long thought followed by a step folds to "Thought for 12s" (with Debug Settings agentPane.debug.thoughtHeader preview, "Thought" and its first line); with agentPane.debug.foldLongThoughts off (data-fold-long-thoughts="off" on <html>), it shows in full as before.',
      snapshot: chat(
        [
          user(prompt, 2),
          activity(
            [
              thought(LONG_THOUGHT, { startedAt: 0, endedAt: 12_000 }),
              tool("Read client.ts", "read", "completed", {
                locations: [{ path: "/Users/you/src/atlas-web/src/net/client.ts" }],
              }),
            ],
            1.5,
          ),
        ],
        { isWorking: true },
      ),
    },
    "thought-find": {
      note: "Play: Find in Chat for a word in a thought marks the word in its text, never the row's own Thought label (cx-ncc.73).",
      checks: {
        longFrameFailMs: {
          value: 80,
          reason:
            "The key that opens the closed Worked for fold still re-renders the whole pane once (the fold state lives in AcpmuxPane; Find state moved below it in cx-ncc.86): 70-120 ms at 4x CPU throttle in dev React, other keys now render the transcript alone.",
        },
        layoutShiftMax: {
          value: 0.05,
          reason:
            "Find opens the fold that holds the match, which moves the rows below on purpose. Rows sit at their `top` (a translate put the line above the pointer under a drag, PR 23826), so that move counts as a layout shift: 0.034 in Chromium.",
        },
      },
      snapshot: chat([
        user(prompt, 2),
        activity(
          [
            thought(
              "Check how the helper parses errors first.\n\nOn second thought, the retry wrapper swallows the status.",
            ),
            tool("Read client.ts", "read", "completed", {
              locations: [{ path: "/Users/you/src/atlas-web/src/net/client.ts" }],
            }),
          ],
          1.5,
        ),
        assistant("Retries now stop on a 4xx.", 1),
        summary(0.9, { status: "completed" }),
      ]),
      play: async (ctx) => {
        // Cmd-F: the app sends the page `find`, and the bar takes the keyboard.
        const page = ctx.document.defaultView as unknown as {
          cmuxAcpmuxBridge?: { command?(name: string): void };
        };
        page.cmuxAcpmuxBridge?.command?.("find");
        await ctx.waitFor(() => ctx.document.activeElement?.classList.contains("find-pill__field") ?? false);
        // A key at a time, as a person types: the play's type inserts its whole text in one task,
        // which ran seven query updates and the fold opening in one frame (cx-ncc.76).
        for (const key of "thought") await ctx.type(key);
        const active = () => {
          const highlights = (ctx.document.defaultView as unknown as { CSS: { highlights?: Map<string, Set<Range>> } })
            .CSS.highlights;
          return [...(highlights?.get("acpmux-find-active") ?? [])][0];
        };
        await ctx.waitFor(() => active() !== undefined);
        const at = active()!.startContainer.parentElement;
        if (!at?.closest(".cv-thought__text"))
          throw new Error(`the current match is not in the thought's text: ${at?.className ?? "none"}`);
      },
    },
    "takeaways-stay-open": {
      note: 'A long finished turn (synthetic text): the closing "Pushed." stays in sight, and the earlier dialogue folds into one Worked-for line.',
      snapshot: chat(takeawayTurnRows),
    },
    "takeaways-fold-open": {
      note: "The same turn with Worked for opened: every command, intermediate answer, short note, and compaction remains in order.",
      snapshot: chat(takeawayTurnRows),
      play: (ctx) => ctx.click({ selector: ".cv-worked" }),
    },
    "working-tools": {
      note: "Tool calls running in a live turn; the status line names the call in flight.",
      snapshot: chat(
        [
          user(prompt, 2),
          activity(
            [
              thought("The helper lives in src/net/client.ts; check how errors are parsed first."),
              tool("Read client.ts", "read", "completed", {
                locations: [{ path: "/Users/you/src/atlas-web/src/net/client.ts" }],
              }),
              tool("Search for parseError", "search", "completed"),
              tool("bun test src/net", "execute", "in_progress", {
                command: "bun test src/net",
                startedAt: minutesAgo(0.3),
              }),
            ],
            1.5,
          ),
        ],
        { isWorking: true },
      ),
    },
    "working-thinking": {
      note: "A turn before its first output: the last row reads Thinking with the turn's time, ticking.",
      snapshot: chat([user(prompt, 0.2)], { isWorking: true }),
    },
    "working-after-text": {
      note: "Text after work while the turn goes on (the agent thinks, or writes a call's input): the line stays under it and its clock keeps going.",
      snapshot: chat(
        [
          user(prompt, 1.5),
          activity(
            [
              tool("Read client.ts", "read", "completed", {
                locations: [{ path: "/Users/you/src/atlas-web/src/net/client.ts" }],
              }),
            ],
            1.4,
          ),
          assistant("The parser drops the status code. I'll write a typed error and a test for it.", 1.2),
        ],
        { isWorking: true },
      ),
    },
    "working-line-above": {
      note: "Debug toggle agentPane.debug.liveLineBelow off: the older line over the turn's work.",
      theme: { liveLineBelow: false },
      snapshot: chat(
        [
          user(prompt, 2),
          activity([tool("bun test src/net", "execute", "in_progress", { command: "bun test src/net" })], 1.5),
        ],
        { isWorking: true },
      ),
    },
    "steer-continuous": {
      note: "A message sent now while the turn ran, to an agent that cannot steer: acpmux stopped that turn and ran the message next, yet it reads as one turn. The message draws inline with no mark of its own, the line counts from the first prompt, and nothing says the turn was stopped.",
      snapshot: chat(
        [
          user("Fix the flaky login test", 1.5),
          activity(
            [
              thought("The login test fails one run in five; check how the retry waits for the session."),
              tool("bun test src/auth/login", "execute", "completed", { command: "bun test src/auth/login" }),
            ],
            1.3,
          ),
          assistant("The retry races the session refresh: it reads the old token before the refresh lands.", 0.9),
          summary(0.58, { status: "cancelled", durationMs: 55_000, continued: true }),
          user("Also check the logout path, it uses the same retry", 0.58, { continues: true }),
          activity(
            [
              tool("bun test src/auth/logout", "execute", "in_progress", {
                command: "bun test src/auth/logout",
                startedAt: minutesAgo(0.3),
              }),
            ],
            0.3,
          ),
        ],
        { isWorking: true },
      ),
    },
    "steer-ended": {
      note: "A turn Leo steered, once it ended: the whole connected turn folds under one Worked for keyed by its prompt, with the answer below it. Play: that fold opens on the call before the steer, the reply, the steer, then the call after it, in the order they ran.",
      snapshot: chat([
        user("Fix the flaky login test", 3, { id: "steer-ended-prompt" }),
        activity(
          [
            thought("The login test fails one run in five; check how the retry waits for the session."),
            tool("bun test src/auth/login", "execute", "completed", { command: "bun test src/auth/login" }),
          ],
          2.8,
        ),
        assistant("The retry races the session refresh: it reads the old token before the refresh lands.", 2.4),
        user("Also check the logout path, it uses the same retry", 2.2, { id: "steer-ended-steer", continues: true }),
        activity(
          [tool("bun test src/auth/logout", "execute", "completed", { command: "bun test src/auth/logout" })],
          1.8,
        ),
        assistant("Both paths now wait for the refresh before they retry, and both tests pass.", 1.2),
        summary(1.2, { status: "completed", toolCount: 2, durationMs: 108_000 }),
      ]),
      play: async (ctx: PlayContext) => {
        // A finished turn draws one fold, the prompt's; the steer and the work after it open inside it.
        const fold = '[data-row-id="worked-steer-ended-prompt"] .cv-worked';
        await ctx.click({ selector: fold });
        await ctx.waitFor(() => ctx.find({ selector: fold }).getAttribute("aria-expanded") === "true");
        await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="steer-ended-steer"]'));
      },
    },
    "working-tokens": {
      note: "A live Claude turn says its tokens so far after its time, on its one live line at the bottom: Thinking 5m 54s · ↓ 12.4K out ↑ 2.1M in. Output comes first, as Anthropic counts a turn, and is only what the model generated (never folded into one total with the context); then all it read (fresh input, cache reads and writes, named on hover). The time and the tokens are in the line's quieter color, in tabular numerals. No blinking dots before it and no Working for over the turn. A harness that does not report each call shows the time alone. Play: the line holds still.",
      snapshot: chat(
        [
          user(prompt, 5.9),
          activity(
            [
              thought("The helper lives in src/net/client.ts; check how errors are parsed first."),
              tool("Read client.ts", "read", "completed", {
                locations: [{ path: "/Users/you/src/atlas-web/src/net/client.ts" }],
              }),
              tool("Search for parseError", "search", "completed"),
            ],
            5.85,
          ),
          assistant("The parser drops the status code; I'll keep it and retry only on 5xx.", 5.5),
        ],
        {
          isWorking: true,
          turnTokens: 12_400,
          turnTokenSplit: { output: 12_400, input: 18_000, cacheRead: 2_080_000, cacheWrite: 42_000 },
        },
      ),
      play: runningLineStill(/^Thinking/, true),
    },
    "working-tokens-total": {
      note: "A live turn whose calls named their output but not what they read: the line says the output alone, Thinking 5m 54s · 2.1M out, in the same quieter color.",
      snapshot: chat(
        [
          user(prompt, 5.9),
          activity([tool("Search for parseError", "search", "completed")], 5.85),
          assistant("The parser drops the status code; I'll keep it and retry only on 5xx.", 5.5),
        ],
        { isWorking: true, turnTokens: 2_140_000 },
      ),
      play: runningLineStill(/^Thinking/, true),
    },
    "worked-tokens": {
      note: "A finished Claude turn: its Worked for line says the turn's tokens from its result, output first (↓ 9.8K out ↑ 1.4M in), with its time and tokens in the line's quieter color.",
      snapshot: chat([
        user(prompt, 5.9),
        activity(
          [
            tool("Read client.ts", "read", "completed", {
              locations: [{ path: "/Users/you/src/atlas-web/src/net/client.ts" }],
            }),
            tool("Search for parseError", "search", "completed"),
          ],
          5.85,
        ),
        assistant("The parser now keeps the status code and retries only on 5xx.", 4.6),
        summary(4.6, {
          status: "completed",
          toolCount: 2,
          durationMs: 78_000,
          tokens: { output: 9_800, input: 12_000, cacheRead: 1_360_000, cacheWrite: 31_000 },
        }),
      ]),
    },
    "working-counts": {
      note: "A live turn with background work: the line counts the two agents still running and the dev server still up, not the agent that finished. A count opens what it counts.",
      snapshot: chat(
        [
          user("Start the dev server", 9),
          activity(
            [
              tool("npm run dev", "execute", "completed", {
                command: "npm run dev",
                inputSummary: JSON.stringify({ command: "npm run dev", run_in_background: true }),
              }),
            ],
            8.9,
          ),
          assistant("The dev server is up on port 5173.", 8.8),
          summary(8.8, { status: "completed" }),
          user(prompt, 3),
          row(SUBAGENTS, 2.8, {
            subagents: [
              { id: "agent-retries", parent: null, name: "Retry policy", state: "running", startedAt: minutesAgo(2.8) },
              { id: "agent-tests", parent: null, name: "Test coverage", state: "running", startedAt: minutesAgo(2.8) },
              {
                id: "agent-errors",
                parent: null,
                name: "Error parsing",
                state: "completed",
                startedAt: minutesAgo(2.8),
                endedAt: minutesAgo(1.6),
              },
            ],
          }),
          activity([tool("Read client.ts", "read", "in_progress")], 1.5),
        ],
        { isWorking: true },
      ),
    },
    "dense-live-run": {
      note: "A running turn folds its finished calls into one counted summary line (Read a file, ran 7 commands) and names the running MCP call on the live line, never a growing stack of rows.",
      snapshot: chat(
        [
          user("Find why the sidebar drag drops tabs, and hand the fix to a sub-session.", 3),
          assistant("I'll look at the drag handlers and the recent changes first.", 2.9),
          activity(
            [
              ...DENSE_COMMANDS.map((command) => shellTool(command)),
              tool("Read SidebarDrag.tsx", "read", "completed"),
              tool("mcp__cmux-subsessions__start_session", "other", "in_progress", {
                inputSummary: JSON.stringify({ name: "sidebar-drag-bugs", prompt: "Fix the sidebar drag bugs" }),
              }),
            ],
            2.8,
          ),
        ],
        { isWorking: true },
      ),
    },
    "consolidated-run": {
      note: "An opened Worked for: reads, searches and commands with thoughts between them fold into one counted line (Read 3 files, ran a search, ran 2 commands, 1 failed); the edit stays in sight between the lines, and the reply stays below the fold.",
      snapshot: chat(
        [
          user(prompt, 6),
          activity(
            [
              tool("Read client.ts", "read", "completed", { locations: [{ path: "src/net/client.ts" }] }),
              thought("The helper throws on any non-2xx status, so the retry has to sit around fetchJson itself."),
              tool("Search for fetchJson", "search", "completed"),
              tool("Read errors.ts", "read", "completed", { locations: [{ path: "src/net/errors.ts" }] }),
              thought("Check whether any caller already retries before adding a second layer of backoff."),
              tool("grep -rn retry src/net", "execute", "completed", {
                command: "grep -rn retry src/net",
                exitCode: 1,
              }),
              tool("Read client.test.ts", "read", "completed", { locations: [{ path: "src/net/client.test.ts" }] }),
              tool("bun test src/net", "execute", "completed", { command: "bun test src/net", exitCode: 0 }),
              tool("Edit client.ts", "edit", "completed", {
                locations: [{ path: "src/net/client.ts" }],
                diffs: [
                  {
                    path: "src/net/client.ts",
                    oldText: "export async function fetchJson(url: string) {\n  return request(url);\n}\n",
                    newText:
                      "export async function fetchJson(url: string) {\n  return withRetry(() => request(url), { attempts: 3 });\n}\n",
                  },
                ],
              }),
              tool("Read retry.ts", "read", "completed", { locations: [{ path: "src/net/retry.ts" }] }),
              thought("Run the focused tests again, then the type check, before answering."),
              tool("bun test src/net", "execute", "completed", { command: "bun test src/net", exitCode: 0 }),
              tool("bun run typecheck", "execute", "completed", { command: "bun run typecheck", exitCode: 0 }),
            ],
            5.8,
          ),
          assistant("fetchJson now retries three times with backoff on 5xx; the net tests and the type check pass.", 5),
          summary(5, { status: "completed", toolCount: 10 }),
        ],
        {},
      ),
      play: openWorked,
    },
    "consolidated-live-run": {
      note: "A running turn with a message to another agent in its run: the card stays in sight and the calls on each side of it still fold into counted lines, with thoughts between calls kept inside them.",
      snapshot: chat(
        [
          user("Check the fleet sessions and tell the coordinator what is stuck.", 3),
          activity(
            [
              ...["acpmux ls", "acpmux status --json", "acpmux ls --peers"].map((command) => shellTool(command)),
              thought("Two sessions show no heartbeat; read their logs before telling anyone."),
              shellTool("grep -l chief /tmp/l*.txt"),
              tool("Read session.log", "read", "completed", { locations: [{ path: "/tmp/session.log" }] }),
              tool("Run", "execute", "completed", {
                command: 'tell-coordinator "fleet: two sessions stuck on build-box, restarting them"',
                output: "delivered to coord-deputy\n",
              }),
              shellTool("acpmux restart stuck-1"),
              thought("The first restart came back; do the second one the same way."),
              shellTool("acpmux restart stuck-2"),
              tool("acpmux ls", "execute", "in_progress", { command: "acpmux ls" }),
            ],
            2.8,
          ),
        ],
        { isWorking: true },
      ),
    },
    "collapsed-run": {
      note: 'A run of mixed work between two messages collapses to one quiet line naming its work in the order it came, "Edited 2 files, read 2 files, ran 2 commands", under the several-tools glyph (four rings joined by a diagonal). The run the agent works in now keeps its call in flight out, on the live line (Leo 2026-10-22: "this is pretty good ui: … the collapsing i mean").',
      snapshot: collapsedRunChat(),
    },
    "collapsed-run-one-kind": {
      note: "A collapsed run of one kind of work (two web fetches) keeps that kind's glyph, the globe.",
      snapshot: oneKindRunChat(),
    },
    "collapsed-run-open": {
      note: "The same line opened: the rows it holds, drawn as they are on their own.",
      snapshot: collapsedRunChat(),
      play: openFoldedRun,
    },
    "collapsed-run-spacing-tight": {
      note: "Gallery comparison: the tool rows use a 20px line and 2px after the run.",
      snapshot: collapsedRunChat(),
      documentAttributes: { "transcript-tool-spacing": "tight" },
      play: openFoldedRun,
    },
    "collapsed-run-spacing-selected": {
      note: "Selected gallery rhythm: compact 22px tool rows and a 4px gap before the reply, matching the Codex reference.",
      snapshot: collapsedRunChat(),
      play: openFoldedRun,
    },
    "collapsed-run-spacing-roomy": {
      note: "Gallery comparison: the prior 26px tool rows and 8px after-run gap.",
      snapshot: collapsedRunChat(),
      documentAttributes: { "transcript-tool-spacing": "roomy" },
      play: openFoldedRun,
    },
    "collapsed-run-failed": {
      note: "A failed call in the collapsed run is counted on its line.",
      snapshot: collapsedRunChat([
        tool("bun run lint", "execute", "completed", { command: "bun run lint", exitCode: 1, output: "1 error\n" }),
      ]),
    },
    "collapsed-run-pencil": {
      note: "Gallery version: the pencil on every collapsed run, as the Codex app draws it (theme toolRunLook pencil).",
      snapshot: collapsedRunChat(),
      theme: { toolRunLook: "pencil" },
    },
    "collapsed-run-quiet": {
      note: "Gallery version: the line's words in the quiet rows' colour (theme toolRunLook quiet).",
      snapshot: collapsedRunChat(),
      theme: { toolRunLook: "quiet" },
    },
    "collapsed-run-quiet-pencil": {
      note: "Gallery version: quiet words and the pencil, closest to the Codex app (theme toolRunLook quiet-pencil).",
      snapshot: collapsedRunChat(),
      theme: { toolRunLook: "quiet-pencil" },
    },
    "agent-messages": {
      note: "Messages to other agents say how far they got in one word at the line's end (Sent, Queued, Delivered, or why not) without the receipt's id; a shell call reads without its leading cd and, opened, names its folder beside Shell.",
      snapshot: chat(
        [
          user("Tell the coordinator the fix is pushed, then check the branch.", 2),
          activity(
            [
              tool("Run", "execute", "completed", {
                command: 'tell-coordinator "sidebar-drag: fix pushed as #22990, review next"',
                output: "delivered to leoli-24 (id 9defc4d0ed87)\n",
              }),
            ],
            1.9,
          ),
          activity(
            [
              tool("Run", "execute", "completed", {
                command: 'cmux send --surface reviewer "sidebar-drag: CI green, merging"',
                output: "",
              }),
            ],
            1.8,
          ),
          activity(
            [
              tool("Run", "execute", "in_progress", {
                command: 'tell-coordinator "sidebar-drag: merged, cleaning up"',
              }),
            ],
            1.7,
          ),
          activity([shellTool("cd ~/wt/lanes/sidebar-drag && git status --short && git log --oneline -3")], 1.6),
        ],
        { isWorking: true },
      ),
      play: async (ctx: PlayContext) => {
        await ctx.click({ selector: ".cv-tool.is-toggle" });
        await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-shell__folder")));
      },
    },
    "dense-ended-run": {
      note: "An ended turn folds under Worked for; opened, its commentary sits between the runs' summary lines, each opening to its calls, as in the Codex app.",
      snapshot: chat([
        user("Find why the sidebar drag drops tabs, and hand the fix to a sub-session.", 6),
        assistant("I'll look at the drag handlers and the recent changes first.", 5.9),
        activity(
          [
            ...DENSE_COMMANDS.map((command) => shellTool(command)),
            tool("Read SidebarDrag.tsx", "read", "completed"),
            tool("mcp__cmux-subsessions__start_session", "other", "completed", {
              inputSummary: JSON.stringify({ name: "sidebar-drag-bugs", prompt: "Fix the sidebar drag bugs" }),
              output: JSON.stringify({ ok: true }),
            }),
          ],
          5.8,
        ),
        assistant("The drop target loses its index when the list re-sorts. A sub-session is fixing it.", 3),
        summary(3, { status: "completed", toolCount: 9, durationMs: 174_000 }),
      ]),
      play: openWorked,
    },
    "codex-turn-live": {
      note: "A running turn as the Codex app draws it: one live block at the bottom and nothing over the turn, each finished run one counted summary line between the paragraphs (Read 2 files, ran 3 commands; Ran 3 commands), commands named by what they do, and the call in flight named on the live line instead of a growing stack.",
      snapshot: chat(
        [
          user("Check the retry regression and the macOS verification run.", 11.5),
          assistant("I'll check the existing regression tests and the documented verification runs first.", 11.4),
          activity(
            [
              tool("Read client.ts", "read", "completed", { locations: [{ path: "src/net/client.ts" }] }),
              tool("Read retry.test.ts", "read", "completed", { locations: [{ path: "src/net/retry.test.ts" }] }),
              describedShell("git log --oneline -5 -- src/net", "Show recent changes to the network code"),
            ],
            11.3,
          ),
          assistant("The repaired head has passed the fast checks; I'm reading the verification runs.", 9),
          activity(
            [
              describedShell("gh run list --workflow verify.yml -L 5", "List the latest verification runs"),
              describedShell("gh run view 1190 --log-failed", "Read the failed run's log"),
              describedShell("bun test src/net --filter retry", "Run the retry tests"),
            ],
            8.9,
          ),
          assistant("The regression is confirmed on the 429 path; the rescue workflow is running now.", 2),
          activity(
            [
              describedShell("git cat-file -t c94307c", "Check the pinned commit"),
              tool("Run the rescue workflow", "execute", "in_progress", {
                command:
                  'export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"; gh workflow run rescue.yml',
                description: "Run the rescue workflow",
                startedAt: minutesAgo(0.2),
              }),
            ],
            1.9,
          ),
        ],
        { isWorking: true },
      ),
    },
    "codex-turn-command-under-messages": {
      note: 'Leo, 2026-10-22: "the ran thing basiclly replcaes the thinking usually". A command still running in an earlier run while the agent writes and messages others: it is the live line at the bottom (Running cp … with its time, ⌃B to run in background at its right on hover), not a Ran cp row with the hint over a Thinking line. Play: the line names the cp, no transcript row draws the hint or runs.',
      snapshot: chat(
        [
          user("Copy the session log into recovery and tell the lanes what changed.", 3),
          activity(
            [
              tool("cp", "execute", "in_progress", {
                command: "cp /private/tmp/session-export/session.jsonl ~/recovery/",
                startedAt: minutesAgo(1.2),
              }),
            ],
            1.2,
          ),
          assistant(
            "While the copy runs I'll tell the lanes what changed: the live line now names the command in flight, the Ctrl-B hint sits at its right, and finished commands keep their rows.",
            1,
          ),
          activity([shellTool("acpmux send --no-wait coord-deputy '[lanes] summary sent'")], 0.8),
        ],
        { isWorking: true },
      ),
      play: async (ctx: PlayContext) => {
        const doc = ctx.document;
        await ctx.waitFor(() =>
          (doc.querySelector(".cv-worked.is-below .cv-thinking")?.textContent ?? "").startsWith("Running cp "),
        );
        const stray = [...doc.querySelectorAll(".cv-command__bg")].filter((node) => !node.closest(".cv-worked"));
        if (stray.length) throw new Error(`${stray.length} transcript rows draw the ⌃B hint`);
        const live = doc.querySelectorAll(".cv-tool.is-live").length;
        if (live) throw new Error(`${live} running rows draw over the live line`);
        await liveLineClear(ctx);
      },
    },
    "codex-turn-raw-commands": {
      note: "Leo's turn-toolcalls-now.png: commands that all start with export PATH=… and send no description. Each reads as its meaningful command (acpmux ls, gh pr view 22363); the two runs and the short note between them are one folded line; the call in flight is the one live line at the bottom (Running acpmux send 13s), shimmering, no dots, 16px clear of the run over it; ⌃B to run in background shows on hover. Play: hover the line.",
      snapshot: chat(
        [
          user("What did the lanes decide? Relay it and answer.", 2),
          assistant("I'll read the lanes' latest reports first.", 1.95),
          activity(
            [
              envShell("acpmux ls 2>&1 | head -40"),
              envShell("acpmux history linux-box/activity-indicators | tail -c 4000"),
              envShell("acpmux history transcript-density | tail -c 4000"),
              tool("grep -l -i chief /tmp/l*.txt /tmp/r*.txt", "execute", "completed", {
                command:
                  "grep -l -i chief /tmp/l*.txt /tmp/r*.txt 2>/dev/null | head; for f in $(grep -l chief /tmp/*.txt); do wc -l $f; done",
                exitCode: 0,
                output: "",
                startedAt: minutesAgo(1.9),
                endedAt: minutesAgo(1.89),
              }),
              envShell("acpmux history chat-background | tail -c 4000"),
            ],
            1.9,
          ),
          assistant("Relay the decisions, then answer.", 1.5),
          activity(
            [
              envShell("gh pr view 22363 --json state,mergeable"),
              tool("acpmux send", "execute", "in_progress", {
                command: `export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"\nacpmux send --no-wait coord-deputy "[lanes] decisions relayed"`,
                startedAt: minutesAgo(0.22),
              }),
            ],
            1.4,
          ),
        ],
        { isWorking: true },
      ),
      play: liveLineClear,
    },
    "codex-turn-drafts-replace": {
      note: "Leo's status-task-notification-replacement.png: a task notification's work after the turn ended, three calls Claude has not written yet. They draw no rows of their own (it was four bare command rows stacked under Worked for 1s); the newest is the one live line at the bottom (Writing a command), under the finished call, and each next call replaces it there, as Thinking does. Play: one live line, no running rows.",
      snapshot: chat(
        [
          user("Start the release build in the background and tell me when it's done.", 3),
          activity([describedShell("make release &", "Start the release build")], 2.9),
          assistant("The release build is running in the background.", 2.8),
          summary(2.8, { status: "completed", durationMs: 1_000, toolCount: 1 }),
          activity(
            [
              describedShell("tail -n 40 build/release.log", "Read the end of the build log", {
                startedAt: minutesAgo(0.4),
                endedAt: minutesAgo(0.39),
              }),
              ...[0.3, 0.2, 0.1].map((minutes) =>
                tool("Bash", "execute", "pending", { inputSummary: "{}", startedAt: minutesAgo(minutes) }),
              ),
            ],
            0.4,
          ),
        ],
        { isWorking: true },
      ),
      play: async (ctx: PlayContext) => {
        const doc = ctx.document;
        await ctx.waitFor(() =>
          (doc.querySelector(".cv-worked.is-below")?.textContent ?? "").startsWith("Writing a command"),
        );
        const lines = doc.querySelectorAll(".cv-worked.is-below").length;
        if (lines !== 1) throw new Error(`${lines} live lines, not one`);
        const live = doc.querySelectorAll(".cv-tool.is-live").length;
        if (live) throw new Error(`${live} running rows stack over the live line`);
      },
    },
    "tool-run-scrolled-fade": {
      note: 'Leo 2026-10-24: a long run ("Read files, ran commands") keeps its collapsed rows on the transcript\'s one vertical scroll surface instead of capturing the wheel in a nested list. Play: open the turn and the run.',
      snapshot: chat([
        user("Find where the sidebar's drag reorder loses its index.", 3),
        activity(
          Array.from({ length: 6 }, (_, index) => [
            tool(`Read sidebar${index}.ts`, "read", "completed", {
              locations: [{ path: `webviews/src/sidebar/sidebar${index}.ts` }],
            }),
            tool(`Read sidebar${index}.test.ts`, "read", "completed", {
              locations: [{ path: `webviews/test/sidebar${index}.test.ts` }],
            }),
            describedShell(DENSE_COMMANDS[index]!, `Search the sidebar code (${index + 1})`),
          ]).flat(),
          2.9,
        ),
        assistant("The index is read before the drop moves the row; the fix reads it after.", 2),
        summary(2, { status: "completed", toolCount: 18, durationMs: 64_000 }),
      ]),
      play: async (ctx) => {
        await openGroupedRun(ctx);
        const list = () => ctx.find({ selector: ".cv-tool-run" });
        await ctx.waitFor(() => list().clientHeight > 0);
        if (list().scrollHeight > list().clientHeight + 1) throw new Error("tool run captured vertical scroll");
        if (list().scrollTop !== 0) throw new Error("tool run moved its own scroll position");
      },
    },
    "codex-turn-run-open": {
      note: "The same turn ended: opened, Worked for shows the commentary between the runs' summary lines; a click opens Ran 3 commands to its calls. Play: open the turn, then the second run.",
      snapshot: chat([
        user("Check the retry regression and the macOS verification run.", 11.5),
        assistant("I'll check the existing regression tests first.", 11.4),
        activity(
          [
            tool("Read client.ts", "read", "completed", { locations: [{ path: "src/net/client.ts" }] }),
            describedShell("git log --oneline -5 -- src/net", "Show recent changes to the network code"),
          ],
          11.3,
        ),
        assistant("The fast checks passed; I'm reading the verification runs.", 9),
        activity(
          [
            describedShell("gh run list --workflow verify.yml -L 5", "List the latest verification runs"),
            describedShell("gh run view 1190 --log-failed", "Read the failed run's log"),
            describedShell("bun test src/net --filter retry", "Run the retry tests", { status: "failed", exitCode: 1 }),
          ],
          8.9,
        ),
        assistant("The regression is on the 429 path; the fix is a two-line change in the backoff.", 2),
        summary(2, { status: "completed", toolCount: 5, durationMs: 576_000 }),
      ]),
      play: async (ctx) => {
        await openWorked(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-tools > .cv-tool.is-toggle").length === 2);
        const runs = () => [...ctx.document.querySelectorAll<HTMLElement>(".cv-tools > .cv-tool.is-toggle")];
        runs()[1]!.click();
        await ctx.waitFor(() => runs()[1]!.getAttribute("aria-expanded") === "true");
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-command").length === 3);
      },
    },
    "tool-hover-meta": {
      note: "A finished command's check and run time show only while it is pointed at; a failed one keeps its red exit mark at rest. Play: hover the first command.",
      snapshot: chat([
        user("Run the checks", 3),
        activity(
          [
            describedShell("bun run check", "Run the web checks"),
            describedShell("bun test src/net", "Run the network tests", { status: "failed", exitCode: 1 }),
          ],
          2.9,
        ),
        assistant("The web checks pass; one network test fails on the 429 path.", 2.5),
        summary(2.5, { status: "completed", toolCount: 2, durationMs: 31_000 }),
      ]),
      play: async (ctx) => {
        await openGroupedRun(ctx);
        const ok = () => ctx.find({ selector: ".cv-command .cv-command__ok" });
        const failed = ctx.find({ selector: ".cv-command .cv-command__failed" });
        if (ctx.document.defaultView!.getComputedStyle(failed).opacity !== "1")
          throw new Error("the failure mark hides at rest");
        if (ctx.document.defaultView!.getComputedStyle(ok()).opacity !== "0")
          throw new Error("the check shows at rest");
        await ctx.hover({ selector: ".cv-command" });
        await ctx.waitFor(() => ctx.document.defaultView!.getComputedStyle(ok()).opacity === "1");
      },
    },
    "tool-hover-meta-lone": {
      note: "Calls that are not shells, at rest: a finished fetch shows no check or time, a failed one says failed in red. Play: open Worked for and its run.",
      snapshot: loneToolCalls(),
      play: loneToolMetaAtRest,
    },
    "tool-hover-meta-lone-hovered": {
      note: "The same calls with the finished fetch pointed at: its green check and run time fade in; the failure stays as it was. Play: open Worked for and its run, hover the fetch.",
      snapshot: loneToolCalls(),
      play: async (ctx) => {
        await loneToolMetaAtRest(ctx);
        const row = ctx.find({ selector: ".cv-tool:has(.cv-command__ok)" });
        await ctx.hover({ selector: ".cv-tool:has(.cv-command__ok)" });
        await ctx.waitFor(() =>
          [...row.querySelectorAll(".cv-command__ok, .cv-command__time")].every(
            (node) => getComputedStyle(node).opacity === "1",
          ),
        );
      },
    },
    "mcp-calls": {
      note: "MCP calls read as what they did: four sends to one chat are one line, the read names the chat.",
      snapshot: chat(
        [
          user("Post the lane updates to the Coordination hub and read it back.", 1),
          activity([...MCP_SENDS, MCP_READ], 0.8),
        ],
        { isWorking: true },
      ),
    },
    "tool-result-envelopes": {
      note: "Opened tool results read as their content, not the JSON a harness wrapped them in: one-line JSON pretty-printed, an MCP text list as Markdown, a result envelope and Codex's output as their text, a JSON file kept as printed.",
      height: 1100,
      snapshot: chat(
        // The reply under the calls keeps every call a row: with nothing after it, the live line
        // would hold the last finished call instead.
        [
          user("Stop the watcher, check the issues and run the tests.", 1),
          activity(ENVELOPE_TOOLS, 0.8),
          assistant("The watcher is stopped and the tests pass.", 0.5),
        ],
        { isWorking: true },
      ),
      play: async (ctx) => {
        // A settled run folds to its line; opened, it lists the calls, each opened in turn.
        await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-tool.is-toggle")));
        if (ctx.document.querySelector(".cv-tools > .cv-tool.is-toggle")) await openFoldedRun(ctx);
        const closed = '.cv-tool.is-toggle[aria-expanded="false"]';
        await ctx.waitFor(() => ctx.document.querySelectorAll(closed).length === ENVELOPE_TOOLS.length);
        // Each row centered first: the runner scrolls a target only as far as needed, which parks a row
        // at the transcript's foot, under Jump to latest (shown while a run is working), and the click
        // lands on the pill.
        for (let opened = 0; opened < ENVELOPE_TOOLS.length; opened++) {
          ctx.find({ selector: closed }).scrollIntoView({ block: "center" });
          await ctx.click({ selector: closed });
        }
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-tool-output-card").length === ENVELOPE_TOOLS.length);
        if (!ctx.document.querySelector(".cv-tool-output__markdown h2"))
          throw new Error("the MCP text list did not render as Markdown");
        if (ctx.document.body.textContent?.includes('"type":"text"')) throw new Error("an envelope shows raw");
      },
    },
    "tool-calls": {
      note: "An ended turn: its work folds under Worked for.",
      snapshot: chat([
        user(prompt, 20),
        activity(
          [
            tool("Read client.ts", "read", "completed"),
            tool("bun test src/net", "execute", "completed", {
              command: "bun test src/net",
              exitCode: 0,
              output: "3 pass\n0 fail\nRan 3 tests across 1 file. [118.00ms]",
              startedAt: minutesAgo(19.5),
              endedAt: minutesAgo(19.4),
            }),
            tool("Fetch https://example.com/docs", "fetch", "completed"),
          ],
          19.6,
        ),
        assistant("The tests pass. No change was needed in `parseError`.", 19),
        summary(19, { status: "completed", toolCount: 3, durationMs: 62_000 }),
      ]),
    },
    "tool-failed": {
      note: "A failed command (exit status 1) inside a turn.",
      snapshot: chat([
        user("Run the linter", 12),
        activity(
          [
            tool("bun run lint", "execute", "failed", {
              command: "bun run lint",
              exitCode: 1,
              output:
                "src/net/client.ts:14:7  error  'policy' is assigned a value but never used  no-unused-vars\n\n✖ 1 problem (1 error, 0 warnings)",
              startedAt: minutesAgo(11.9),
              endedAt: minutesAgo(11.8),
            }),
          ],
          11.9,
        ),
        assistant("Lint fails on one unused variable; I can remove it.", 11.5),
        summary(11.5, { status: "completed", toolCount: 1 }),
      ]),
    },
    "turn-stopped": {
      note: 'The last turn, stopped by the reader: its footer says "You stopped after 40s" at rest and offers Continue, as Codex does. Continue sends a continue prompt through the composer\'s send; the button goes once that prompt shows (Leo, 2026-10-22: "and we should add a continue button if things were stopped, just like codex").',
      snapshot: chat([
        user(prompt, 3),
        activity(
          [
            thought("Find where the fetch helper gives up on a failed request."),
            tool("Read src/net/client.ts", "read", "completed"),
          ],
          2.8,
        ),
        assistant("The helper throws on the first failure. I'll wrap it in a retry loop with backoff next.", 2.5),
        summary(2.33, { status: "cancelled", durationMs: 40_000, toolCount: 1 }),
      ]),
    },
    "turn-stopped-then-continued": {
      note: "A stopped turn that a prompt followed: only the last turn can offer Continue, so the earlier stopped turn offers none, and neither does the completed last turn.",
      snapshot: chat([
        user(prompt, 6),
        assistant("The helper throws on the first failure. I'll wrap it in a retry loop with backoff next.", 5.5),
        summary(5.33, { status: "cancelled", durationMs: 40_000 }),
        user("Continue", 4),
        assistant("Retries now back off from 200 ms, doubling up to three tries.", 3),
        summary(3, { status: "completed", durationMs: 60_000 }),
      ]),
    },
    "turn-error": {
      note: "A turn the agent ended with an error.",
      snapshot: chat([
        user(prompt, 6),
        summary(5.5, {
          status: "failed",
          error: "The agent stopped: model overloaded (529). Try again in a moment.",
        }),
      ]),
    },
    "turn-error-with-pdf": {
      note: "A failed turn keeps its attached PDF available to Retry, so the next request does not lose document context.",
      snapshot: chat([
        user("Review the attached build report", 6, {
          retryAttachments: [
            {
              id: "gallery-build-report",
              kind: "document",
              name: "build-report.pdf",
              mimeType: "application/pdf",
              size: 128,
              data: "JVBERi0xLjQK",
              pageCount: 3,
            },
          ],
        }),
        summary(5.5, {
          status: "failed",
          error: "The model stopped before reading the document. Try again.",
        }),
      ]),
    },
    "turn-error-long": {
      note: "A turn that failed with a long gateway error: the note wraps and the row grows.",
      snapshot: chat([
        user(prompt, 6),
        summary(5.5, {
          status: "failed",
          error:
            "API Error: 503 no non-exhausted claude accounts available, next account frees up in 50m (retry after 2945s). This is a server-side issue, usually temporary. Try again in a moment. If it persists, check your inference gateway (100.89.225.106:31415).",
        }),
      ]),
    },
    "turn-error-signed-out": {
      note: "The CLI's own login is gone: only this class says sign in.",
      snapshot: chat(
        [
          user(prompt, 6),
          summary(5.5, {
            status: "failed",
            error: "Claude Code is not logged in. Please run /login. (OAuth token has expired)",
          }),
        ],
        { harness: "claude" },
      ),
      // cx-w10a: the footer classifies the failure honestly; only subscription-login says "sign in".
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const note = ctx.document.querySelector('[data-failure-kind="subscription-login"]');
          return note && !/Your sign-in expired\. Sign in again to continue/.test(note.textContent ?? "") ? note : null;
        });
      },
    },
    "turn-error-proxy-401": {
      note: "A proxy route refused the request: name the route and the status, not a sign-in.",
      snapshot: chat(
        [
          user(prompt, 6),
          summary(5.5, {
            status: "failed",
            error:
              'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"unauthorized"}} from http://studio-mac:31415/v1/messages',
          }),
        ],
        { harness: "claude-sr" },
      ),
      // cx-w10a: the footer classifies the failure honestly; only subscription-login says "sign in".
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const note = ctx.document.querySelector('[data-failure-kind="proxy-auth"]');
          return note && !/Your sign-in expired\. Sign in again to continue/.test(note.textContent ?? "") ? note : null;
        });
      },
    },
    "turn-error-invalid-key": {
      note: "A bad or missing API key.",
      snapshot: chat(
        [
          user(prompt, 6),
          summary(5.5, {
            status: "failed",
            error: "API Error: 401 authentication_error: invalid x-api-key",
          }),
        ],
        { harness: "claude" },
      ),
      // cx-w10a: the footer classifies the failure honestly; only subscription-login says "sign in".
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const note = ctx.document.querySelector('[data-failure-kind="invalid-key"]');
          return note && !/Your sign-in expired\. Sign in again to continue/.test(note.textContent ?? "") ? note : null;
        });
      },
    },
    "turn-error-rate-limited": {
      note: "Rate limits mention authentication sometimes; they are still rate limits.",
      snapshot: chat(
        [
          user(prompt, 6),
          summary(5.5, {
            status: "failed",
            error:
              "API Error: 429 rate_limit_error: This request would exceed your account's rate limit. Please check your authentication plan.",
          }),
        ],
        { harness: "claude" },
      ),
      // cx-w10a: the footer classifies the failure honestly; only subscription-login says "sign in".
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const note = ctx.document.querySelector('[data-failure-kind="rate-limited"]');
          return note && !/Your sign-in expired\. Sign in again to continue/.test(note.textContent ?? "") ? note : null;
        });
      },
    },
    "turn-error-no-team-account": {
      note: "Codex on a team Cloud machine whose team has no Codex account: say so and name the command that adds one, not a rate limit or a refused route.",
      snapshot: chat(
        [
          user(prompt, 6),
          summary(5.5, {
            status: "failed",
            error:
              "unexpected status 403 Forbidden: Codex needs a team account on this machine. To add one for the team, run `cr add codex` in this machine's terminal. If someone added one as private, they can choose Share with team at coderouter.dev., url: https://coderouter.cmux.dev/v1/responses, request id: req-1",
          }),
        ],
        { harness: "codex", model: "gpt-5.5" },
      ),
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const note = ctx.document.querySelector('[data-failure-kind="no-team-account"]');
          return note && /needs a team account on this machine/.test(note.textContent ?? "") ? note : null;
        });
      },
    },
    "turn-error-unreachable": {
      note: "The route's server is down or unreachable.",
      snapshot: chat(
        [
          user(prompt, 6),
          summary(5.5, {
            status: "failed",
            error: "Connection error: fetch failed (connect ECONNREFUSED 127.0.0.1:31415)",
          }),
        ],
        { harness: "claude-cr" },
      ),
      // cx-w10a: the footer classifies the failure honestly; only subscription-login says "sign in".
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const note = ctx.document.querySelector('[data-failure-kind="unreachable"]');
          return note && !/Your sign-in expired\. Sign in again to continue/.test(note.textContent ?? "") ? note : null;
        });
      },
    },
    "turn-error-other": {
      note: "Anything else keeps the agent's own words.",
      snapshot: chat(
        [
          user(prompt, 6),
          summary(5.5, {
            status: "failed",
            error: "The agent stopped: the tool output was larger than the context window.",
          }),
        ],
        { harness: "claude" },
      ),
      // cx-w10a: the footer classifies the failure honestly; only subscription-login says "sign in".
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const note = ctx.document.querySelector('[data-failure-kind="other"]');
          return note && !/Your sign-in expired\. Sign in again to continue/.test(note.textContent ?? "") ? note : null;
        });
      },
    },
    "refused-retry": {
      note: "A prompt the host refused: why, and Retry.",
      snapshot: chat([
        user(prompt, 3),
        assistant("Done.", 2.8),
        summary(2.8, { status: "completed" }),
        user("Now also add a circuit breaker", 0.5, {
          failed: true,
          error: "This chat is read only on this connection.",
        }),
      ]),
    },
    rhythm: {
      note: "The transcript's vertical rhythm: two prompts in one turn, each meta row right under its bubble, a reply's footer right under the reply, turns a fixed gap apart, and a Worked for turn.",
      snapshot: chat([
        user("Is the hosted test run done?", 20),
        assistant("Checking the hosted run now.", 19.8),
        user("Also check the PR checks.", 19.7),
        assistant("Not yet: the hosted test run is still queued, and the PR checks wait on it.", 19.5),
        summary(19.5, { status: "completed", durationMs: 17_000 }),
        ...workedTurnRows(minutesAgo(15)),
        summary(14, { status: "completed", toolCount: 3 }),
      ]),
    },
    "sub-second-turns": {
      note: "Turns under a second: no Worked for 0s, and a turn with nothing to copy takes no footer line, only the turn gap (Leo, 2026-10-21).",
      snapshot: subSecondTurns(),
    },
    "sub-second-turns-pointed": {
      note: "The same turns, the pointer on the quiet turn's footer: its age (and Pin, where the chat pins) shows over the turn gap, and nothing below moves.",
      snapshot: subSecondTurns(),
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-turnSummary" });
      },
    },
    "prompt-delivery": {
      note: "Each sent prompt's way to the agent: the read check once it started, unread once acpmux took it, a clock and Still sending while it waits, and one that failed with Retry, Edit, Remove and Details.",
      snapshot: chat([
        user("Add retries to the client", 6, {
          delivery: { state: "read", promptId: "p1", sessionId: "s", sentAt: 0, acceptedAt: 40, readAt: 90 },
        }),
        assistant("Added.", 5.5),
        summary(5.5, { status: "completed" }),
        user("And a test for it", 3, {
          delivery: { state: "delivered", promptId: "p2", sessionId: "s", sentAt: 0, acceptedAt: 60 },
        }),
        user("Then open a PR", 2, {
          pending: true,
          delivery: { state: "sending", promptId: "p3", sessionId: "s", sentAt: 0, slow: true },
        }),
        user("Ship it", 1, {
          failed: true,
          error: "Not sent: no answer from acpmux.",
          delivery: {
            state: "failed",
            promptId: "p4",
            sessionId: "s",
            sentAt: 0,
            failedAt: 60000,
            hop: "acpmux",
            code: "timeout",
            error: "Not sent: no answer from acpmux.",
          },
        }),
      ]),
    },
    "failed-sends-grouped": {
      note: "Three prompts acpmux held behind the folder's trust question (Leo 2026-10-21): one card under the last of them, one plain sentence with Trust folder, and Retry, Edit, Remove and Details once for the three; the raw code only under Details.",
      snapshot: chat([
        user(prompt, 6),
        assistant("Added retries with backoff.", 5.5),
        summary(5.5, { status: "completed" }),
        user("Add a test for the backoff", 3, {
          failed: true,
          error: "Not sent until you trust this folder.",
          delivery: {
            state: "failed",
            promptId: "p1",
            sessionId: "s",
            sentAt: 0,
            failedAt: 40,
            hop: "acpmux",
            reason: "trust.pending",
            error: "trust.pending: answer the trust question for the folder first",
          },
        }),
        user("Then open a PR", 2, {
          failed: true,
          error: "Not sent until you trust this folder.",
          delivery: {
            state: "failed",
            promptId: "p2",
            sessionId: "s",
            sentAt: 0,
            failedAt: 40,
            hop: "acpmux",
            reason: "trust.pending",
            error: "trust.pending: answer the trust question for the folder first",
          },
        }),
        user("And ping me when CI is green", 1, {
          failed: true,
          error: "Not sent until you trust this folder.",
          delivery: {
            state: "failed",
            promptId: "p3",
            sessionId: "s",
            sentAt: 0,
            failedAt: 40,
            hop: "acpmux",
            reason: "trust.pending",
            error: "trust.pending: answer the trust question for the folder first",
          },
        }),
      ]),
      play: async (ctx) => {
        await ctx.waitFor(() =>
          ctx.document.querySelectorAll(".cv-user__status--failed").length === 1
            ? ctx.document.querySelector('[data-failure-cause="trust-pending"][data-failed-count="3"]')
            : null,
        );
      },
    },
    "failed-send-too-large": {
      note: 'A prompt larger than one message (message.too_large): acpmux refuses it the same way at every Retry, so the card names the attachment to take out and offers Edit, Remove and Details, never Retry (Leo, 2026-10-31: "this is completely hardlocked bc of message size").',
      snapshot: chat([
        user(prompt, 6),
        assistant("Added retries with backoff.", 5.5),
        summary(5.5, { status: "completed" }),
        user("Why does the dashboard look like this on the staging build?", 1, {
          failed: true,
          error:
            "Not sent: this message is too large to send at once. Take out dashboard-recording.png with Edit, or send it in a message of its own.",
          delivery: {
            state: "failed",
            promptId: "p1",
            sessionId: "s",
            sentAt: 0,
            failedAt: 900,
            hop: "acpmux",
            code: "-32000",
            reason: "message.too_large",
            error: "message too large to send: 16907300 bytes, the limit is 15728640",
          },
        }),
      ]),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('[data-failure-cause="too-large"]'));
      },
    },
    "edited-files": {
      note: "A turn that edited three files: the edited-files card with Undo.",
      snapshot: chat([...workedTurnRows(minutesAgo(15)), summary(14, { status: "completed", toolCount: 3 })]),
    },
    "preview-card": {
      note: "A turn that started a local server. Its address stays a link in the reply; the preview card under the answer shows only with the Debug toggle agentPane.debug.turnPreviewCards (data-turn-preview-cards on <html>).",
      snapshot: chat([
        user("Start the dev server", 9),
        activity(
          [
            tool("bun run dev", "execute", "completed", {
              command: "bun run dev",
              output: "  VITE v8.0.0  ready in 412 ms\n\n  ➜  Local:   http://localhost:5173/",
              exitCode: 0,
            }),
          ],
          8.9,
        ),
        assistant("The dev server runs at http://localhost:5173/.", 8.8),
        summary(8.8, { status: "completed", toolCount: 1 }),
      ]),
    },
    "token-link": {
      note: "An agent's bare local address with a token (Leo 2026-10-20): plain link text with the token as •••, no card under the answer; hovering it offers Open and Open in.",
      snapshot: chat([
        user("Open the dashboard", 6),
        assistant(
          "The dashboard is up at http://127.0.0.1:47811?token=0f3c9a7d51e2b8846a0c3f9e1d7b2a5c6e8f0a1b and reloads on save.",
          5.9,
        ),
        summary(5.9, { status: "completed" }),
      ]),
    },
    "chips-and-previews": {
      note: "Markdown mixing URL/path chips, host-mediated images, an oversized image guard, and a local preview.",
      chipHost: CHIP_HOST,
      snapshot: chat([user("Show the links and images", 5), assistant(CHIP_PREVIEW_MIX, 4.9), summary(4.9)]),
    },
    "tool-images": {
      note: "Images tool calls produced: a screenshot a browser tool returned, a chart a script saved, and the first page of a PDF report; a click opens the viewer.",
      chipHost: {
        paths: {
          "/Users/you/src/atlas-web/out/build-times.png": { place: "root" as const, folder: false },
          "/Users/you/src/atlas-web/out/build-report.pdf": {
            place: "root" as const,
            folder: false,
          },
        },
        images: {
          "/Users/you/src/atlas-web/out/build-times.png": `data:image/png;base64,${BUILD_TIMES_PNG}`,
          "/Users/you/src/atlas-web/out/build-report.pdf": `data:image/png;base64,${BUILD_REPORT_PDF_PAGE_PNG}`,
        },
      },
      snapshot: chat([
        user("Check the sign-in page, then chart the build times", 6),
        activity(
          [
            tool("Screenshot localhost:5173/login", "other", "completed", {
              output: "Captured 640x400",
              images: [`data:image/png;base64,${LOGIN_SCREENSHOT_PNG}`],
            }),
            tool("python3 scripts/plot_build_times.py", "execute", "completed", {
              command: "python3 scripts/plot_build_times.py",
              output: "Saved chart to /Users/you/src/atlas-web/out/build-times.png\n",
              exitCode: 0,
            }),
            tool("python3 scripts/build_report.py", "execute", "completed", {
              command: "python3 scripts/build_report.py",
              output: "Wrote 3 pages to /Users/you/src/atlas-web/out/build-report.pdf\n",
              exitCode: 0,
            }),
          ],
          5.8,
        ),
        assistant(
          "The sign-in page renders with both fields and the Continue button. The app target is the slowest build at 312 s; the report has the per-file timings.",
          5.6,
        ),
        summary(5.6, { status: "completed", toolCount: 3 }),
      ]),
    },
    "tool-video": {
      note: "A terminal recording a tool saved plays inline with controls (muted while hovered); Expand shows it over the pane.",
      chipHost: {
        paths: {
          "/Users/you/src/atlas-web/out/login-tests.mp4": { place: "root" as const, folder: false },
        },
        media: {
          "/Users/you/src/atlas-web/out/login-tests.mp4": `data:video/mp4;base64,${LOGIN_TESTS_MP4}`,
        },
      },
      snapshot: chat([
        user("Record the login tests running so I can attach it to the PR", 4),
        activity(
          [
            tool("vhs scripts/login-tests.tape", "execute", "completed", {
              command: "vhs scripts/login-tests.tape",
              output: "Recorded 7 s to /Users/you/src/atlas-web/out/login-tests.mp4\n",
              exitCode: 0,
            }),
          ],
          3.8,
        ),
        assistant("All six login tests pass; the recording is ready to attach.", 3.6),
        summary(3.6, { status: "completed", toolCount: 1 }),
      ]),
    },
    "web-video": {
      note: "A GitHub attachment alone on its line: with images.remote = click (the default) it shows its site and Load video.",
      chipHost: { media: { [WEB_VIDEO]: `data:video/mp4;base64,${LOGIN_TESTS_MP4}` } },
      snapshot: chat([
        user("Did the PR's recording show the login tests passing?", 3),
        assistant(WEB_VIDEO_REPLY, 2.9),
        summary(2.9),
      ]),
    },
    "web-video-loaded": {
      note: "The same reply with images.remote = always: the host fetched the attachment and the copy plays inline.",
      chipHost: {
        policy: { remoteImages: "always" as const },
        media: { [WEB_VIDEO]: `data:video/mp4;base64,${LOGIN_TESTS_MP4}` },
      },
      snapshot: chat([
        user("Did the PR's recording show the login tests passing?", 3),
        assistant(WEB_VIDEO_REPLY, 2.9),
        summary(2.9),
      ]),
    },
    "vega-lite-chart": {
      note: "A vega-lite fence in a reply draws as a chart (the markdown viewer's bundled Vega); Code shows the spec.",
      height: 520,
      snapshot: chat([user("Which build targets are slowest?", 3), assistant(BUILD_CHART, 2.9), summary(2.9)]),
    },
    "long-code": {
      note: "Long code blocks: wide lines, many lines, two languages.",
      height: 720,
      snapshot: chat([user("Show me the whole module", 4), assistant(LONG_CODE, 3.9), summary(3.9)]),
    },
    math: {
      note: "Inline and display math (KaTeX).",
      snapshot: chat([user("What is the expected wait?", 4), assistant(MATH, 3.9), summary(3.9)]),
    },
    "math-delimiters": {
      note: "Math in all four delimiters ($…$, \\(…\\), \\[…\\], $$…$$) beside prices and shell $$ that stay text.",
      snapshot: chat([
        user("How likely is a retry inside t seconds?", 4),
        assistant(MATH_DELIMITERS, 3.9),
        summary(3.9),
      ]),
    },
    permission: {
      note: "A Claude Bash call waiting for permission (Claude Code desktop's prompt): a glass card titled with the call's description, the script's first line clamped in mono, and Allow once, Always allow and Deny.",
      snapshot: BASH_PERMISSION,
    },
    "permission-expanded": {
      note: "Play: Show full command opens the whole script, wrapper included, in a scrolling mono block.",
      snapshot: BASH_PERMISSION,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Show full command" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-command-full"));
      },
    },
    "permission-deny-feedback": {
      note: "Play: Deny opens the field for what Claude should do instead; its send denies the call with that text.",
      snapshot: BASH_PERMISSION,
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Deny" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-permission-feedback textarea"));
      },
    },
    "secret-card": {
      note: "Play: an agent asks for a secret (cx-ncc.42). The value is typed in the private field and Provide sends it to acpmux only; the card closes and the chat never shows the value.",
      snapshot: chat([user("Create the Stripe test webhook", 1), assistant("I need your Stripe key for that.", 0.9)], {
        isWorking: true,
        secret: {
          secretId: "gallery-secret",
          name: "STRIPE_API_KEY",
          reason: "Create the test webhook",
        },
      }),
      afterCall: {
        "chat.secret": chat(
          [user("Create the Stripe test webhook", 1), assistant("I need your Stripe key for that.", 0.9)],
          {
            isWorking: true,
          },
        ),
      },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-secret-card-field" });
        await ctx.type("sk-test-51Hx9", { selector: ".acpmux-secret-card-field" });
        await ctx.click({ role: "button", name: "Provide" });
        await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-secret-card"));
      },
      checks: {
        layoutShiftMax: {
          value: 0.08,
          reason:
            "The card leaves the bottom stack, which lies over the transcript's foot (bottomStack.css): the stack's unpainted wrapper (div.acpmux-dock, the only source) shrinks from its top, 0.062 measured; the composer and the rows do not move.",
        },
      },
    },
    "secret-card-unsent": {
      note: "Play: a secret typed in the card whose send has not gone through stays in the private field, so the person does not retype it.",
      snapshot: chat([user("Create the Stripe test webhook", 1), assistant("I need your Stripe key for that.", 0.9)], {
        isWorking: true,
        secret: {
          secretId: "gallery-secret",
          name: "STRIPE_API_KEY",
          reason: "Create the test webhook",
        },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-secret-card-field" });
        await ctx.type("sk-test-51Hx9", { selector: ".acpmux-secret-card-field" });
        await ctx.waitFor(() =>
          ctx.document.querySelector(".acpmux-secret-card-field")?.matches("input:not(:placeholder-shown)"),
        );
      },
    },
    "markdown-fence-pipes": {
      note: "A reply that quotes Markdown in a four-backtick fence (its inner three-backtick fence stays text) and a table whose cell holds an escaped pipe (a literal pipe, not a column break).",
      snapshot: chat(
        [
          user("Show me the fence and the table", 2),
          assistant(
            [
              "Quoting a reply keeps its own fence:",
              "",
              "````md",
              "```js",
              "console.log(1);",
              "```",
              "````",
              "",
              "| command | note |",
              "| --- | --- |",
              "| `ls \\| head` | the pipe stays in its cell |",
            ].join("\n"),
            1,
          ),
        ],
        { isWorking: false },
      ),
    },
    queued: {
      note: "Prompts queued behind a running turn.",
      snapshot: chat([user(prompt, 2), assistant("Working on the policy type…", 1, { streaming: true })], {
        isWorking: true,
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          { id: "q2", prompt: "And update the README" },
        ],
      }),
    },
    "long-chat": {
      note: "Many turns over two days (date lines, virtualized rows).",
      height: 720,
      snapshot: chat(longChatRows),
    },
    "scrolling-history": {
      note: "Play: move from the latest reply to the oldest history while the virtual transcript keeps its lead rows mounted.",
      height: 560,
      snapshot: chat(longChatRows),
      play: async (ctx) => {
        await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-row[aria-posinset="1"]'));
      },
    },
    "jump-latest": {
      note: "Play: scroll up from the latest reply; Jump to latest shows as a glass circle centered above the composer.",
      height: 560,
      snapshot: chat(longChatRows),
      play: async (ctx) => {
        await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest[data-shown]"));
      },
    },
    "jump-latest-working": {
      note: "Play: scrolled up while a reply streams below, Jump to latest keeps its static arrow.",
      height: 560,
      snapshot: chat(longChatRows, { isWorking: true }),
      play: async (ctx) => {
        await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest[data-shown]"));
      },
    },
    selection: {
      note: "Play: select a whole prompt row, then the assistant's rendered prose; both remain browser text selection.",
      snapshot: chat(selectionRows),
      play: async (ctx) => {
        await ctx.selectText({ selector: '[data-row-id="gallery-selection-user"]' });
        await ctx.selectText({ selector: '[data-row-id="gallery-selection-answer"] .cv-md' });
      },
    },
    "keyboard-selection": {
      note: "Play: move the transcript roving focus with Shift+ArrowDown and keep the selected range visible.",
      snapshot: chat(selectionRows),
      play: async (ctx) => {
        await ctx.focus({ selector: '[data-row-id="gallery-selection-user"]' });
        await ctx.press("Shift+ArrowDown");
        await ctx.waitFor(
          () =>
            ctx.document
              .querySelector('[data-row-id="gallery-selection-answer"]')
              ?.getAttribute("data-transcript-selected") === "true",
        );
      },
    },
    "keyboard-copy": {
      note: "Play: select a transcript range, invoke both Ctrl-C and Cmd-C, and keep the range focused for copy feedback.",
      snapshot: chat(selectionRows),
      play: async (ctx) => {
        await ctx.focus({ selector: '[data-row-id="gallery-selection-user"]' });
        await ctx.press("Shift+ArrowDown");
        await ctx.waitFor(
          () =>
            ctx.document
              .querySelector('[data-row-id="gallery-selection-answer"]')
              ?.getAttribute("data-transcript-selected") === "true",
        );
        await ctx.press("Control+c");
        await ctx.press("Meta+c");
        await ctx.waitFor(() => {
          const answer = ctx.document.querySelector('[data-row-id="gallery-selection-answer"]');
          return (
            answer?.getAttribute("data-transcript-selected") === "true" && answer.contains(ctx.document.activeElement)
          );
        });
      },
    },
    "keyboard-focus": {
      note: "Play: focus the Worked for disclosure and press Enter; the tool details open without leaving the transcript.",
      snapshot: chat(keyboardRows),
      checks: {
        layoutShiftMax: {
          value: 0.25,
          reason: "Opening the disclosure intentionally reveals its folded tool rows below the focused control.",
        },
      },
      play: async (ctx) => {
        const worked = { selector: ".cv-worked" };
        await ctx.focus(worked);
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.find(worked).getAttribute("aria-expanded") === "true");
      },
    },
    "shell-command-only": {
      note: "A command call with no output still opens a compact Shell block with its command line.",
      checks: shellDisclosureChecks,
      snapshot: chat(shellRows("gallery-shell-command", "Run the focused test", "bun test src/net --filter retry")),
      play: openSingleShell,
    },
    "shell-success-output": {
      note: "A successful command keeps its output selectable below the command line.",
      checks: shellDisclosureChecks,
      snapshot: chat(
        shellRows("gallery-shell-success", "Run the focused test", "bun test src/net --filter retry", {
          output: "3 pass\n0 fail",
          exitCode: 0,
        }),
      ),
      play: async (ctx) => {
        await openSingleShell(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".cv-shell__output")?.textContent === "3 pass\n0 fail");
      },
    },
    "shell-long-colored-output": {
      note: "A long, coloured test run: no colour codes, its end scrolling in an eight-line box with Show all 1200 lines (every line, though only the last 400 draw until opened), and Wrap lines and Copy in the label.",
      checks: shellDisclosureChecks,
      snapshot: chat(
        shellRows("gallery-shell-long", "Run the whole suite", "bun test", {
          output: Array.from(
            { length: 1200 },
            (_, index) => `\x1b[32m(pass)\x1b[0m retry backoff case ${index + 1} \x1b[2m[0.${index % 10}ms]\x1b[0m`,
          ).join("\n"),
          exitCode: 0,
        }),
      ),
      play: async (ctx) => {
        await openSingleShell(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".cv-output-more")?.textContent === "Show all 1200 lines");
      },
    },
    "edit-long-line-code": {
      note: "An Edited card's diff for code: long lines stay whole, the right edge fades while more lies past it, a thin sideways scrollbar shows under the lines at rest (trackpad or Shift-wheel scrolls it), and Wrap lines sits beside Copy.",
      checks: shellDisclosureChecks,
      snapshot: chat(editedRows("gallery-edit-code", "src/net/retryPolicy.ts", EDIT_LONG_CODE)),
      play: openEditedDiff,
    },
    "edit-long-line-prose": {
      note: "An Edited card's diff for a Markdown file: long lines wrap, each hanging under its start; its first eight lines show under a fade with Show all 21 lines.",
      checks: shellDisclosureChecks,
      snapshot: chat(editedRows("gallery-edit-prose", "docs/codex-excursions.md", EDIT_LONG_PROSE)),
      play: openEditedDiff,
    },
    "edit-preview-open": {
      note: "Show all 21 lines opens the whole diff and turns into Show less.",
      checks: shellDisclosureChecks,
      snapshot: chat(editedRows("gallery-edit-open", "docs/codex-excursions.md", EDIT_LONG_PROSE)),
      play: async (ctx) => {
        await openEditedDiff(ctx);
        await ctx.click({ role: "button", name: "Show all 21 lines" });
        await ctx.waitFor(
          () => ctx.document.querySelector(".cv-edit-diff .cv-output-more")?.textContent === "Show less",
        );
      },
    },
    "shell-unwrapped-long-line": {
      note: "A command's output with Wrap lines off: each line stays whole, the right edge fades while more lies past it, and a thin sideways scrollbar shows under the lines at rest.",
      checks: shellDisclosureChecks,
      snapshot: chat(
        shellRows("gallery-shell-unwrapped", "Print the retry log", "cat logs/retry.log", {
          output: SHELL_LONG_LOG,
          exitCode: 0,
        }),
      ),
      play: async (ctx) => {
        await openSingleShell(ctx);
        await ctx.click({ selector: '.cv-shell__actions button[aria-label="Wrap lines"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-shell__body")?.getAttribute("data-wrap") === "false");
      },
    },
    "edit-long-line-code-cut": {
      note: "An Edited card's diff for code past eight lines, lines whole: the first eight under a fade, and below them the thin sideways scrollbar, shown at rest while the lines run past the right edge.",
      checks: shellDisclosureChecks,
      snapshot: chat(editedRows("gallery-edit-code-cut", "src/net/uploadRoutes.ts", EDIT_LONG_CODE_CUT)),
      play: openEditedDiff,
    },
    "shell-unwrapped-long-cut": {
      note: "A long command output with Wrap lines off: the first eight lines under a fade, and below them the thin sideways scrollbar, shown at rest while the lines run past the right edge.",
      checks: shellDisclosureChecks,
      snapshot: chat(
        shellRows("gallery-shell-unwrapped-cut", "Print the retry log", "cat logs/retry.log", {
          output: SHELL_LONG_LOG_CUT,
          exitCode: 0,
        }),
      ),
      play: async (ctx) => {
        await openSingleShell(ctx);
        await ctx.click({ selector: '.cv-shell__actions button[aria-label="Wrap lines"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-shell__body")?.getAttribute("data-wrap") === "false");
      },
    },
    "shell-live-unwrapped-long-line": {
      note: "A running command's output with Wrap lines off: the thin sideways scrollbar's lane stays under the lines while it runs, so a line that starts or stops running past the edge does not move the transcript.",
      checks: shellDisclosureChecks,
      snapshot: chat(liveShellRows("gallery-shell-live", SHELL_LONG_LOG), { isWorking: true }),
      play: unwrapCall(".cv-shell__body", ".cv-shell__actions"),
    },
    "shell-live-unwrapped-long-cut": {
      note: "A running command's long output with Wrap lines off: the first eight lines under a fade and the sideways scrollbar's lane under them while it runs.",
      checks: shellDisclosureChecks,
      snapshot: chat(liveShellRows("gallery-shell-live-cut", SHELL_LONG_LOG_CUT), { isWorking: true }),
      play: unwrapCall(".cv-shell__body", ".cv-shell__actions"),
    },
    "output-unwrapped-long-line": {
      note: "A call's output with Wrap lines off: each line stays whole and a thin sideways scrollbar shows at rest in the output's bottom padding.",
      checks: shellDisclosureChecks,
      snapshot: chat([
        user("Fetch the retry log", 3, { id: "gallery-output-unwrapped-user" }),
        activity([tool("Fetch the retry log", "fetch", "completed", { output: SHELL_LONG_LOG })], 2.8, {
          id: "gallery-output-unwrapped-activity",
        }),
        assistant("The output stays inside the transcript row.", 2.6, { id: "gallery-output-unwrapped-answer" }),
        summary(2.6, { id: "gallery-output-unwrapped-summary", status: "completed", toolCount: 1 }),
      ]),
      play: unwrapCall(".cv-tool-output", ".cv-tool-output__actions"),
    },
    "output-unwrapped-long-cut": {
      note: "A call's long output with Wrap lines off: its first eight lines whole under a fade, and the thin sideways scrollbar under them in the output's bottom padding, the preview that much taller (Codex review of #23967).",
      checks: shellDisclosureChecks,
      snapshot: chat([
        user("Fetch the whole retry log", 3, { id: "gallery-output-unwrapped-cut-user" }),
        activity([tool("Fetch the whole retry log", "fetch", "completed", { output: SHELL_LONG_LOG_CUT })], 2.8, {
          id: "gallery-output-unwrapped-cut-activity",
        }),
        assistant("Its first eight lines show; Show all opens the rest.", 2.6, {
          id: "gallery-output-unwrapped-cut-answer",
        }),
        summary(2.6, { id: "gallery-output-unwrapped-cut-summary", status: "completed", toolCount: 1 }),
      ]),
      play: unwrapCall(".cv-tool-output", ".cv-tool-output__actions"),
    },
    "shell-failed-exit": {
      note: "A failed command exposes its nonzero exit status alongside its output.",
      checks: shellDisclosureChecks,
      snapshot: chat(
        shellRows("gallery-shell-failed", "Run the focused test", "bun test src/net --filter retry", {
          status: "failed",
          output: "1 failing test",
          exitCode: 2,
        }),
      ),
      play: async (ctx) => {
        await openSingleShell(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".cv-shell__exit")?.textContent?.includes("2") ?? false);
      },
    },
    "shell-grouped-commands": {
      note: "Two consecutive commands use the real group disclosure and nested command-row disclosures.",
      checks: shellDisclosureChecks,
      snapshot: chat(groupedShellRows),
      play: openGroupedShells,
    },
    "long-commands-fill-row": {
      note: 'Leo 2026-10-22, of Ran rows cut with an ellipsis about two thirds across: "shouldnt these also ellipsis later". Long commands (a cp of two long paths, a gh pr comment) draw their whole first step and end in an ellipsis at the row\'s right edge, before the chevron; no 60-character cut. Play: open Worked for and the run; each command line is the whole step.',
      checks: shellDisclosureChecks,
      snapshot: chat(longCommandRows),
      play: async (ctx) => {
        await openWorked(ctx);
        await openFoldedRun(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-command").length === 2);
        const lines = [...ctx.document.querySelectorAll(".cv-command__line")].map((line) => line.textContent);
        if (lines[0] !== LONG_CP) throw new Error(`the cp row reads ${lines[0]}, not the whole command`);
      },
    },
    "worked-for-opening": {
      note: "Play: open Worked for and hold its fold halfway: the rows below slide down from where they were, the steps it shows fade in and the chevron turns. With animations off or under Reduce Motion it opens at once.",
      checks: shellDisclosureChecks,
      snapshot: chat(turnFoldRows),
      play: (ctx) => toggleWorkedHalfway(ctx, true),
    },
    "worked-for-closing": {
      note: "Play: open Worked for, then close it and hold the fold halfway: the steps fade out where they were while the rows below slide up over them.",
      checks: shellDisclosureChecks,
      snapshot: chat(turnFoldRows),
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-worked" });
        await ctx.waitFor(
          () =>
            ctx.find({ selector: ".cv-worked" }).getAttribute("aria-expanded") === "true" &&
            ctx.document.getAnimations().every((animation) => animation.playState !== "running"),
        );
        await toggleWorkedHalfway(ctx, false);
      },
    },
    "fold-holds-clicked-line": {
      note: "Play: at the latest row, open Worked for, then a command, then close it; each line stays where it was clicked while its fold plays (height and opacity, the chevron turning).",
      checks: shellDisclosureChecks,
      snapshot: chat([...longChatRows.slice(-12), ...groupedShellRows]),
      play: async (ctx) => {
        await clickHoldsLine(ctx, ".cv-worked", true);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-command").length === 2);
        await clickHoldsLine(ctx, ".cv-command", true);
        await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-shell__command")));
        await clickHoldsLine(ctx, ".cv-command", false);
      },
    },
    "cut-line-closed": {
      note: "Leo, ask-486cb2cec3: \"why the fuck did you guys ffucking ellipsis EVERYTHING WITH NO WAY TO EXPAND WHAT WAS SAID TO SEE\". A search call's long pattern cut at the row's edge, closed. Play: open Worked for.",
      checks: shellDisclosureChecks,
      snapshot: chat(cutLineRows),
      play: showCutLine(false),
    },
    "cut-line-open": {
      note: "The same line opened: its label wraps to the whole pattern above the output, never only its first words.",
      checks: shellDisclosureChecks,
      snapshot: chat(cutLineRows),
      play: showCutLine(true),
    },
    "show-less-keeps-place": {
      note: "A long command output at the transcript's end, opened with Show all, then closed from Show less after scrolling down to it: the view stays on the control the reader clicked, with the rows above it, not on blank room under a row that closed up above the view.",
      checks: {
        layoutShiftMax: {
          value: 1,
          reason:
            "Show all and Show less open and close a 160-line output; the play checks the clicked control stays in view.",
        },
      },
      snapshot: chat(
        shellRows("gallery-show-less", "Run the whole suite", "bun test", { output: SHOW_LESS_LOG, exitCode: 0 }),
      ),
      play: showLessAtEnd,
    },
    "background-turns": {
      note: "A person's turn, then a turn the agent ran on its own after a background task finished with nothing new to tell: one muted line, Background task finished, closed. Then one that has something to say (a failure and a question), drawn as its rows came. No Worked for or footer for either. Play: open the quiet line.",
      snapshot: chat(backgroundTurnRows),
      checks: {
        layoutShiftMax: {
          value: 0.5,
          reason: "Opening the quiet line intentionally reveals its rows below the clicked line.",
        },
      },
      play: async (ctx) => {
        const line = { selector: `[data-row-id="${backgroundTurnRowId("gallery-bg-quiet")}"] .cv-background-turn` };
        await ctx.click(line);
        await ctx.waitFor(() => ctx.find(line).getAttribute("aria-expanded") === "true");
      },
    },
    "fold-no-blank-collapsed": {
      note: "A long turn after a background task's notification, bookkeeping the person never typed and another agent's message, folded: Worked for, then the reply right under it. Before, each render row that draws nothing (in the app, an update that joined the first card; the gallery page draws no render frames) left a 34px band between them.",
      snapshot: chat(foldNoBlankRows),
    },
    "fold-no-blank-open": {
      note: "The same turn opened: the work in order, with no band where a step of only quiet thoughts sits (it draws nothing). Before, that step kept its estimate, 26px a thought, as a blank band under the first commands. Play: open Worked for.",
      snapshot: chat(foldNoBlankRows),
      checks: {
        layoutShiftMax: {
          value: 0.5,
          reason: "Opening the disclosure intentionally reveals its folded tool rows below the clicked line.",
        },
      },
      play: async (ctx) => {
        const worked = { selector: '[data-row-id="worked-fold-no-blank-user"] .cv-worked' };
        await ctx.click(worked);
        await ctx.waitFor(() => ctx.find(worked).getAttribute("aria-expanded") === "true");
      },
    },
  },
});

/// Two completed turns of a chat whose agent family is `family` (cx-yqiv).
/// Both turns offer Fork, and the earlier one's forks through that turn's summary (seq 3).
async function forkEarlierTurn(ctx: PlayContext) {
  const page = ctx.document.defaultView as unknown as {
    cmuxGalleryLog: { method: string; params?: { throughSeq?: number } }[];
  };
  // The answers' footers: a prompt's own row has a Fork too (UserBubble.tsx).
  const forks = () => [
    ...ctx.document.querySelectorAll<HTMLButtonElement>('.cv-turn-actions button[aria-label="Fork from here"]'),
  ];
  await ctx.focus({ selector: "[contenteditable='true']" });
  await ctx.waitFor(() => forks().length === 2);
  forks()[0]!.click();
  await ctx.waitFor(() =>
    page.cmuxGalleryLog.some(({ method, params }) => method === "chat.fork" && params?.throughSeq === 3),
  );
}

function forkTurns(family: string | undefined) {
  const snapshot = chat([
    user("Add retry with backoff to the uploader", 9, { seq: 1 }),
    assistant("Done: three tries, doubling from 200 ms, only on 5xx and timeouts.", 8.5),
    summary(8.5, { seq: 3, status: "completed" }),
    user("Now cover it with a test that fakes two timeouts", 6, { seq: 4 }),
    assistant("Added `uploader.retry.test.ts`; it passes and fails without the retry.", 5),
    summary(5, { seq: 6, status: "completed" }),
  ]);
  return { ...snapshot, summary: snapshot.summary && { ...snapshot.summary, family } };
}
