// The mock daemon's seeded workspace: what a few days of real use look like, so a mock-mode
// pane shows a populated sidebar and a worked turn instead of one empty session. Captures and
// demos run on it by default; a recorded MockScript still starts from an empty session.
//
// The session fields past acpmux's summary (host, hostKind, branch, worktree, pinned,
// pullRequest) are what the pane will read once the daemon reports them; acpmux does not send
// them yet.

export type MockSession = {
  sessionId: string;
  title: string;
  harness: "claude" | "codex";
  model: string;
  status: "idle" | "running" | "waiting" | "disconnected";
  cwd: string;
  /// Minutes since the session last changed.
  ago: number;
  host: string;
  hostKind: "local" | "cloud";
  branch?: string;
  worktree?: string;
  pinned?: boolean;
  unread?: boolean;
  pendingPermissions?: number;
  pullRequest?: { number: number; title: string; state: "open" | "draft" | "merged"; reviewReady?: boolean };
  /// The agent's last reply, for sessions other than the worked one.
  reply?: string;
  /// What a session needing input waits on: the tool call its permission card names.
  permission?: { title: string; kind: string };
};

type Update = Record<string, unknown>;
/// One seeded event, `ago` milliseconds before the fixture loads.
export type SeedStep = ({ update: Update } | { mux: string; msg?: Record<string, unknown> }) & { ago: number };

export const LOCAL_HOST = "This Mac";

export const claudeModels = [
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
  { id: "claude-haiku-4-5", name: "Haiku 4.5" },
];
export const codexModels = [
  { id: "gpt-6-astra", name: "GPT-6-Astra" },
  { id: "gpt-6-mini", name: "GPT-6 mini" },
];

const claudeModes = {
  availableModes: [
    { id: "default", name: "Ask before edits" },
    { id: "acceptEdits", name: "Accept edits" },
    { id: "plan", name: "Plan" },
    { id: "bypassPermissions", name: "Full access" },
  ],
  currentModeId: "bypassPermissions",
};
const codexModes = {
  availableModes: [
    { id: "read-only", name: "Read only" },
    { id: "auto", name: "Auto" },
    { id: "full-access", name: "Full access" },
  ],
  currentModeId: "auto",
};
const effort = (currentValue: string) => [
  {
    id: "effort",
    name: "Effort",
    category: "thought_level",
    currentValue,
    options: [
      { value: "low", name: "Low" },
      { value: "medium", name: "Medium" },
      { value: "high", name: "High" },
    ],
  },
];

/// The session the pane opens on: one fully worked turn.
export const WORKED_SESSION = "mock-session";
const CMUX = "~/code/cmux";

