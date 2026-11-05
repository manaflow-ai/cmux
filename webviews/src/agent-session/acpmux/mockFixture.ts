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
  pullRequest?: {
    number: number;
    title: string;
    state: "open" | "draft" | "merged";
    reviewReady?: boolean;
    /// The head commit's CI rollup.
    checks?: "passing" | "failing" | "pending";
  };
  /// The agent's last reply, for sessions other than the worked one.
  reply?: string;
  /// Images the last reply shows under its text (the image viewer's mock chat).
  images?: { alt: string; svg: string }[];
  /// What a session needing input waits on: the tool call its permission card names.
  permission?: { title: string; kind: string };
  /// The call a running session is in the middle of, after its last text.
  working?: { title: string; kind: string; command?: string };
  /// A page the agent rendered before its reply (`cmux mcp`'s render tool), shown as a render card.
  render?: { title: string; html: string };
  /// The chat's whole history, when it is a scene of its own instead of a prompt and its reply.
  history?: (at: number) => SeedStep[];
  /// Config options this chat offers beyond the harness's usual ones (the Options chip's).
  extraOptions?: Record<string, unknown>[];
  /// The agent's suggested next prompt after its last turn. acpmux sends it live only (a page
  /// never holds it, hub/paging.rs NON_TRANSCRIPT_UPDATES), so the mock sends it when the chat opens.
  suggestion?: string;
};

type Update = Record<string, unknown>;
/// One seeded event, `ago` milliseconds before the fixture loads.
/// An update step's `meta` is the `_meta` acpmux writes beside it (its `acpmux.subagents` model).
export type SeedStep = (
  | { update: Update; meta?: Record<string, unknown> }
  | { mux: string; msg?: Record<string, unknown> }
) & { ago: number };

export const LOCAL_HOST = "This Mac";

