// l10n-allow-file: gallery fixtures (sample prompts, replies, commands and chat names), not shipped UI.
// One sample of every transcript row type the agent pane's row registry draws (rows/registry.ts
// `defaultRegistry`), keyed by row type: the rows `VirtualTranscript` gets after `turnView`, not
// the raw snapshot. The gallery entry `agent-pane.transcript-row-types` draws each type in the real
// transcript, and test/transcript-row-types.test.tsx pins each type's rendered DOM, so a move of a
// row's code (the split of App.tsx by row type) cannot change what a row draws. Ids are fixed (no
// counter), so the same rows render the same DOM in every run. Pure data: no DOM needed to import.
import type { AcpmuxActivity, AcpmuxRow } from "../../agent-session/acpmux/model";
import type { AgentQuestion } from "../../agent-session/acpmux/question/model";
import type { Subagent } from "../../agent-session/acpmux/subagents/subagentFold";
import { minutesAgo } from "../clock";

export const ROW_TYPES_SESSION = "gallery-row-types";

const base = (id: string, kind: string, minutes: number, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  at: minutesAgo(minutes),
  kind,
  ...fields,
});

const call = (id: string, title: string, kind: string, fields: Partial<NonNullable<AcpmuxActivity["tool"]>> = {}) =>
  ({
    kind: "tool",
    text: title,
    tool: { id, title, kind, status: "completed", ...fields },
  }) satisfies AcpmuxActivity;

const agent = (id: string, name: string, fields: Partial<Subagent> = {}): Subagent => ({
  id: `${ROW_TYPES_SESSION}/${id}`,
  parent: null,
  name,
  task: name,
  kind: "general-purpose",
  state: "completed",
  startedAt: minutesAgo(9),
  endedAt: minutesAgo(7),
  ...fields,
});

const question: AgentQuestion = {
  id: "perm-question",
  source: { harness: "claude", session: ROW_TYPES_SESSION },
  items: [
    {
      id: "pick",
      header: "Retries",
      prompt: "How many times should the fetch helper retry?",
      options: [
        { id: "three", label: "Three times" },
        { id: "five", label: "Five times" },
      ],
      multiSelect: false,
      allowsOther: false,
    },
  ],
  state: { kind: "answered", answer: { selections: { pick: { optionIDs: ["three"] } } } },
};

const permission = {
  permissionId: "perm-run",
  title: "bun test src/net",
  command: "bun test src/net",
  kind: "execute",
  pending: true,
  options: [
    { id: "allow", name: "Allow", allow: true, kind: "allow_once" },
    { id: "deny", name: "Deny", allow: false, kind: "reject_once" },
  ],
};

