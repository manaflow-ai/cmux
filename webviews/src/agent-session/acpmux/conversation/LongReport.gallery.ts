// l10n-allow-file: gallery fixtures (a made-up project, prompts, progress replies and a report), not shipped UI.
// A lead chat hands a long review to a sub-session, says how it is going while it runs, and the
// review comes back as a long Markdown report, the scenario Leo pointed at on ChatGPT (2026-11-02:
// "see this is the kinda scenario we wanna be able to display super nicely"). The lead chat is
// narrow, as a chat beside its opened task; the report is the sub-session's own chat, wide. Every
// name, number and path is made up (acme/atlas-web).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, session, summary, tool, user, SESSION_ID } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxSessionEntry } from "../sessionList";
import { finishedTaskLook } from "./taskLine.experiment";
import { openEndedStretch } from "./endedStretchPlay";

const REPO = "acme/atlas-web";
const pr = (number: number) => `[#${number}](https://github.com/${REPO}/pull/${number})`;
const REVIEW_ID = "sub-october-review";

/// The cmux server's shape for a sub-session call (cli/mcp/upstream.rs).
const viaCmux = (name: string, args: unknown, result?: unknown, status = "completed") =>
  tool(`mcp__cmux__subsessions_${name}`, "other", status, {
    inputSummary: JSON.stringify(args),
    ...(result !== undefined && { output: JSON.stringify(result) }),
  });

const BRIEF = [
  "Review October's engineering work in `acme/atlas-web`, October 1 through today.",
  "",
  "- Inventory every merged pull request and group them into projects.",
  "- Read the implementation, tests and follow-up fixes, not only the titles.",
  "- Report what the month shows, with links, and say where the evidence is thin.",
].join("\n");

const started = {
  depth: 1,
  harness: "codex",
  mode: "bypassPermissions",
  name: "lead/october-review",
  session: { children: 0, depth: 1, doing: "Inventory merged pull requests", harness: "codex", sessionId: REVIEW_ID },
  sessionId: REVIEW_ID,
  shortName: "october-review",
  turnId: `${REVIEW_ID}-turn`,
  waitsForSlot: false,
};

/// The report the review comes back with: bold lead sentences, pull request links, inline code, a
/// supporting-artifacts line of typed links and a closing note on what it could not read.
export const REPORT = [
  `**The month's work is one release system, not a pile of workflow edits.** ${pr(4123)} added a check that runs after each nightly publishes and rolls back only the build it shipped. It tells a real launch crash apart from a missing download, skips duplicate runs, and refuses to roll back a newer build by accident.`,
  "",
  `Later changes moved the whole release path. By October 28, ${pr(4310)} ran a launch smoke test before publishing and required the tested image's digest to match the one it signs. I checked that dependency in the [current workflow](https://github.com/${REPO}/blob/main/.github/workflows/release.yml). Its claimed 70 to 100 seconds of saving is a projection from earlier runs, not a measured result.`,
  "",
  `${pr(4207)} adds another layer: records scoped to each attempt that say which artifact tree a publisher holds. Missing or stale records read as "unknown" rather than a guessed owner. That is visibility designed around real queueing and retries.`,
  "",
  "**The assessment has real limits.** Most of the changes I read are ancestors of the release branch but not of `main`. That shows they reached the release line, not that they shipped to everyone. GitHub's data can also be newer than the local checkout: #4388 merged after this snapshot.",
  "",
  "The code still carries real maintenance weight: the app's `App.tsx` is 9,820 lines and `release.yml` is 4,410 lines. Size alone is not a defect, but these stay large integration surfaces despite clean boundaries elsewhere. Repeated fixes, regressions and changing release rules are part of the month's record; they should be neither hidden nor counted as separate projects.",
  "",
  "**The strongest supported conclusion is that the month advanced the release pipeline, rendering speed and state handling over sustained runs of work.** That is concrete evidence of the judgment behind it. It does not turn one month into a number of years, and pull request counts alone say little about who did what.",
  "",
  "Supporting artifacts: [investigation manifest](reports/october/manifest.md), [month-wide git log](reports/october/git-discovery.log), [reviewed PR evidence](reports/october/pr-evidence.json) and [follow-up evidence](reports/october/follow-ups.json).",
  "",
  "One GitHub read failed because the CLI could not write `~/.local/state/gh/counts.lock` in this sandbox. It was not retried. Local git reads and the GitHub connector finished the review; nothing blocked the report.",
].join("\n");

const reviewSession = (fields: Partial<AcpmuxSessionEntry>) =>
  session({
    sessionId: REVIEW_ID,
    title: "Review October engineering work",
    name: "lead/october-review",
    shortName: "october-review",
    harness: "codex",
    model: "gpt-6-astra",
    startedBy: SESSION_ID,
    ...fields,
  });

const RUNNING = reviewSession({
  lane: "working",
  indicator: "working",
  status: "running",
  doing: "Read the follow-up fixes for the release check",
});
const DONE = reviewSession({ lane: "idle", indicator: "done", status: "idle" });

const ASK = "There's at least a month of work. Comb through all of it, with Codex if that helps.";
const OPENING =
  "Yes. You asked for a review of the work and I gave you two small samples. I'll cover the whole month: inventory the pull requests, group them into projects, and read the implementation, tests and follow-through. I'll bring back a grounded assessment, not another handful of links.";