/// Wide enough that the model picker's layers (provider, family, model) have something to show.
export const claudeModels = [
  { id: "claude-opus-5-5", name: "Opus 5.5" },
  { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
  { id: "claude-haiku-4-5", name: "Haiku 4.5" },
  { id: "claude-fable-1-5", name: "Fable 1.5" },
  { id: "claude-opus-5", name: "Opus 5" },
  { id: "claude-opus-4-6", name: "Opus 4.6" },
  { id: "claude-opus-4-1", name: "Opus 4.1" },
  { id: "claude-sonnet-5", name: "Sonnet 5" },
  { id: "claude-sonnet-4-6", name: "Sonnet 4.6" },
  { id: "claude-haiku-4", name: "Haiku 4" },
  { id: "claude-fable-1", name: "Fable 1" },
];
/// Codex's own series plus the open-weight models it runs through a local provider.
export const codexModels = [
  { id: "gpt-6-astra", name: "GPT-6-Astra" },
  { id: "gpt-6-mini", name: "GPT-6 mini" },
  { id: "gpt-6-nano", name: "GPT-6 nano" },
  { id: "gpt-5.5-codex", name: "GPT-5.5-Codex" },
  { id: "gpt-5.5", name: "GPT-5.5" },
  { id: "gpt-5-mini", name: "GPT-5 mini" },
  { id: "o4-mini", name: "o4-mini" },
  { id: "o3", name: "o3" },
  { id: "gpt-oss-120b", name: "gpt-oss-120b" },
  { id: "gpt-oss-20b", name: "gpt-oss-20b" },
  { id: "qwen3-coder", name: "Qwen3 Coder" },
  { id: "devstral-2", name: "Devstral 2" },
];

const claudeModes = {
  availableModes: [
    { id: "default", name: "Ask before edits" },
    { id: "acceptEdits", name: "Accept edits" },
    { id: "plan", name: "Plan" },
    { id: "bypassPermissions", name: "Bypass permissions" },
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
/// Codex's collaboration option stays available to its command/mode paths; the composer leaves it
/// out of the generic Options chip.
const codexCollaboration = {
  id: "collaboration_mode",
  name: "Collaboration mode",
  category: "collaboration_mode",
  currentValue: "default",
  options: [
    { value: "default", name: "Default" },
    { value: "plan", name: "Plan", description: "Write a plan before editing." },
  ],
};
/// A session's config options: its effort level, and Codex's collaboration mode for /plan.
const sessionOptions = (codex: boolean) => [
  ...effort(codex ? "high" : "medium"),
  ...(codex ? [codexCollaboration] : []),
];
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

/// The mock chat whose last turn left a prompt suggestion (`?mock&session=` this id).
export const PROMPT_SUGGESTION_SESSION = "mock-prompt-suggestion";
export const PROMPT_SUGGESTION = "Add a test for the retry backoff";
/// acpmux's per-chat switch for Claude Code's prompt suggestions, as it offers it.
export const PROMPT_SUGGESTIONS_OPTION = {
  id: "prompt-suggestions",
  name: "Prompt suggestions",
  type: "select",
  category: "model_config",
  currentValue: "on",
  options: [
    { value: "off", name: "Off" },
    {
      value: "on",
      name: "On",
      description: "Suggests your next prompt after a turn; one extra model call per turn, which counts toward usage",
    },
  ],
};
/// The mock chat whose model the harness cannot reach and retries (`turn_retrying`).
export const MODEL_RETRY_SESSION = "mock-model-retry";
export const SUBAGENT_NAMES_SESSION = "mock-subagent-names";
export const SUBAGENT_NAMES_AGENT_ID = "a6ab68f9e2c41d07b";
export const SUBAGENT_NAMES_TASK = "Watch CI for #33005";
/// Four background agents in mixed states (Leo, 2026-11-03, watching Claude Code Desktop run agents in
/// parallel: "yo wtf i want this kind of feature in cmux-next too", then "Tray only, richer").
export const PARALLEL_AGENTS_SESSION = "mock-parallel-agents";

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
      checks: "passing",
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
    pullRequest: { number: 18231, title: "Read the theme after applyTheme", state: "draft", checks: "pending" },
    reply:
      "The sidebar reads the theme before the window applies it, so the first frame uses the old background. I'm moving the read after `applyTheme` and checking every theme.",
    working: { title: "Run bun test Sources/Sidebar", kind: "execute", command: "bun test Sources/Sidebar" },
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
    // A coordinator's tagged ask at the end of its turn (conversation/nextStepAsk.ts): it draws as a
    // card with its answers as buttons (NextStepCard.tsx); a click sends one as the next prompt.
    sessionId: "mock-next-step-ask",
    title: "Find why the lane stalled",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 40,
    host: LOCAL_HOST,
    hostKind: "local",
    reply:
      "The lane wasn't foregrounded by acpmux or cmux NEXT. It ran about 40 slow Bash calls in the foreground itself, and they stalled the turn. Separately, the activity-row timer bug went to the timer helper.\n\n[outward] Add a hook that pushes known-slow commands to the background?\n- Yes, add the hook\n- Not now\n- Fix CI first",
  },
  {
    // The agent's own wrap-up call at the end of its turn (acpmux's `wrap_up` tool,
    // conversation/wrapUp.ts): the next-step box under the answer, the recap muted on top, then the
    // question and its two answers; a click sends one as the next prompt.
    sessionId: "mock-wrap-up",
    title: "Fix product grid layout shift",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 30,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Done. The grid reserves its space now.",
    history: (at) => [
      { ago: at + 90_000, mux: "user_message", msg: { text: "Fix the layout shift on the product grid" } },
      { ago: at + 90_000, mux: "turn_started" },
      { ago: at + 30_000, update: text("Done. The grid reserves its space now.") },
      {
        ago: at + 20_000,
        update: {
          sessionUpdate: "tool_call",
          toolCallId: "mock-wrap-up-call",
          kind: "other",
          title: "mcp__acpmux__wrap_up",
          status: "completed",
          rawInput: {
            recap:
              "Product images now have a width and height, and the grid reserves a 4:5 box while they load, so the product grid no longer shifts. All 14 tests pass.",
            ask: "Should I open a PR for this?",
            actions: ["Yes, open PR", "Not now"],
          },
        },
      },
      { ago: at, mux: "turn_result", msg: { status: "completed" } },
    ],
  },
  {
    // A real chat's wrap-up from a code-mode script: a DEV build's SR2 Claude chat called
    // `cmux.acpmux_wrap_up` from `cmux_exec`, and this is the call_log it recorded (code_mode.rs keeps
    // the box as `shown`). The pane reads the box from it; a click sends an answer as the next prompt.
    sessionId: "mock-wrap-up-code-mode",
    title: "Look in an empty folder",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 25,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "The folder is empty. I asked in the wrap-up box whether to add a README.",
    history: (at) => {
      const shown = {
        recap: "Checked the folder: it is empty.",
        ask: "Should I add a README here?",
        actions: ["Yes, add README", "No thanks"],
      };
      const log = JSON.stringify({ calls: 1, call_log: [{ name: "acpmux_wrap_up", ok: true, shown }] });
      return [
        { ago: at + 60_000, mux: "user_message", msg: { text: "What's in this folder?" } },
        { ago: at + 60_000, mux: "turn_started" },
        {
          ago: at + 30_000,
          update: {
            sessionUpdate: "tool_call",
            toolCallId: "mock-wrap-up-exec",
            kind: "other",
            title: "mcp__cmux__cmux_exec",
            status: "in_progress",
            rawInput: { script: `await cmux.acpmux_wrap_up(${JSON.stringify(shown)})` },
          },
        },
        {
          ago: at + 29_000,
          update: {
            sessionUpdate: "tool_call_update",
            toolCallId: "mock-wrap-up-exec",
            status: "completed",
            content: [{ type: "content", content: { type: "text", text: log } }],
          },
        },
        { ago: at + 20_000, update: text("The folder is empty. I asked in the wrap-up box whether to add a README.") },
        { ago: at, mux: "turn_result", msg: { status: "completed" } },
      ];
    },
  },
  {
    // The person came back to a Claude chat after 5+ minutes away (Leo, 2026-11-03: "lkewise with
    // teh cli summarization thing? how do those get turned on? maybe we can expose it in cmux-next
    // too"): acpmux's `recap` record, drawn as the recap row under the last turn.
    sessionId: "mock-session-recap",
    title: "Make the parser tolerate missing fields",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 9200,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "The parser now skips absent optional fields.",
    history: (at) => [
      { ago: at + 900_000, mux: "user_message", msg: { text: "Make the parser in foo.rs tolerate missing fields." } },
      { ago: at + 900_000, mux: "turn_started" },
      {
        ago: at + 860_000,
        update: text("The parser now skips absent optional fields; required ones still fail with their name."),
      },
      { ago: at + 860_000, mux: "turn_result", msg: { status: "completed" } },
      {
        ago: at,
        mux: "recap",
        msg: {
          text: "Goal: make the parser in foo.rs tolerate missing fields; optional ones are done. Next: decide how required fields should fail.",
          awayMs: 840_000,
        },
      },
    ],
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
    render: { title: "Keystroke to paint, median ms", html: latencyChart() },
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
    sessionId: "mock-agent-composer",
    title: "Port the composer",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 320,
    host: LOCAL_HOST,
    hostKind: "local",
    pullRequest: { number: 16601, title: "cmux-next agent pane: composer and picker menus", state: "merged" },
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
    reply: "Nested lists now sit 4 px under their item.",
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
    pullRequest: { number: 219, title: "Stream tool output in 8 KiB chunks", state: "open", checks: "failing" },
    reply: "Splitting tool output into 8 KiB chunks so long shell runs stream instead of arriving at the end.",
    working: { title: "Edit src/tools/stream.rs", kind: "edit" },
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
    pullRequest: {
      number: 212,
      title: "Resume sessions after a daemon restart",
      state: "open",
      reviewReady: true,
      checks: "passing",
    },
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
    title: "Polish the home screen",
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
    title: "Make sample images for the docs",
    harness: "claude",
    model: "claude-sonnet-5-5",
    status: "idle",
    cwd: "~/code/atlas-web",
    ago: 2900,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Made three sample images for the docs: a chart, a gradient and a diagram.",
    images: [
      { alt: "Weekly builds", svg: sampleChart() },
      { alt: "Dusk gradient", svg: sampleGradient() },
      { alt: "Request flow", svg: sampleDiagram() },
    ],
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
  {
    // A background shell from an earlier page ends while a reply streams (Leo, 2026-11-03: "this
    // chat's text stream got cut in the middle by a tool call which is weird"): its note goes after
    // the reply, never between "once per machine," and "not once per chat."
    sessionId: "mock-notice-mid-reply",
    title: "How often do Cloud machines ask for a login",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 9000,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Once per machine, not once per chat.",
    history: (at) => [
      { ago: at + 90_000, mux: "user_message", msg: { text: "How often do Cloud machines ask for a login?" } },
      { ago: at + 90_000, mux: "turn_started" },
      {
        ago: at + 40_000,
        update: text(
          "- Codex works the same way through its device sign-in.\n- The login stays on that machine's own disk, so it's once per machine,",
        ),
      },
      {
        ago: at + 30_000,
        update: {
          sessionUpdate: "background_task_update",
          taskId: "task-ci-wait",
          toolCallId: "mock-notice-mid-reply-earlier-call",
          command: "Wait for remote CI run",
          state: "completed",
        },
      },
      { ago: at + 20_000, update: text(" not once per chat. With one machine per workspace, that's rare.") },
      { ago: at, mux: "turn_result", msg: { status: "completed" } },
    ],
  },
  {
    // A background subagent whose Agent call is on a page not loaded (Leo, 2026-11-03: "why is the
    // spacing like this it's weird", his capture reading "Subagent finished: Subagent" and "Sent to
    // a6ab68f9"). acpmux repeats its name and task on its progress and end, and its progress says
    // its agentId (cmux-tui/crates/acpmux), so its end line names its description and a SendMessage to its agentId reads
    // "Sent to <description>".
    sessionId: SUBAGENT_NAMES_SESSION,
    title: "Watch CI for the subagent names fix",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 9200,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "CI is green.",
    history: (at) => {
      const id = `${SUBAGENT_NAMES_SESSION}/toolu_ci_watch`;
      const named = { name: "ci-watcher", task: SUBAGENT_NAMES_TASK };
      const send = "mock-subagent-names-send";
      return [
        { ago: at + 4_400_000, mux: "user_message", msg: { text: "Keep watching CI and tell me when it is green." } },
        { ago: at + 4_400_000, mux: "turn_started" },
        {
          ago: at + 4_350_000,
          update: { sessionUpdate: "subagent_progress", subagentSessionId: id },
          meta: {
            acpmux: {
              subagents: [
                {
                  id,
                  parent: null,
                  state: "running",
                  background: true,
                  action: "Reading the run log",
                  agentId: SUBAGENT_NAMES_AGENT_ID,
                  ...named,
                },
              ],
            },
          },
        },
        {
          ago: at + 4_300_000,
          update: {
            sessionUpdate: "tool_call",
            toolCallId: send,
            title: "SendMessage",
            kind: "other",
            status: "pending",
            rawInput: {
              to: SUBAGENT_NAMES_AGENT_ID,
              message: "Don't end turns to wait: keep watching until the run is green, then report.",
            },
          },
        },
        {
          ago: at + 4_299_000,
          update: {
            sessionUpdate: "tool_call_update",
            toolCallId: send,
            status: "completed",
            content: [{ type: "content", content: { type: "text", text: '{"success":true}' } }],
          },
        },
        {
          ago: at + 10_000,
          update: { sessionUpdate: "subagent_state_update", subagentSessionId: id, state: "completed" },
          meta: { acpmux: { subagents: [{ id, parent: null, state: "completed", ...named }] } },
        },
        { ago: at + 5_000, update: text("CI is green.") },
        { ago: at, mux: "turn_result", msg: { status: "completed" } },
      ];
    },
  },
  {
    // Four background agents at once, each in its own state (PARALLEL_AGENTS_SESSION): the tray lists
    // the running one with its latest step, the one that stopped to wait on background work of its
    // own, and under them the transcript keeps a quiet line for each that ended, the finished one's
    // opening to its final report and the failed one's with Retry.
    sessionId: PARALLEL_AGENTS_SESSION,
    title: "Audit the nightly pipeline in parallel",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 9300,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Two agents are still on it; the publish step's report is in.",
    history: (at) => {
      const id = (name: string) => `${PARALLEL_AGENTS_SESSION}/toolu_${name}`;
      const agent = (name: string, task: string, fields: Record<string, unknown>) => ({
        id: id(name),
        parent: null,
        name,
        task,
        background: true,
        ...fields,
      });
      const progress = (ago: number, change: Record<string, unknown>) => ({
        ago,
        update: { sessionUpdate: "subagent_progress", subagentSessionId: change.id },
        meta: { acpmux: { subagents: [change] } },
      });
      const spawned = (ago: number, change: Record<string, unknown>) => ({
        ago,
        update: { sessionUpdate: "subagent_spawned", subagentSessionId: change.id },
        meta: { acpmux: { subagents: [change] } },
      });
      const ended = (ago: number, change: Record<string, unknown>) => ({
        ago,
        update: { sessionUpdate: "subagent_state_update", subagentSessionId: change.id, state: change.state },
        meta: { acpmux: { subagents: [change] } },
      });
      const cache = agent("cache", "Measure the build cache", { state: "running", action: "Read warm-sources.json" });
      const signing = agent("signing", "Time the signing step", {
        state: "running",
        action: "Waiting on the notarization run",
        lastMessage: "Started the notarization run; I'll report when it settles.",
      });
      const publish = agent("publish", "Check the publish step", {
        state: "completed",
        lastMessage: [
          "## Publish step",
          "The publish step spends 4m 10s re-uploading the DMG it already uploaded.",
          "",
          "- The upload step runs twice: once in `build-nightly-app`, once in `publish`.",
          "- Dropping the second upload saves about 4 minutes per nightly.",
          "",
          "**Fix:** reuse the first upload's artifact in `publish`.",
        ].join("\n"),
      });
      const compile = agent("compile", "Profile the Release compile", {
        state: "failed",
        error: "Agent terminated early due to an API error. The request timed out after 600s.",
      });
      return [
        {
          ago: at + 600_000,
          mux: "user_message",
          msg: { text: "Audit the nightly pipeline end to end, in parallel." },
        },
        { ago: at + 600_000, mux: "turn_started" },
        {
          ago: at + 590_000,
          update: text("I'll run four agents at once: the cache, signing, publish and the compile."),
        },
        spawned(at + 580_000, { ...cache, action: "Read the cache keys" }),
        spawned(at + 579_000, { ...signing, state: "running", action: "Read the signing job", lastMessage: undefined }),
        spawned(at + 578_000, { ...publish, state: "running", action: "Read publish.yml", lastMessage: undefined }),
        spawned(at + 577_000, { ...compile, state: "running", action: "Read the compile timings", error: undefined }),
        { ago: at + 570_000, mux: "turn_result", msg: { status: "completed" } },
        ended(at + 300_000, compile),
        ended(at + 200_000, publish),
        progress(at + 120_000, cache),
        // The signing agent stopped while its own background run goes on: Claude Code's notification
        // says so, and acpmux weighs that end interim (hub/background_cause.rs).
        ended(at + 90_000, { ...signing, state: "completed" }),
        {
          ago: at + 89_000,
          mux: "background_turn",
          msg: {
            id: "mock-parallel-interim",
            state: "started",
            trigger: "task",
            cause: {
              kind: "subagent",
              status: "interim",
              weight: "silent",
              origin: id("signing"),
              summary: "The agent is waiting on its own background work.",
            },
          },
        },
        { ago: at + 88_000, mux: "background_turn", msg: { id: "mock-parallel-interim", state: "ended", quiet: true } },
      ];
    },
  },
  {
    // A Stop the agent never answered, with another agent's message steered in a second after it
    // (Leo, 2026-11-03: "this is an "interesting" recovery flow... idk if it should be showing things
    // like that"): acpmux forced the turn's end 10 s later and ran the message as the next turn's
    // prompt, same promptId. The stopped turn reads "Stopped", the message comes after it.
    sessionId: "mock-forced-stop",
    title: "Migrate the parser to the new token stream",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 9400,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Still on the parser: the lexer is done, the lookahead is next.",
    history: (at) => [
      {
        ago: at + 120_000,
        mux: "user_message",
        msg: { text: "Migrate the parser to the new token stream", promptId: "mock-fs-1", turnId: "mock-fs-turn-1" },
      },
      { ago: at + 120_000, mux: "turn_started", msg: { turnId: "mock-fs-turn-1", promptId: "mock-fs-1" } },
      { ago: at + 80_000, update: text("The lexer already emits the new tokens. I'm moving the lookahead over next.") },
      { ago: at + 60_000, mux: "stopping", msg: { turnId: "mock-fs-turn-1" } },
      {
        ago: at + 59_000,
        mux: "user_message",
        msg: {
          text: "Status check: are you still on the parser migration?",
          promptId: "mock-fs-late",
          turnId: "mock-fs-turn-1",
          steer: true,
          _meta: { provenance: { kind: "session_message", from: "mock-session", fromShortName: "coordinator" } },
        },
      },
      { ago: at + 50_000, mux: "turn_end", msg: { stopReason: "cancelled", turnId: "mock-fs-turn-1" } },
      {
        ago: at + 50_000,
        mux: "turn_result",
        msg: { status: "cancelled", stopReason: "cancelled", turnId: "mock-fs-turn-1", cancelForced: true },
      },
      {
        ago: at + 40_000,
        mux: "user_message",
        msg: {
          text: "Status check: are you still on the parser migration?",
          promptId: "mock-fs-late",
          turnId: "mock-fs-turn-2",
          _meta: { provenance: { kind: "session_message", from: "mock-session", fromShortName: "coordinator" } },
        },
      },
      { ago: at + 40_000, mux: "turn_started", msg: { turnId: "mock-fs-turn-2", promptId: "mock-fs-late" } },
      { ago: at + 10_000, update: text("Still on the parser: the lexer is done, the lookahead is next.") },
      { ago: at, mux: "turn_result", msg: { status: "completed", turnId: "mock-fs-turn-2" } },
    ],
  },
  {
    sessionId: "mock-session-links",
    title: "Which lanes own Session Info",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 9500,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Three lanes work on Session Info.",
    history: (at) => [
      { ago: at + 60_000, mux: "user_message", msg: { text: "Which sessions own Session Info?" } },
      { ago: at + 60_000, mux: "turn_started" },
      {
        ago: at + 10_000,
        update: text(
          [
            "Three lanes work on Session Info:",
            "",
            `- \`${SESSION_LINK_REFS.swarm}\``,
            `- \`${SESSION_LINK_REFS.lane}\``,
            `- \`${SESSION_LINK_REFS.name}\``,
            "",
            `Earlier work was in \`${SESSION_LINK_REFS.notYours}\` and \`${SESSION_LINK_REFS.unknown}\`;` +
              ` the panel lives under \`${SESSION_LINK_REFS.path}\`, about 3/4 done.`,
          ].join("\n"),
        ),
      },
      { ago: at + 5_000, mux: "turn_result", msg: { status: "completed" } },
      // Two lanes' messages sent from a shell (`from: "cli"`), which name their sender only (Leo,
      // 2026-11-05: "i can't click to go to these for some reason"): the daemon resolves the first
      // (its chip opens that chat) and has no chat for the second (its click says so).
      ...[SESSION_LINK_REFS.name, "fleet-mesh-3"].map((fromName, index) => ({
        ago: at + 2_000 - index * 1_000,
        mux: "user_message",
        msg: {
          text: index === 0 ? "the hq#7125 lane is up; Session Info panel next" : "mesh relay reconnected",
          promptId: `mock-links-msg-${index}`,
          _meta: { provenance: { kind: "agent_message", from: "cli", fromName, msgId: `mock-links-m-${index}` } },
        },
      })),
    ],
  },
  {
    // Claude Code's prompt suggestions (Leo, 2026-11-03: "i know there's suggested prompts that you
    // can right arrow/tab to do stuff with... maybe we can expose it in cmux-next too"): after the
    // second turn acpmux sends the agent's guess at the next prompt (live, `suggestion`), which the empty composer shows
    // as ghost text (Tab or Right-arrow takes it). acpmux also offers the chat's "Prompt
    // suggestions" switch (claude_stdio/prompt_suggestions.rs), which the composer leaves out.
    sessionId: PROMPT_SUGGESTION_SESSION,
    title: "Retry flaky uploads",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "idle",
    cwd: CMUX,
    ago: 9600,
    host: LOCAL_HOST,
    hostKind: "local",
    reply: "Done: the uploader retries 5xx with backoff.",
    extraOptions: [PROMPT_SUGGESTIONS_OPTION],
    suggestion: PROMPT_SUGGESTION,
    history: (at) => [
      { ago: at + 120_000, mux: "user_message", msg: { text: "Why do uploads fail on the fleet?" } },
      { ago: at + 120_000, mux: "turn_started" },
      { ago: at + 100_000, update: text("The uploader gives up on the first 503 from the artifact store.") },
      { ago: at + 90_000, mux: "turn_result", msg: { status: "completed" } },
      { ago: at + 60_000, mux: "user_message", msg: { text: "Retry 5xx with backoff" } },
      { ago: at + 60_000, mux: "turn_started" },
      { ago: at + 10_000, update: text("Done: the uploader retries 5xx with backoff.") },
      { ago: at, mux: "turn_result", msg: { status: "completed" } },
    ],
  },
  {
    // A chat whose model gateway is down (Leo, 2026-11-03, on "Thinking 7m 49s": "i feel like this
    // mac session just keeps "thinking""): Claude Code retries the request every 75 s, and acpmux
    // logs each retry as `turn_retrying` (hub/turn_retry.rs). The live line says the model cannot
    // be reached, with the retry's count and error, never "Thinking" (`?mock&session=` this id).
    sessionId: MODEL_RETRY_SESSION,
    title: "Fix the flaky upload test",
    harness: "claude",
    model: "claude-opus-5-5",
    status: "running",
    cwd: CMUX,
    ago: 9300,
    host: LOCAL_HOST,
    hostKind: "local",
    history: (at) => [
      { ago: at + 470_000, mux: "user_message", msg: { text: "Fix the flaky upload test" } },
      { ago: at + 470_000, mux: "turn_started", msg: { turnId: "mock-retry-turn" } },
      ...[1, 2, 3, 4, 5, 6, 7].map((attempt) => ({
        ago: at + 470_000 - attempt * 66_000,
        mux: "turn_retrying",
        msg: {
          turnId: "mock-retry-turn",
          attempt,
          maxRetries: 10,
          errorStatus: 503,
          error: "server_error",
          retryDelayMs: 75_000,
          source: "claude",
        },
      })),
    ],
  },
];

/// The mock chat whose reply lists other agents' sessions as an agent writes them, in inline code
/// (Leo, 2026-11-03: "these links aren't clickable"): two agent links that name only host and
/// session, a `HOST/NAME`, a link with a harness to a session that is not the reader's, a
/// `HOST/NAME` no daemon knows, and code that only looks like one.
export const SESSION_LINKS_SESSION = "mock-session-links";
export const SESSION_LINK_REFS = {
  swarm: "https://cmux.com/deeplink/agent?host=gcp-agent-lane-7&session=01a19ee7-0000-7de2-862f-0b255ab41dd0",
  lane: "https://cmux.com/deeplink/agent?host=gcp-agent-lane-2&session=01a18a4b-0000-7950-b4c1-d1053077a7b7",
  name: "gcp-agent-lane-1/opus-session-info",
  notYours:
    "https://cmux.com/deeplink/agent?harness=claude&session=0cfd5322-0000-4e01-b71c-aaf0edfb4de8&host=elsewhere",
  unknown: "gcp-agent-lane-9/nobody-here",
  path: "src/app",
};
/// What the mock `_acpmux/resolve` answers: each query that names a session this daemon lists,
/// and that session (a fixture chat, so a click opens something). Any other query is not found.
export const mockResolvable: Record<string, { sessionId: string; name: string; host: string }> = {
  "01a19ee7-0000-7de2-862f-0b255ab41dd0": { sessionId: "mock-zsh", name: "codex-swarm-07", host: "gcp-agent-lane-7" },
  "01a18a4b-0000-7950-b4c1-d1053077a7b7": {
    sessionId: "mock-ghostty-config",
    name: "lane-2",
    host: "gcp-agent-lane-2",
  },
  "gcp-agent-lane-1/opus-session-info": {
    sessionId: "mock-notice-mid-reply",
    name: "opus-session-info",
    host: "gcp-agent-lane-1",
  },
};

/// A session as `_acpmux/watch` and `_acpmux/attach` report it.
export function sessionSummary(session: MockSession, now: number, turnCount: number): Record<string, unknown> {
  const {
    ago,
    reply,
    permission: _permission,
    history: _history,
    extraOptions,
    suggestion: _suggestion,
    ...fields
  } = session;
  const preview = session.sessionId === WORKED_SESSION ? "Uploads now retry server errors with backoff." : reply;
  return {
    ...fields,
    preview,
    name: session.harness,
    // acpmux runs the fixture's `claude` as Claude Code: Ctrl-B and subagent Stop.
    backgroundsWork: session.harness === "claude",
    updatedAt: now - ago * 60_000,
    turnCount,
    indicator: fixtureIndicator(session),
    modes: session.harness === "codex" ? codexModes : claudeModes,
    configOptions: [...sessionOptions(session.harness === "codex"), ...(extraOptions ?? [])],
  };
}

/// The status dot acpmux would name for a fixture session: a disconnected one left mid-answer.
function fixtureIndicator(session: MockSession): string {
  if (session.status === "waiting" || (session.pendingPermissions ?? 0) > 0) return "input";
  if (session.status === "running") return "working";
  return session.status === "disconnected" ? "lost" : "done";
}

/// A new chat in `cwd` on `harness` (Claude Code unless asked): no turns yet.
export function newSessionSummary(
  sessionId: string,
  cwd: string,
  now: number,
  harness: MockSession["harness"] = "claude",
): Record<string, unknown> {
  const codex = harness === "codex";
  return {
    sessionId,
    title: "New chat",
    name: harness,
    harness,
    // acpmux names the harness family, which decides what the chat forks (Edit, versions).
    family: harness,
    backgroundsWork: !codex,
    model: (codex ? codexModels : claudeModels)[0]!.id,
    status: "idle",
    cwd,
    host: LOCAL_HOST,
    hostKind: "local",
    branch: "main",
    updatedAt: now,
    turnCount: 0,
    modes: codex ? codexModes : claudeModes,
    configOptions: sessionOptions(codex),
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
/// block, edits to three files, a test run and the pull request it opened (so the pane's pull
/// request dock shows in mock mode and captures), ending a few minutes ago.
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
    ago: START - 82_000,
    update: tool("w-pr", "execute", 'Run gh pr create --title "fleet: retry artifact uploads with backoff" --fill', {
      rawInput: { command: 'gh pr create --title "fleet: retry artifact uploads with backoff" --fill', cwd: CMUX },
      rawOutput: { exit_code: 0 },
      ...output("https://github.com/manaflow-ai/cmux/pull/18204\n"),
    }),
  },
  {
    ago: START - 84_000,
    update: text(
      "Uploads now retry server errors with backoff.\n\n- `withRetry` in `retry.ts` tries up to 5 times, waiting 0.5 s, 1 s, 2 s and 4 s.\n- `uploadArtifact` retries only 5xx responses; a 4xx still fails at once.\n- The new test fails the first two uploads with 503 and checks the third succeeds.\n\n```ts\nawait withRetry(async () => {\n  const response = await fetch(url, { method: 'PUT', body });\n  if (response.status >= 500) throw new RetryableError(response.status);\n});\n```\n\nBoth tests pass. The worst case adds 7.5 s before a publish gives up.",
    ),
  },
  // How full the context window is after the turn, as the agent reports it.
  { ago: START - 85_000, update: { sessionUpdate: "usage_update", used: 33_551, size: 200_000 } },
  { ago: START - 86_000, mux: "turn_result", msg: { status: "completed" } },
];

/// The permission request a session needing input waits on.
export const PERMISSION_OPTIONS = [
  { optionId: "allow_once", name: "Allow", kind: "allow_once" },
  { optionId: "allow_always", name: "Always allow", kind: "allow_always" },
  { optionId: "reject_once", name: "Deny", kind: "reject_once" },
];

/// A bar chart of median keystroke-to-paint per layout, as an agent would render it: plain SVG
/// in the pane's theme variables, no library.
function latencyChart(): string {
  const bars: [string, number, number][] = [
    ["1 pane", 7.8, 7.7],
    ["2 splits", 7.9, 7.9],
    ["4 splits", 8.1, 8.2],
    ["8 splits", 8.6, 8.9],
  ];
  const scale = (ms: number) => Math.round(ms * 16);
  const rows = bars
    .map(([label, branch, main], index) => {
      const y = 14 + index * 34;
      return (
        `<text x="0" y="${y + 13}" class="l">${label}</text>` +
        `<rect x="76" y="${y}" width="${scale(branch)}" height="11" rx="2" class="b"/>` +
        `<rect x="76" y="${y + 13}" width="${scale(main)}" height="7" rx="2" class="m"/>` +
        `<text x="${82 + scale(branch)}" y="${y + 10}" class="v">${branch.toFixed(1)}</text>`
      );
    })
    .join("");
  return (
    "<style>body{padding:14px 16px}svg{display:block;width:420px;max-width:100%;height:auto;font:12px var(--cmux-font)}" +
    ".l{fill:var(--cmux-muted)}.v{fill:var(--cmux-text)}.b{fill:#3b82f6}.m{fill:var(--cmux-border)}" +
    "p{margin:10px 0 0;color:var(--cmux-muted);font-size:12px}i{display:inline-block;width:9px;height:9px;border-radius:2px;margin:0 5px 0 12px}</style>" +
    `<svg viewBox="0 0 420 148" role="img" aria-label="Median keystroke-to-paint by layout">${rows}</svg>` +
    '<p><i style="background:#3b82f6;margin-left:0"></i>This branch<i style="background:var(--cmux-border)"></i>main</p>'
  );
}

/// A session's reply with its images after the text, as data URLs a reply can draw.
function replyWithImages(session: MockSession): string {
  const images = (session.images ?? []).map(({ alt, svg }) => `![${alt}](data:image/svg+xml;base64,${btoa(svg)})`);
  return [session.reply ?? "Done.", ...images].join("\n\n");
}

/// Neutral sample images (no app UI): a bar chart, a photo-like gradient and a box diagram.
export function sampleChart(): string {
  const bars = [42, 58, 51, 73, 66, 88, 79]
    .map(
      (value, index) =>
        `<rect x="${60 + index * 76}" y="${340 - value * 3}" width="48" height="${value * 3}" rx="4" fill="#3b82f6"/>`,
    )
    .join("");
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">` +
    `<rect width="640" height="400" fill="#f8fafc"/>` +
    `<path d="M48 340h560M48 240h560M48 140h560" stroke="#cbd5e1" stroke-width="1"/>` +
    bars +
    `</svg>`
  );
}

export function sampleGradient(): string {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">` +
    `<defs><linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">` +
    `<stop offset="0" stop-color="#1e3a8a"/><stop offset="0.55" stop-color="#c2410c"/><stop offset="1" stop-color="#fbbf24"/>` +
    `</linearGradient></defs>` +
    `<rect width="640" height="400" fill="url(#sky)"/>` +
    `<circle cx="420" cy="300" r="46" fill="#fde68a" opacity="0.9"/>` +
    `<path d="M0 330 Q160 280 320 320 T640 300 V400 H0Z" fill="#1f2937"/>` +
    `</svg>`
  );
}

