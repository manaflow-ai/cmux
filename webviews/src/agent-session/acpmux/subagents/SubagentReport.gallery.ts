// l10n-allow-file: gallery fixtures (prompts, subagent names and reports), not shipped UI.
// A subagent's report to its chat (SubagentReportLine.tsx). Leo, 2026-11-05, on a quiet clock line
// under "Subagent finished: Fix live working line in transcript" that read the report's first words
// ("I've merged the fix, but it covers one cause. ...") with a chevron: "what's up with this \"tool
// call\"?". It is the task notification Claude Code hands the chat when a subagent ends, which starts
// a turn the agent runs on its own; its line said the notification's summary as if it were a tool
// call. Now it reads "Report from <the subagent>" right under that subagent's finished line, and
// opens to the report in the reply's Markdown, then the agent's own reply to it. Compare arms shows
// the looks (reportRow.experiment.ts), "Before" the clock line it was. Synthetic data.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxBackgroundCause, AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "../conversation/backgroundTurns";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { reportRowLook } from "./reportRow.experiment";

const TASK = "Fix live working line in transcript";
/// As Claude's live records name them: the notification's `origin` is the Agent call, acpmux's
/// subagent record is `<session>/<tool call>`.
const CALL_ID = "toolu_gallery_report_fix";
const AGENT_ID = `gallery-session/${CALL_ID}`;
/// acpmux cuts a Claude subagent's `lastMessage` at 240 characters (subagents.rs).
const cut = (text: string) => (text.length > 240 ? `${text.slice(0, 239)}…` : text);

const REPORT = `I've merged the fix, but it covers one cause. The live working line went blank when a turn's first event was a tool call: \`liveLine()\` read the last assistant segment, which a tool call ends.

- \`liveLine()\` now falls back to the running call's title
- a test drives a turn that opens on a tool call and checks the line

The other cause is still open: after a Stop, the line keeps the stopped turn's words until the next event. That one is in \`stopAnswered\`; I left it for a separate PR.`;

const LONG_REPORT = `${REPORT}

## What I checked

${Array.from(
  { length: 8 },
  (_, index) =>
    `${index + 1}. Case ${index + 1}: a turn that ${["opens on a tool call", "opens on a thought", "streams text first", "is stopped mid-call", "is interrupted by Send now", "resumes after a reload", "pages in older history", "runs a background shell"][index]}; the live line reads the right words.`,
).join("\n")}

\`\`\`text
bun test conversation/liveLine.test.ts
 14 pass
 0 fail
\`\`\``;

const SUMMARY =
  "I've merged the fix, but it covers one cause. The live working line went blank when a turn's first event was a tool call";

const agent = (fields: Partial<Subagent> = {}): Subagent => ({
  id: AGENT_ID,
  parent: null,
  name: "general-purpose",
  task: TASK,
  kind: "general-purpose",
  prompt: TASK,
  state: "completed",
  startedAt: minutesAgo(14),
  endedAt: minutesAgo(9),
  lastMessage: cut(REPORT),
  ...fields,
});

/// The subagent's own transcript, whose last reply is its whole report.
const views = (text: string) => ({
  subagentViews: {
    [AGENT_ID]: [user(TASK, 14, { id: "report-child-prompt" }), assistant(text, 9.1, { id: "report-child-reply" })],
  },
});

/// The turn the report started, as acpmux records it: weighed by `cause`, quiet when the agent's
/// reply had nothing new.
const reportTurn = (id: string, minutes: number, cause: Partial<AcpmuxBackgroundCause> = {}, quiet = true) =>
  row(BACKGROUND_TURN, minutes, {
    id: backgroundTurnRowId(id),
    background: {
      id,
      trigger: "task_notification",
      running: false,
      quiet,
      reason: "result",
      hasRows: true,
      cause: { kind: "subagent", status: "completed", weight: "result", origin: CALL_ID, summary: SUMMARY, ...cause },
    },
  });

const reply = (id: string, text: string, minutes: number) =>
  assistant(text, minutes, { id: `${id}-reply`, inBackground: id });