export const mockSessions: MockSession[] = [
  {
    sessionId: WORKED_SESSION,
    title: "Add retry backoff to the fleet uploader",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 2,
    host: LOCAL_HOST,
    hostKind: "local",
    branch: "feat-upload-retry",
    worktree: "~/code/cmux-worktrees/upload-retry",
    pinned: true,
    pullRequest: {
      number: 18204,
      title: "fleet: retry artifact uploads with backoff",
      state: "open",
      reviewReady: true,
    },
  },
  {
    sessionId: "mock-sidebar-flicker",
    title: "Fix sidebar flicker on theme change",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "running",
    cwd: CMUX,
    ago: 4,
    host: "hearty-beige-elk",
    hostKind: "cloud",
    branch: "fix-sidebar-flicker",
    reply:
      "The sidebar reads the theme before the window applies it, so the first frame uses the old background. I'm moving the read after `applyTheme` and checking every theme.",
  },
  {
    sessionId: "mock-tab-strip",
    title: "Review the terminal tab strip",
    harness: "claude",
    model: "claude-sonnet-5-5",
    status: "waiting",
    pendingPermissions: 1,
    cwd: CMUX,
    ago: 9,
    host: LOCAL_HOST,
    hostKind: "local",
    permission: { title: "Run bun run lint:ci", kind: "execute" },
    reply: "I'd like to run `bun run lint:ci` across the workspace to check the tab strip changes. Allow it?",
  },
  {
    sessionId: "mock-localize-changes",
    title: "Localize the changes view",
    harness: "codex",
    model: "gpt-6-astra",
    status: "idle",
    unread: true,
    cwd: CMUX,
    ago: 25,
    host: LOCAL_HOST,
    hostKind: "local",
    branch: "changes-view-l10n",
    pullRequest: { number: 18166, title: "Localize the changes view", state: "draft" },
    reply:
      "Added the 14 new strings to Localizable.xcstrings in all nine app locales. The Arabic layout mirrors the toolbar correctly.",
  },
  {
    sessionId: "mock-typing-latency",
    title: "Measure typing latency in split panes",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 70,
    host: LOCAL_HOST,
    hostKind: "local",
    reply:
      "Median keystroke-to-paint is 7.8 ms in a single pane and 8.1 ms with four splits. No regression against main.",
  },
  {
    sessionId: "mock-ci-cache",
    title: "Investigate CI cache misses",
    harness: "codex",
    model: "gpt-6-astra",
    status: "disconnected",
    cwd: CMUX,
    ago: 130,
    host: "hearty-beige-elk",
    hostKind: "cloud",
    branch: "ci-cache-keys",
    reply:
      "The cache key includes the runner's temp path, so every job misses. I was about to strip it when the machine went away.",
  },
  {
    sessionId: "mock-release-notes",
    title: "Draft release notes for 0.64",
    harness: "claude",
    model: "claude-sonnet-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 200,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Drafted CHANGELOG.md for 0.64: the agent pane, cloud machines in the sidebar, and 23 fixes.",
  },
  {
    sessionId: "mock-codex-composer",
    title: "Port the Codex composer",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 320,
    host: LOCAL_HOST,
    hostKind: "local",
    pullRequest: { number: 16601, title: "cmux-next agent pane: Codex composer and picker menus", state: "merged" },
    reply: "Merged. The composer, model menu and permission menu now follow the pane theme.",
  },
  {
    sessionId: "mock-markdown-lists",
    title: "Tighten markdown list spacing",
    harness: "claude",
    model: "claude-sonnet-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 1440,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Nested lists now sit 4 px under their item, matching Codex.",
  },
  {
    sessionId: "mock-restore-launch",
    title: "Speed up workspace restore on launch",
    harness: "claude",
    model: "claude-sonnet-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 2000,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Restoring 40 workspaces now takes 180 ms; terminals start lazily when first shown.",
  },
  {
    sessionId: "mock-ime",
    title: "Fix IME composition in the terminal",
    harness: "codex",
    model: "gpt-6-astra",
    status: "idle",
    cwd: CMUX,
    ago: 3100,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Marked text now draws at the cursor, and Enter commits the composition instead of sending it.",
  },
  {
    sessionId: "mock-tool-output",
    title: "Stream tool output in chunks",
    harness: "codex",
    model: "gpt-6-astra",
    status: "running",
    cwd: "~/code/acpmux",
    ago: 6,
    host: LOCAL_HOST,
    hostKind: "local",
    branch: "stream-tool-output",
    reply: "Splitting tool output into 8 KiB chunks so long shell runs stream instead of arriving at the end.",
  },
  {
    sessionId: "mock-resume",
    title: "Resume sessions after a daemon restart",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    unread: true,
    pinned: true,
    cwd: "~/code/acpmux",
    ago: 40,
    host: LOCAL_HOST,
    hostKind: "local",
    branch: "resume-after-restart",
    pullRequest: { number: 212, title: "Resume sessions after a daemon restart", state: "open", reviewReady: true },
    reply: "Sessions now reload from the event log on start. All 48 replay tests pass.",
  },
  {
    sessionId: "mock-replay-bench",
    title: "Benchmark event replay",
    harness: "claude",
    model: "claude-sonnet-5-5",
    status: "idle",
    cwd: "~/code/acpmux",
    ago: 1500,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Replaying 100k events takes 310 ms, 92% of it in JSON parsing.",
  },
  {
    sessionId: "mock-home-screen",
    title: "Match the Codex home screen",
    harness: "codex",
    model: "gpt-6-astra",
    status: "waiting",
    pendingPermissions: 1,
    cwd: "~/code/atlas-web",
    ago: 15,
    host: LOCAL_HOST,
    hostKind: "local",
    branch: "home-screen",
    worktree: "~/code/atlas-web-worktrees/home-screen",
    permission: { title: "Install @pierre/trees", kind: "execute" },
    reply: "I need to install `@pierre/trees`, which also updates package.json. Approve?",
  },
  {
    sessionId: "mock-light-theme",
    title: "Add light theme screenshots",
    harness: "claude",
    model: "claude-sonnet-5-5",
    status: "idle",
    cwd: "~/code/atlas-web",
    ago: 2900,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Captured 12 light-theme screens next to their dark versions.",
  },
  {
    sessionId: "mock-prorate",
    title: "Prorate seat changes mid-cycle",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    unread: true,
    cwd: "~/code/billing-service",
    ago: 65,
    host: LOCAL_HOST,
    hostKind: "local",
    branch: "prorate-seats",
    pullRequest: { number: 88, title: "Prorate seat changes mid-cycle", state: "open", reviewReady: true },
    reply: "Seat changes now prorate to the day. The invoice preview shows the credit as its own line.",
  },
  {
    sessionId: "mock-webhooks",
    title: "Retry failed Stripe webhooks",
    harness: "codex",
    model: "gpt-6-astra",
    status: "idle",
    cwd: "~/code/billing-service",
    ago: 4300,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Failed webhooks retry 5 times with jitter, then land in the dead-letter table.",
  },
  {
    sessionId: "mock-zsh",
    title: "Clean up zsh startup time",
    harness: "claude",
    model: "claude-haiku-4-5",
    status: "idle",
    cwd: "~/code/dotfiles",
    ago: 5800,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Startup went from 410 ms to 95 ms by lazy-loading nvm and compinit.",
  },
  {
    sessionId: "mock-ghostty-config",
    title: "Sync Ghostty config across machines",
    harness: "claude",
    model: "claude-sonnet-5-5",
    status: "idle",
    cwd: "~/code/dotfiles",
    ago: 8600,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "The config now lives in dotfiles and links into ~/.config/ghostty on each machine.",
  },
];