const PROGRESS = [
  "I've started a Codex review of the repository history alongside the pull requests. It covers **October 1 through today** and groups related changes into projects rather than counting them. There are thousands of records, so I'll say what was covered instead of pretending a few samples are the whole picture.",
  "The month-wide review is turning up links my samples missed: sandboxing, durable agent state, machine lifecycle, rendering speed and the release pipeline under all of it. It is also tracing follow-up fixes, because a merged title doesn't always mean the problem was solved.",
];

/// `startEnded`: the stretch that started the review ended with its summary while the chat works on,
/// so its start card is in sight: under the live-turn-work `line` a stretch still running
/// draws none of its calls, only its replies and the live line (turns.ts `codexRuns`).
const leadRows = (finished: boolean, startEnded = false) => [
  user("How did October go? Look at what I worked on.", 30),
  assistant(
    "These landed on the release branch, so I'm separating what was built from what shipped. Together they form one product, not a handful of maintenance fixes.",
    29,
  ),
  summary(29),
  user(ASK, 22),
  assistant(OPENING, 21.5),
  activity(
    [
      viaCmux(
        "start_session",
        { name: "october-review", harness: "codex", model: "gpt-6-astra", prompt: BRIEF },
        finished ? { ...started, session: { ...started.session, state: "idle" } } : started,
      ),
    ],
    21,
  ),
  ...(startEnded ? [summary(20.5, { durationMs: 60_000, toolCount: 1 })] : []),
  assistant(PROGRESS[0]!, 20),
  assistant(PROGRESS[1]!, 8),
  ...(finished
    ? [
        activity(
          [
            viaCmux(
              "wait_for_sessions",
              { sessionIds: [REVIEW_ID] },
              {
                sessions: [
                  {
                    sessionId: REVIEW_ID,
                    shortName: "october-review",
                    harness: "codex",
                    state: "idle",
                    lastReply: REPORT,
                  },
                ],
              },
            ),
          ],
          2,
        ),
        assistant("The review is done. Its report is above; the short version is in its first line.", 1.5),
        summary(1.5, { durationMs: 1_210_000, toolCount: 2 }),
      ]
    : []),
];

const lead = (finished: boolean, task = finished ? DONE : RUNNING, startEnded = false) => {
  const snapshot = chat(leadRows(finished, startEnded), {
    title: "How did October go?",
    isWorking: !finished,
  });
  return { ...snapshot, sessions: [...snapshot.sessions, task] };
};

/// The review's own chat: its brief, the reads it ran, and the report as its last reply.
const report = () => {
  const snapshot = chat(
    [
      user(BRIEF, 21),
      activity(
        [
          tool("git log --since=2026-10-01 --merges", "execute", "completed"),
          tool("Read .github/workflows/release.yml", "read", "completed"),
          tool("Search follow-up fixes", "search", "completed"),
        ],
        20,
      ),
      assistant(REPORT, 2),
      summary(2, { durationMs: 1_140_000, toolCount: 3 }),
    ],
    { title: "Review October engineering work", harness: "codex", model: "gpt-6-astra" },
  );
  return snapshot;
};

export default agentPaneEntry({
  id: "agent-pane.long-report",
  title: "Long report from a background review",
  area: "Agent pane",
  height: 900,
  covers: [
    "agent-session/acpmux/conversation/SubsessionCallCard.tsx",
    "agent-session/acpmux/conversation/Markdown.tsx",
    "agent-session/acpmux/conversation/TaskLine.tsx",
  ],
  // Where the finished review stays in sight in the lead chat (variant lead-finished): a line
  // after the fold (shipped), a line after the reply, or the sub-session's card left unfolded.
  experiment: {
    definition: finishedTaskLook,
    script: [{ name: "The finished turn", run: async () => undefined }],
  },
  variants: {
    "lead-running": {
      note: "The lead chat, narrow: it starts a Codex review as a sub-session and posts progress replies while it runs.",
      snapshot: lead(false),
    },
    "lead-running-hover": {
      note: "The pointer on the sub-session's name: only its chip lights, the chat's one opener (Leo, 2026-11-05: \"subagents need to have their clickable bit be highlighted instead of the whole line click\"). The stretch that started it ended, so its card is in sight while the lead works on.",
      snapshot: lead(false, RUNNING, true),
      play: async (ctx) => {
        await openEndedStretch(ctx);
        await ctx.hover({ selector: ".cv-disclosure__open button.cv-agent-tag.is-open" });
      },
    },
    "lead-finished": {
      note: "The lead chat once the review finished: its work folds, and the review stays in sight as one line that opens its report.",
      snapshot: lead(true),
    },
    "lead-finished-working": {
      note: "The lead chat's turn finished while the review still works: its line keeps the harness mark at rest, no spinner, and its title shimmers as a running tool row's words do.",
      snapshot: lead(true, RUNNING),
    },
    report: {
      note: "The review's own chat, wide: the long report with bold lead sentences, PR links, inline code and typed artifact links.",
      snapshot: report(),
    },
    "report-15px": {
      note: "The same report at ChatGPT's body size, 15px on a 1.7 line, through the chat's own text size setting (a question for Leo, not the default).",
      display: { "agentPane.display.font.size": 15, "agentPane.display.font.lineHeight": 1.7 },
      snapshot: report(),
    },
  },
});