const opening = (fields: Partial<Subagent> = {}): AcpmuxRow[] => [
  user("Have a subagent fix the live working line in the transcript, then tell me what it found", 15, {
    id: "report-prompt",
  }),
  assistant("Started a subagent on it. I'll report when it's done.", 14.5, { id: "report-started" }),
  row(SUBAGENTS, 14.4, { id: "report-group", subagents: [agent(fields)] }),
  summary(14.4, { id: "report-footer", status: "completed", durationMs: 5_000 }),
];

/// Leo's capture: the subagent finished after the turn, its report started a quiet turn.
const reported = (fields: Partial<Subagent> = {}, cause: Partial<AcpmuxBackgroundCause> = {}) => [
  ...opening(fields),
  reportTurn("report-turn", 8.9, cause),
  reply("report-turn", "Noted: one cause fixed, the Stop case left for its own PR.", 8.85),
];

const openReport = async (ctx: PlayContext) => {
  const head = { selector: ".cv-subagent-report__head" };
  await ctx.waitFor(() => ctx.document.querySelector(head.selector));
  await ctx.click(head);
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subagent-report__body") !== null);
};

export default agentPaneEntry({
  id: "agent-pane.subagent-report",
  title: "Subagent report",
  area: "Agent pane",
  height: 520,
  covers: [
    "agent-session/acpmux/subagents/SubagentReportLine.tsx",
    "agent-session/acpmux/subagents/runningTray.ts#withSubagentLines",
  ],
  variants: {
    report: {
      note: 'Leo\'s capture: "Report from Fix live working line in transcript" right under its "Subagent finished" line, no clock, closed.',
      snapshot: chat(reported(), views(REPORT)),
    },
    "report-open": {
      note: "Opened: the report in the reply's Markdown, then the agent's own reply to it.",
      snapshot: chat(reported(), views(REPORT)),
      checks: { layoutShiftMax: { value: 0.5, reason: "Opening the report reveals it below its line." } },
      play: openReport,
    },
    "long-report": {
      note: "A long report opened: it reads whole, as a reply does, with its list and code block.",
      snapshot: chat(reported({ lastMessage: cut(LONG_REPORT) }), views(LONG_REPORT)),
      checks: { layoutShiftMax: { value: 0.8, reason: "Opening the report reveals it below its line." } },
      play: openReport,
    },
    "again-after-resume": {
      note: "The same report delivered again after the chat resumed: each says whose report it is; the first sits under the finished line.",
      snapshot: chat(
        [
          ...reported(),
          user("Resume", 6, { id: "report-resume" }),
          assistant("Picking up where we left off.", 5.9, { id: "report-resumed" }),
          summary(5.9, { id: "report-resume-footer", status: "completed", durationMs: 2_000 }),
          reportTurn("report-turn-again", 5),
          reply("report-turn-again", "Same report as before; nothing new.", 4.95),
        ],
        views(REPORT),
      ),
    },
    failed: {
      note: "A subagent that failed: its finished line says why, and its report line opens to what it said.",
      snapshot: chat(
        reported(
          {
            state: "failed",
            lastMessage: undefined,
            error: "Agent terminated early due to an API error. Retry with a smaller context.",
          },
          { status: "failed", weight: "failure", summary: 'Agent "Fix live working line in transcript" failed' },
        ),
      ),
    },
    stopped: {
      note: "A subagent the person stopped: its finished line says so; the agent's reply to the stop has its report line.",
      snapshot: chat([
        ...opening({
          state: "cancelled",
          stopReason: "user",
          result: undefined,
          lastMessage: "Read liveLine.ts; no change made yet.",
        }),
        reportTurn("report-turn", 8.9, { status: "killed", weight: "silent", summary: undefined }, false),
        reply("report-turn", "Stopped the subagent as asked; nothing was changed.", 8.85),
      ]),
    },
  },
  experiment: { definition: reportRowLook, script: [{ name: "open the report", run: openReport }] },
});