export function sampleDiagram(): string {
  const box = (x: number, label: string) =>
    `<rect x="${x}" y="160" width="140" height="72" rx="10" fill="#ffffff" stroke="#64748b" stroke-width="2"/>` +
    `<text x="${x + 70}" y="202" text-anchor="middle" font-family="system-ui, sans-serif" font-size="18" fill="#0f172a">${label}</text>`;
  const arrow = (x: number) =>
    `<path d="M${x} 196h44" stroke="#64748b" stroke-width="2"/><path d="M${x + 44} 196l-10-6v12z" fill="#64748b"/>`;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">` +
    `<rect width="640" height="400" fill="#f1f5f9"/>` +
    box(28, "Client") +
    arrow(176) +
    box(250, "Queue") +
    arrow(398) +
    box(472, "Worker") +
    `</svg>`
  );
}

/// A short exchange for every other session, so any row the reader opens has a transcript. A
/// running session's turn is still open; a session needing input waits on a permission card.
export function sessionHistory(session: MockSession): SeedStep[] {
  const at = session.ago * MIN;
  if (session.history) return session.history(at);
  const steps: SeedStep[] = [
    { ago: at + 90_000, mux: "user_message", msg: { text: session.title } },
    { ago: at + 90_000, mux: "turn_started" },
  ];
  if (session.render)
    steps.push({
      ago: at + 40_000,
      update: {
        sessionUpdate: "tool_call",
        toolCallId: `${session.sessionId}-render`,
        kind: "other",
        title: "mcp__cmux__render",
        status: "completed",
        rawInput: session.render,
      },
    });
  steps.push({ ago: at + 30_000, update: text(replyWithImages(session)) });
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
  } else if (session.status === "running" && session.working)
    // A running agent is usually in the middle of a call, which its pane shows under "Working for".
    steps.push({
      ago: at + 10_000,
      update: {
        sessionUpdate: "tool_call",
        toolCallId: `${session.sessionId}-working`,
        kind: session.working.kind,
        title: session.working.title,
        status: "in_progress",
        ...(session.working.command ? { rawInput: { command: session.working.command } } : {}),
      },
    });
  else if (session.status !== "running") steps.push({ ago: at, mux: "turn_result", msg: { status: "completed" } });
  return steps;
}