/// A session as `_acpmux/watch` and `_acpmux/attach` report it.
export function sessionSummary(session: MockSession, now: number, turnCount: number): Record<string, unknown> {
  const { ago, reply, permission: _permission, ...fields } = session;
  const preview = session.sessionId === WORKED_SESSION ? "Uploads now retry server errors with backoff." : reply;
  return {
    ...fields,
    preview,
    name: session.harness,
    updatedAt: now - ago * 60_000,
    turnCount,
    modes: session.harness === "codex" ? codexModes : claudeModes,
    configOptions: effort(session.harness === "codex" ? "high" : "medium"),
  };
}

/// A new chat in `cwd`: no turns yet.
export function newSessionSummary(sessionId: string, cwd: string, now: number): Record<string, unknown> {
  return {
    sessionId,
    title: "New chat",
    name: "claude",
    harness: "claude",
    model: claudeModels[0]!.id,
    status: "idle",
    cwd,
    host: LOCAL_HOST,
    hostKind: "local",
    branch: "main",
    updatedAt: now,
    turnCount: 0,
    modes: claudeModes,
    configOptions: effort("medium"),
  };
}

const text = (value: string): Update => ({
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text: value },
});
const tool = (toolCallId: string, kind: string, title: string, extra: Update = {}): Update => ({
  sessionUpdate: "tool_call",
  toolCallId,
  kind,
  title,
  status: "completed",
  ...extra,
});
const output = (value: string): Update => ({ content: [{ type: "content", content: { type: "text", text: value } }] });

const UPLOAD = `${CMUX}/Sources/Fleet/upload.ts`;
const RETRY = `${CMUX}/Sources/Fleet/retry.ts`;
const TEST = `${CMUX}/Sources/Fleet/upload.test.ts`;

