// l10n-allow-file: gallery fixtures (sample prompts, sub-session names and replies), not shipped UI.
// A chat's calls to the cmux-subsessions tools as sub-session cards (SubsessionCallCard.tsx,
// subsessionCalls.ts): a started sub-session with its live state from the session list (working
// with what it does now and its queue, waiting on a question or a permission, failed, done), a
// message sent to one with how it was delivered, a wait's replies, and calls still running. The
// summary card's Subagents list shows the same sub-sessions (summary/SubagentStatusList.tsx).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, session, summary, tool, user, SESSION_ID } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxSessionEntry } from "../sessionList";

/// Claude Code's shape for a call to the server: `mcp__cmux-subsessions__<tool>`, the arguments as
/// its input and the result's text as its output.
const call = (name: string, args: unknown, output?: string, status = "completed") =>
  tool(`mcp__cmux-subsessions__${name}`, "other", status, {
    inputSummary: JSON.stringify(args),
    ...(output !== undefined && { output }),
  });

const started = (shortName: string, id: string) =>
  call(
    "start_session",
    { prompt: `Own the ${shortName} lane`, name: shortName },
    `Started sub-session ${shortName} (sessionId ${id}, depth 1). The user sees it under your chat in the sidebar. It works in parallel; use wait_for_sessions to get its result.`,
  );

const sent = (id: string, text: string, said: string) => call("send_message", { sessionId: id, text }, said);

/// A sub-session of the gallery's chat.
const child = (id: string, shortName: string, fields: Partial<AcpmuxSessionEntry> = {}) =>
  session({
    sessionId: id,
    title: `Own the ${shortName} lane`,
    name: `claude-sr2/${shortName}`,
    shortName,
    startedBy: SESSION_ID,
    lane: "idle",
    indicator: "done",
    ...fields,
  });

const CHILDREN: AcpmuxSessionEntry[] = [
  child("sub-tests", "tests", {
    lane: "working",
    indicator: "working",
    status: "running",
    queued: 2,
    doing: "Check the retry tests · bun test src/net/retry.test.ts",
  }),
  child("sub-docs", "docs", {
    lane: "input",
    indicator: "input",
    status: "waiting",
    waitingOn: { on: "question", prompt: "Which branch should the docs target, main or the release branch?" },
  }),
  child("sub-deps", "deps", { lane: "input", indicator: "input", status: "waiting", waitingOn: { on: "permission" } }),
  child("sub-bench", "bench", { lane: "failed", indicator: "failed" }),
  child("sub-lint", "lint", { unread: true }),
  child("sub-fixture", "fixture", {
    startedBy: "sub-tests",
    lane: "working",
    indicator: "working",
    doing: "Rebuild the net fixtures",
  }),
];

/// The gallery's chat, with its sub-sessions in the session list.
const withChildren = (rows: Parameters<typeof chat>[0], fields: Parameters<typeof chat>[1] = {}) => {
  const snapshot = chat(rows, { title: "Split the net audit into lanes", ...fields });
  return { ...snapshot, sessions: [...snapshot.sessions, ...CHILDREN] };
};

const prompt = "Split the net audit into lanes: tests, docs, deps, bench and lint.";

export default agentPaneEntry({
  id: "agent-pane.subsession-cards",
  title: "Sub-session cards",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/conversation/SubsessionCallCard.tsx"],
  variants: {
    started: {
      note: "Five sub-sessions started, each with its state now: tests working (what it does under it, 2 queued), docs waiting on a question (its prompt after), deps waiting for permission, bench failed, lint done. A name opens that chat beside this one.",
      snapshot: withChildren(
        [
          user(prompt, 6),
          activity(
            [
              started("tests", "sub-tests"),
              started("docs", "sub-docs"),
              started("deps", "sub-deps"),
              started("bench", "sub-bench"),
              started("lint", "sub-lint"),
            ],
            5.8,
          ),
          assistant("Started five sub-sessions; I'll collect their reports.", 5.5),
        ],
        { isWorking: true },
      ),
    },
    messages: {
      note: "Messages to sub-sessions and how each was delivered: read at its next step (a working one), queued at a position, or a turn of its own (an idle one).",
      snapshot: withChildren([
        user("Tell tests to cover the retries, and lint to also check the docs folder.", 3),
        activity(
          [
            sent(
              "sub-tests",
              "Also cover the retry backoff.\nReport the failing cases first.",
              "Delivered into its running turn: it reads it at its next tool step.",
            ),
            sent(
              "sub-tests",
              "Then rerun the whole suite.",
              "Queued behind its running turn (position 2, 2 queued): it reads it when that turn ends. To reach it sooner send with deliver: next_step, or interrupt to stop the turn.",
            ),
            sent("sub-lint", "Lint the docs folder too.", "Sent: it started a turn with it."),
          ],
          2.8,
        ),
        assistant("Sent both.", 2.5),
        summary(2.5, { status: "completed" }),
      ]),
    },
    replies: {
      note: "A wait's result: lint's reply (its first lines), docs still waiting on its question, and tests still running when the wait timed out.",
      snapshot: withChildren([
        user("Wait for the lanes and summarize.", 2),
        activity(
          [
            call(
              "wait_for_sessions",
              {},
              `Still running after 45 s; call wait_for_sessions again to keep waiting.\n${JSON.stringify({
                timedOut: true,
                sessions: [
                  {
                    sessionId: "sub-lint",
                    shortName: "lint",
                    state: "idle",
                    lastReply:
                      "Lint is clean in src/net and docs/.\nTwo warnings remain in the generated client; they come from the codegen template and are left as they are.",
                  },
                  {
                    sessionId: "sub-docs",
                    shortName: "docs",
                    state: "input",
                    waitingOn: "question",
                    doing: "Waiting for the user to answer, in the app: Which branch should the docs target?",
                  },
                  { sessionId: "sub-tests", shortName: "tests", state: "working", doing: "Run bun test" },
                ],
              })}`,
            ),
          ],
          1.8,
        ),
        assistant("Lint is clean; docs needs your answer on its branch; tests are still running.", 1.5),
        summary(1.5, { status: "completed" }),
      ]),
    },
    pending: {
      note: "Calls still running: one compact line each with the working spinner.",
      snapshot: withChildren(
        [
          user(prompt, 1),
          activity(
            [
              call("start_session", { prompt: "Own the perf lane", name: "perf" }, undefined, "in_progress"),
              call("send_message", { sessionId: "sub-tests", text: "Status?" }, undefined, "in_progress"),
              call("wait_for_sessions", { sessionIds: ["sub-tests"] }, undefined, "in_progress"),
            ],
            0.8,
          ),
        ],
        { isWorking: true },
      ),
    },
    summary: {
      note: "The summary card's Subagents list with the chat's sub-sessions: docs and deps waiting on the person first (what for under each), then tests working with 2 queued and its own sub-session fixture indented under it, then bench failed and lint done with its unread dot.",
      snapshot: withChildren([
        user(prompt, 6),
        activity([started("tests", "sub-tests")], 5.8),
        assistant("Started the lanes.", 5.5),
      ]),
      play: async (ctx) => {
        // At a width with no room for the inline column the card is a popover: open it from the header.
        if (!ctx.document.querySelector(".acpmux-summary-card"))
          await ctx.click({ selector: ".acpmux-summary-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-card .acpmux-summary-subsession"));
        const rows = ctx.document.querySelectorAll(".acpmux-summary-card .acpmux-summary-subsession");
        if (rows.length !== CHILDREN.length)
          throw new Error(`summary lists ${rows.length} sub-sessions, expected ${CHILDREN.length}`);
      },
    },
  },
});