/// Each row type, by the registry key that draws it, with the rows that show it (in order).
export const ROW_TYPE_ROWS: Record<string, AcpmuxRow[]> = {
  user: [base("row-user", "user", 12, { text: "Add retries with backoff to the fetch helper" })],
  "user-chief": [base("row-user-chief", "user", 12, { text: "Rerun the focused tests", from: "chief" })],
  "user-notice": [
    base("row-user-notice", "user", 12, {
      text: "Task finished",
      incoming: { kind: "notice", text: "Task notification: the build finished" },
      untyped: true,
    }),
  ],
  "user-received": [
    base("row-user-received", "user", 12, {
      received: { offerId: "offer-1", childSessionId: "child-1", title: "Write the retry tests" },
      untyped: true,
    }),
  ],
  "user-queued": [
    base("row-user-queued", "user", 12, {
      text: "Then update the docs",
      status: "Waiting for the switch to Codex",
      queued: "prompt-queued",
      viaCli: "studio-mac",
    }),
  ],
  assistant: [
    base("row-assistant", "assistant", 11, {
      text: "Retries now back off from **200 ms**, doubling up to three tries.\n\n- Timeouts retry\n- A 4xx fails at once",
    }),
  ],
  activity: [
    base("row-activity", "activity", 11, {
      items: [
        call("tool-read", "Read src/net/retry.ts", "read"),
        call("tool-run", "bun test src/net", "execute", { command: "bun test src/net", output: "3 pass", exitCode: 0 }),
      ],
      toolCount: 2,
    }),
  ],
  editedFiles: [
    base("row-edited", "activity", 10, {
      items: [
        call("tool-edit", "Edit src/net/retry.ts", "edit", {
          diffs: [
            { path: "/Users/you/src/atlas-web/src/net/retry.ts", oldText: "tries = 1\n", newText: "tries = 3\n" },
          ],
        }),
      ],
      toolCount: 1,
    }),
  ],
  worked: [base("worked-row-user", "worked", 10, { toolCount: 4, durationMs: 42_000 })],
  date: [base("date-row-user", "date", 60 * 26)],
  thinking: [base("row-thinking", "thinking", 0.5, { untimed: true })],
  working: [base("working-row-user", "working", 1, { doing: "Read src/net/retry.ts" })],
  activityLine: [base("activityLine-row-user", "activityLine", 1, { text: "Editing retry.ts" })],
  preview: [base("preview-row-user", "preview", 9, { text: "http://localhost:5173/" })],
  render: [base("row-render", "render", 9, { items: [call("tool-render", "Render chart", "other")] })],
  turnSummary: [
    base("row-summary", "turnSummary", 9, { status: "completed", toolCount: 2, durationMs: 42_000, folded: true }),
  ],
  notice: [base("row-notice", "notice", 9, { text: "Switched to Codex" })],
  typing: [base("row-typing", "typing", 9, { text: "Codex is typing" })],
  plan: [
    base("row-plan", "plan", 9, {
      plan: [
        { content: "Add retry to the uploader", status: "completed" },
        { content: "Cover it with a test", status: "in_progress" },
        { content: "Update the docs", status: "pending" },
      ],
      turnEnded: true,
    }),
  ],
  "plan-text": [base("row-plan-text", "plan", 9, { text: "No plan yet" })],
  backgroundTask: [
    base("row-bgtask", "backgroundTask", 8, {
      backgroundTask: { toolCallId: "bg-1", command: "npm run dev", state: "completed", exitCode: 0 },
    }),
  ],
  compaction: [
    base("row-compaction", "compaction", 8, {
      compaction: { state: "completed", preTokens: 412_000, postTokens: 18_400 },
    }),
  ],
  failover: [base("row-failover", "failover", 8, { failover: { from: "claude", to: "codex" } })],
  policyUnenforced: [
    base("row-policy", "policyUnenforced", 8, { policyUnenforced: { policy: "approve-reads", why: "ownSettings" } }),
  ],
  agentPair: [
    base("row-agent-pair", "agentPair", 8, {
      agentPair: {
        peer: "0190a000-0000-7000-8000-00000000beef",
        peerName: "Migration reviewer",
        reason: "alternating",
        count: 10,
        held: [{ promptId: "p-1", text: "Can you confirm the migration is safe?" }],
        released: 0,
        dropped: 0,
      },
    }),
  ],
  sessionStart: [
    base("row-session-start", "sessionStart", 8, {
      sessionStart: { agent: "claude", version: "2.1.303", model: "claude-opus-5-5", harness: "claude" },
    }),
  ],
  sessionOffer: [
    base("row-offer", "sessionOffer", 7, {
      offers: [
        {
          offerId: "offer-2",
          title: "Write the retry tests",
          prompt: "Write tests for the retry helper",
          cwd: "/Users/you/src/atlas-web",
          worktree: true,
        },
      ],
    }),
  ],
  offerResult: [
    base("row-offer-result", "offerResult", 7, {
      received: { offerId: "offer-2", childSessionId: "child-2", title: "Write the retry tests" },
    }),
  ],
  startedSessions: [
    base("row-started", "startedSessions", 7, {
      started: [{ sessionId: "child-3", title: "Fix the flaky sidebar test", state: "idle", named: true }],
    }),
  ],
  permission: [base("row-permission", "permission", 6, { permission })],
  "permission-empty": [base("row-permission-empty", "permission", 6)],
  questionRecord: [
    base("row-question-record", "questionRecord", 6, {
      question,
      permission: { ...permission, permissionId: "perm-question", question },
    }),
  ],
  permissionRecord: [
    base("row-permission-record", "permissionRecord", 6, {
      permission: { ...permission, pending: false },
      decision: { kind: "allowed" },
    }),
  ],
  userShell: [
    base("shell-run-1", "userShell", 5, {
      shell: {
        id: "run-1",
        command: "git status --short",
        startedAt: minutesAgo(5),
        endedAt: minutesAgo(5) + 400,
        status: "done",
        exitCode: 0,
        output: " M src/net/retry.ts\n",
        truncated: false,
        version: 1,
      },
    }),
  ],
  subagents: [
    base("row-subagents", "subagents", 4, {
      subagents: [agent("explore", "Explore the fetch helper"), agent("review", "Review the retry tests")],
    }),
  ],
  "subagents-run": [
    base("row-subagents-run", "subagents", 4, {
      subagents: [agent("codex-run", "Codex", { command: "codex exec 'fix the grid'", harness: "codex" })],
    }),
  ],
  subagent: [base("row-subagent", "subagent", 4, { subagents: [agent("explore", "Explore the fetch helper")] })],
  subagentDone: [
    base("row-subagent-done", "subagentDone", 3, { subagents: [agent("review", "Review the retry tests")] }),
  ],
  subagentOf: [
    base("row-subagent-of", "subagentOf", 3, {
      text: "Add retries to the fetch helper",
      subagents: [agent("explore", "Explore the fetch helper", { parent: "gallery-parent" })],
    }),
  ],
  workflowCard: [
    base("row-workflow", "workflowCard", 2, {
      subagents: [
        agent("workflow", "Release checklist", { kind: "workflow", agents: { done: 3, started: 3 }, runId: "wf_1" }),
      ],
    }),
  ],
  unknown: [base("row-unknown", "someFutureKind", 2, { text: "A row kind this pane does not know" })],
};

/// The row types in the order the gallery lists them.
export const ROW_TYPES = Object.keys(ROW_TYPE_ROWS);
