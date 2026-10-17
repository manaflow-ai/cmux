// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The transcript's row kinds and states (conversation/*, App.tsx VirtualTranscript), each as the
// snapshot the pane bridge would deliver. src/gallery/format.ts describes the format.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { workedTurnRows } from "../workedTurn";
import { minutesAgo } from "../../../gallery/clock";
import {
  BUILD_REPORT_PDF_PAGE_PNG,
  BUILD_TIMES_PNG,
  LOGIN_SCREENSHOT_PNG,
  LOGIN_TESTS_MP4,
} from "../../../gallery/fixtures/toolImages";

const prompt = "Add retries with backoff to the fetch helper";

const selectionRows = [
  user("Select this prompt to copy it into a bug report", 5, { id: "gallery-selection-user" }),
  assistant(
    "The response stays selectable while controls keep their keyboard focus.\n\nUse the highlighted prose to compare the real transcript against the reference.",
    4.9,
    { id: "gallery-selection-answer" },
  ),
  summary(4.9, { id: "gallery-selection-summary", status: "completed" }),
];

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

/// One call in the gallery's log: a host bridge call, or `acpmux <method>` for a request the page
/// sent to the in-page mock daemon (mock.ts).
type GalleryCall = { method: string; params?: { id?: string; sessionId?: string; archived?: unknown } };
/// The pane's client attached the mock daemon's chat (the menu can show before, from the stage's
/// snapshot), and its header offers the chat menu.
const chatMenuReady = async (ctx: PlayContext) => {
  const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: GalleryCall[] }).cmuxGalleryLog;
  await ctx.waitFor(() => log.some(({ method }) => method === "acpmux _acpmux/attach"), { capMs: 10_000 });
  await ctx.waitFor(() => ctx.document.querySelector('[aria-label="Chat actions"]'), { capMs: 10_000 });
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

