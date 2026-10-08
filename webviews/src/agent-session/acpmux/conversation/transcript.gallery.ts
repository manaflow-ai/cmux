// l10n-allow-file: gallery fixtures (sample prompts and replies), not shipped UI.
// The transcript's row kinds and states (conversation/*, App.tsx VirtualTranscript), each as the
// snapshot the pane bridge would deliver. src/gallery/format.ts describes the format.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
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
  covers: [
    "page:cmux.agent",
    "agent-session/acpmux/App.tsx#VirtualTranscript",
    "agent-session/acpmux/App.tsx#AcpmuxApp",
    "agent-session/acpmux/conversation/MessageCard.tsx",
    "agent-session/acpmux/conversation/Markdown.tsx",
    "agent-session/acpmux/conversation/RevealedMarkdown.tsx",
    "agent-session/acpmux/conversation/CodeBlock.tsx",
    "agent-session/acpmux/conversation/DiagramBlock.tsx",
    "agent-session/acpmux/conversation/StreamingCode.tsx",
    "agent-session/acpmux/conversation/Math.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/chips/ReplyMedia.tsx",
    "agent-session/acpmux/conversation/icons.tsx#Expand",
    "agent-session/acpmux/conversation/ToolRun.tsx",
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
    "agent-session/acpmux/conversation/CommandRow.tsx",
    "agent-session/acpmux/conversation/EditDiff.tsx",
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
        summary(29, { status: "completed", durationMs: 41_000 }),
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
    selection: {
      note: "Play: select a whole prompt row, then the assistant's rendered prose; both remain browser text selection.",
      snapshot: chat(selectionRows),
      play: async (ctx) => {
        await ctx.selectText({ selector: '[data-row-id="gallery-selection-user"]' });
        await ctx.selectText({ selector: '[data-row-id="gallery-selection-answer"] .cv-md' });
      },
    },
    "keyboard-focus": {
      note: "Play: focus the Worked for disclosure and press Enter; the tool details open without leaving the transcript.",
      snapshot: chat(keyboardRows),
      play: async (ctx) => {
        const worked = { selector: ".cv-worked" };
        await ctx.focus(worked);
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.find(worked).getAttribute("aria-expanded") === "true");
      },
    },
  },
});