const uploadBefore = `export async function uploadArtifact(url: string, body: Blob): Promise<void> {
  const response = await fetch(url, { method: "PUT", body });
  if (!response.ok) throw new Error(\`upload failed: \${response.status}\`);
}
`;
const uploadAfter = `import { withRetry } from "./retry";

export async function uploadArtifact(url: string, body: Blob): Promise<void> {
  await withRetry(async () => {
    const response = await fetch(url, { method: "PUT", body });
    if (response.status >= 500) throw new RetryableError(response.status);
    if (!response.ok) throw new Error(\`upload failed: \${response.status}\`);
  });
}
`;
const retrySource = `export class RetryableError extends Error {}

/// Runs \`attempt\` until it succeeds, waiting 0.5 s, 1 s, 2 s... between tries.
export async function withRetry<T>(attempt: () => Promise<T>, tries = 5): Promise<T> {
  for (let index = 0; ; index += 1) {
    try {
      return await attempt();
    } catch (error) {
      if (!(error instanceof RetryableError) || index + 1 >= tries) throw error;
      await new Promise((resolve) => setTimeout(resolve, 500 * 2 ** index));
    }
  }
}
`;
const testBefore = `import { expect, test } from "bun:test";
import { uploadArtifact } from "./upload";

test("uploads the artifact", async () => {
  await uploadArtifact(server.url, new Blob(["ok"]));
  expect(server.requests).toHaveLength(1);
});
`;
const testAfter = `${testBefore}
test("retries a 503 and then succeeds", async () => {
  server.failNext(2, 503);
  await uploadArtifact(server.url, new Blob(["ok"]));
  expect(server.requests).toHaveLength(3);
});
`;

/// The worked turn's files before and after it, which the mock's git scopes diff too.
export const workedSources = {
  root: CMUX,
  upload: { path: "Sources/Fleet/upload.ts", before: uploadBefore, after: uploadAfter },
  retry: { path: "Sources/Fleet/retry.ts", after: retrySource },
  test: { path: "Sources/Fleet/upload.test.ts", before: testBefore, after: testAfter },
};

const MIN = 60_000;
/// The worked turn starts 3.5 minutes before the fixture loads and ends about 2 minutes before.
const START = 3 * MIN + 30_000;