const openGroupedShells = async (ctx: PlayContext) => {
  await openWorked(ctx);
  await ctx.click({ selector: ".cv-tool.is-toggle" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-command").length === 2);
  await ctx.click({ selector: ".cv-command" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-shell__command").length === 1);
  await ctx.click({ selector: ".cv-command:nth-of-type(2)" });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-shell__command").length === 2);
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-shell__exit")));
};

const shellDisclosureChecks = {
  layoutShiftMax: {
    value: 0.25,
    reason: "Opening command details intentionally reveals the shell block below its focused row.",
  },
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
          encoding: { y: { field: "target", type: "nominal", sort: "-x" }, x: { field: "p90", type: "quantitative" } },
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
    "agent-session/acpmux/chips/ReplyMedia.tsx",
    "agent-session/acpmux/conversation/icons.tsx#Expand",
    "agent-session/acpmux/conversation/ToolRun.tsx",
    "agent-session/acpmux/conversation/transcriptDisclosure.tsx#TranscriptDisclosureProvider",
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
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
    "agent-session/acpmux/FailedPrompt.tsx",
    "agent-session/acpmux/PermissionCard.tsx",
  ],
  variants: {
    conversation: {
      note: "A finished exchange: prompt, markdown reply, turn footer.",
      snapshot: chat([
        user(prompt, 30),
        assistant(MARKDOWN_MIX, 29),
        summary(29, { status: "completed", durationMs: 41_000, seq: 2 }),
      ]),
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
    tasks: {
      note: "Checked, unchecked, nested and wrapping task-list items.",
      snapshot: chat([user("Review the release checklist", 4), assistant(TASKS_REPLY, 3)]),
    },
    thinking: {
      note: "A turn that started and has no output yet.",
      snapshot: chat([user(prompt, 0.2)], { isWorking: true }),
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
        const page = ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: { lastCodeBlock?(): string | null } };
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
        await ctx.waitFor(() => ctx.document.querySelectorAll('button[aria-label="Fork from here"]').length === 1);
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
      note: "Play: a thought shows in full on its row, wrapped after a muted Thought label, with nothing to open and no tooltip (Leo 2026-10-13).",
      snapshot: chat(
        [
          user(prompt, 2),
          activity(
            [
              thought(
                "Check how the helper parses errors first.\n\nThe retry wrapper in src/net/client.ts swallows the status code, so a 429 looks like a network failure.\n\nRetry only on 429 and 5xx, with jittered backoff capped at three attempts.",
              ),
              tool("Read client.ts", "read", "completed", {
                locations: [{ path: "/Users/you/src/atlas-web/src/net/client.ts" }],
              }),
            ],
            1.5,
          ),
        ],
        { isWorking: true },
      ),
      play: async (ctx) => {
        const row = () => ctx.document.querySelector<HTMLElement>(".cv-thought");
        await ctx.waitFor(() => row()?.textContent?.includes("jittered backoff capped at three attempts") ?? false);
        // Hovering the thought used to pop its full text as a tooltip.
        await ctx.hover({ selector: ".cv-thought__text" });
        if (row()!.matches("button") || row()!.hasAttribute("aria-expanded"))
          throw new Error("a thought is a row of text, not a toggle");
        if (row()!.closest("[title]") || row()!.querySelector("[title]")) throw new Error("a thought shows no tooltip");
      },
    },
    "long-thought-streaming": {
      note: "A long thought still streaming shows in full (with the Debug toggle agentPane.debug.foldLongThoughts on, it folds only once done).",
      snapshot: chat([user(prompt, 2), activity([thought(LONG_THOUGHT)], 1.5)], { isWorking: true }),
    },
    "long-thought-done": {
      note: "A long thought followed by a step. With the Debug toggle agentPane.debug.foldLongThoughts on (data-fold-long-thoughts on <html>), it folds to its first line; off, it shows in full as before.",
      snapshot: chat(
        [
          user(prompt, 2),
          activity(
            [
              thought(LONG_THOUGHT),
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
          value: 0.01,
          reason: "Find opens the fold that holds the match, which moves the rows below on purpose.",
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
        const page = ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: { command?(name: string): void } };
        page.cmuxAcpmuxBridge?.command?.("find");
        await ctx.waitFor(() => ctx.document.activeElement?.classList.contains("acpmux-find__field") ?? false);
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
    "working-tools": {
      note: "Tool calls running in a live turn.",
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
    "turn-error": {
      note: "A turn the agent ended with an error.",
      snapshot: chat([
        user(prompt, 6),
        summary(5.5, { status: "failed", error: "The agent stopped: model overloaded (529). Try again in a moment." }),
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
        summary(5.5, { status: "failed", error: "The model stopped before reading the document. Try again." }),
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
              'API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"unauthorized"}} from http://cmux-lawrences-mac-mini:31415/v1/messages',
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
          summary(5.5, { status: "failed", error: "API Error: 401 authentication_error: invalid x-api-key" }),
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
    "edited-files": {
      note: "A turn that edited three files: the edited-files card with Undo.",
      snapshot: chat([...workedTurnRows(minutesAgo(15)), summary(14, { status: "completed", toolCount: 3 })]),
    },
    "preview-card": {
      note: "A turn that started a local server: the preview card.",
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
          "/Users/you/src/atlas-web/out/build-report.pdf": { place: "root" as const, folder: false },
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
        paths: { "/Users/you/src/atlas-web/out/login-tests.mp4": { place: "root" as const, folder: false } },
        media: { "/Users/you/src/atlas-web/out/login-tests.mp4": `data:video/mp4;base64,${LOGIN_TESTS_MP4}` },
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
      note: "A tool call waiting for the user's permission.",
      snapshot: chat(
        [
          user("Install the tree package", 1),
          activity([tool("bun add @pierre/trees", "execute", "pending", { command: "bun add @pierre/trees" })], 0.9),
        ],
        {
          isWorking: true,
          permission: {
            permissionId: "gallery-permission",
            title: "bun add @pierre/trees",
            kind: "execute",
            pending: true,
            options: [
              { id: "allow_once", name: "Allow", allow: true },
              { id: "allow_always", name: "Always allow", allow: true },
              { id: "reject_once", name: "Deny", allow: false },
            ],
          },
        },
      ),
    },
    "secret-card": {
      note: "Play: an agent asks for a secret (cx-ncc.42). The value is typed in the private field and Provide sends it to acpmux only; the card closes and the chat never shows the value.",
      snapshot: chat([user("Create the Stripe test webhook", 1), assistant("I need your Stripe key for that.", 0.9)], {
        isWorking: true,
        secret: { secretId: "gallery-secret", name: "STRIPE_API_KEY", reason: "Create the test webhook" },
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
      note: "Play: scrolled up while a reply streams below, Jump to latest shows its dots.",
      height: 560,
      snapshot: chat(longChatRows, { isWorking: true }),
      play: async (ctx) => {
        await ctx.scroll({ selector: ".acpmux-scroll" }, "top");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-jump-latest[data-shown][data-working]"));
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
      note: "A long, coloured test run: no colour codes, its last 400 lines under a cut mark, Show all output, and Copy in the label.",
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
        await ctx.waitFor(() => ctx.document.querySelector(".cv-output-more")?.textContent === "Show all output");
      },
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
  },
});

/// Two completed turns of a chat whose agent family is `family` (cx-yqiv).
/// Both turns offer Fork, and the earlier one's forks through that turn's summary (seq 3).
async function forkEarlierTurn(ctx: PlayContext) {
  const page = ctx.document.defaultView as unknown as {
    cmuxGalleryLog: { method: string; params?: { throughSeq?: number } }[];
  };
  const forks = () => [...ctx.document.querySelectorAll<HTMLButtonElement>('button[aria-label="Fork from here"]')];
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