/// The worked session's history: one prompt and a full turn with a search, reads, a code
/// block, edits to three files and a test run, ending a few minutes ago.
export const workedTurn: SeedStep[] = [
  {
    ago: START,
    mux: "user_message",
    msg: { text: "The fleet uploader gives up on the first 503. Add retry with backoff and cover it with a test." },
  },
  { ago: START, mux: "turn_started" },
  { ago: START - 2_000, update: text("I'll find where artifacts are uploaded first.") },
  {
    ago: START - 4_000,
    update: tool(
      "w-search",
      "search",
      "Search for uploadArtifact",
      output("Sources/Fleet/upload.ts:1\nSources/Fleet/publish.ts:42\nSources/Fleet/upload.test.ts:2"),
    ),
  },
  {
    ago: START - 7_000,
    update: tool("w-read-upload", "read", "Read Sources/Fleet/upload.ts", {
      locations: [{ path: UPLOAD }],
      ...output(uploadBefore),
    }),
  },
  {
    ago: START - 9_000,
    update: tool("w-read-test", "read", "Read Sources/Fleet/upload.test.ts", {
      locations: [{ path: TEST }],
      ...output(testBefore),
    }),
  },
  {
    ago: START - 15_000,
    update: text(
      "The upload is a single `fetch` with no retry, so any 5xx fails the whole publish. I'll add a small helper that retries only server errors, doubling the wait each time:\n\n```ts\nexport async function withRetry<T>(attempt: () => Promise<T>, tries = 5): Promise<T> {\n  for (let index = 0; ; index += 1) {\n    try {\n      return await attempt();\n    } catch (error) {\n      if (!(error instanceof RetryableError) || index + 1 >= tries) throw error;\n      await new Promise((resolve) => setTimeout(resolve, 500 * 2 ** index));\n    }\n  }\n}\n```\n\nClient errors like 403 still fail at once, since retrying them can't help.",
    ),
  },
  {
    ago: START - 40_000,
    update: tool("w-write-retry", "edit", "Write Sources/Fleet/retry.ts", {
      locations: [{ path: RETRY }],
      content: [{ type: "diff", path: RETRY, newText: retrySource }],
    }),
  },
  {
    ago: START - 52_000,
    update: tool("w-edit-upload", "edit", "Edit Sources/Fleet/upload.ts", {
      locations: [{ path: UPLOAD, line: 1 }],
      content: [{ type: "diff", path: UPLOAD, oldText: uploadBefore, newText: uploadAfter }],
    }),
  },
  {
    ago: START - 61_000,
    update: tool("w-edit-test", "edit", "Edit Sources/Fleet/upload.test.ts", {
      locations: [{ path: TEST, line: 8 }],
      content: [{ type: "diff", path: TEST, oldText: testBefore, newText: testAfter }],
    }),
  },
  {
    ago: START - 80_000,
    update: tool("w-test", "execute", "Run bun test Sources/Fleet", {
      rawInput: { command: "bun test Sources/Fleet", cwd: CMUX },
      rawOutput: { exit_code: 0 },
      ...output(
        "bun test v1.4.0\n\nSources/Fleet/upload.test.ts:\n✓ uploads the artifact [3.12ms]\n✓ retries a 503 and then succeeds [1504.40ms]\n\n 2 pass\n 0 fail\nRan 2 tests across 1 file. [1.53s]",
      ),
    }),
  },
  {
    ago: START - 84_000,
    update: text(
      "Uploads now retry server errors with backoff.\n\n- `withRetry` in `retry.ts` tries up to 5 times, waiting 0.5 s, 1 s, 2 s and 4 s.\n- `uploadArtifact` retries only 5xx responses; a 4xx still fails at once.\n- The new test fails the first two uploads with 503 and checks the third succeeds.\n\n```ts\nawait withRetry(async () => {\n  const response = await fetch(url, { method: 'PUT', body });\n  if (response.status >= 500) throw new RetryableError(response.status);\n});\n```\n\nBoth tests pass. The worst case adds 7.5 s before a publish gives up.",
    ),
  },
  // How full the context window is after the turn, as Codex and Claude report it.
  { ago: START - 85_000, update: { sessionUpdate: "usage_update", used: 33_551, size: 200_000 } },
  { ago: START - 86_000, mux: "turn_result", msg: { status: "completed" } },
];

/// The permission request a session needing input waits on.
export const PERMISSION_OPTIONS = [
  { optionId: "allow_once", name: "Allow", kind: "allow_once" },
  { optionId: "allow_always", name: "Always allow", kind: "allow_always" },
  { optionId: "reject_once", name: "Deny", kind: "reject_once" },
];

/// A short exchange for every other session, so any row the reader opens has a transcript. A
/// running session's turn is still open; a session needing input waits on a permission card.
export function sessionHistory(session: MockSession): SeedStep[] {
  const at = session.ago * MIN;
  const steps: SeedStep[] = [
    { ago: at + 90_000, mux: "user_message", msg: { text: session.title } },
    { ago: at + 90_000, mux: "turn_started" },
    { ago: at + 30_000, update: text(session.reply ?? "Done.") },
  ];
  if (session.permission) {
    const toolCallId = `${session.sessionId}-tool`;
    steps.push(
      {
        ago: at + 10_000,
        update: {
          sessionUpdate: "tool_call",
          toolCallId,
          kind: session.permission.kind,
          title: session.permission.title,
          status: "pending",
        },
      },
      {
        ago: at,
        mux: "permission_request",
        msg: {
          permissionId: `${session.sessionId}-permission`,
          request: {
            toolCall: { toolCallId, title: session.permission.title, kind: session.permission.kind },
            options: PERMISSION_OPTIONS,
          },
        },
      },
    );
  } else if (session.status !== "running") steps.push({ ago: at, mux: "turn_result", msg: { status: "completed" } });
  return steps;
}
