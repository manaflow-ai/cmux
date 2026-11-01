// l10n-allow-file: gallery fixtures (sample commands, session names and messages), not shipped UI.
// Messages this agent sent another one, as one row each (SentMessageLine.tsx): shell `acpmux send`
// calls read from their command lines (acpmuxSends.ts) and a cmux-subsessions `send_message`, which
// draw the same row. The calls have the shapes Claude Code recorded through acpmux on 2026-10-21
// (`_meta.claude.tool: "Bash"`, kind `execute`, the command cut to its title, the description the
// model wrote, `queued` from `--no-wait`), and the failure acpmux prints for a session it does not
// know; names and messages are made up.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, session, summary, tool, user, SESSION_ID } from "../../../gallery/fixtures/acpmux";

/// A Claude Code Bash call as acpmux records it: its title the command's first 120 characters.
const bash = (
  command: string,
  description: string,
  status: string,
  fields: { output?: string; startedAt?: number; endedAt?: number } = {},
) => tool(command.slice(0, 120), "execute", status, { command, description, ...fields });

const REPORT =
  "Merged #4182 (retry banner shows once per outage). The review passed; its one red, the release notary, is red on base too.";

const HEREDOC_BODY = [
  "## net-retries: done",
  "",
  "- **#4182** merged as `9c1e0f2`; the banner shows once per outage.",
  "- Follow-up: the offline toast still fades in. I left it for the toast owner.",
  "",
  "Stop condition met; removing my worktree now.",
].join("\n");

const reported = bash(
  `acpmux send --no-wait coord-deputy '${REPORT}' 2>&1 | tail -1`,
  "Report merge to coord-deputy",
  "completed",
  { output: "queued" },
);
const viaTimeout = bash(
  "timeout 100 acpmux send --no-wait --prompt-id 01a15c51-9277-7e62-8a33-d8d3c74973c9 studio-mac/scroll-jitter 'From composer-scroll: the bottom stack moved into the pane flow. Rebase on it before you touch the dock.'",
  "Tell scroll-jitter about the dock change",
  "completed",
  { output: "steered" },
);
const viaHeredoc = bash(
  `cd ~/wt/net-retries && acpmux send --no-wait --from net-retries coord-deputy - <<'EOF'\n${HEREDOC_BODY}\nEOF`,
  "Send the final report",
  "completed",
  { output: "queued" },
);
const viaReach = bash(
  `reach build-box 'perl -e "alarm 60; exec @ARGV" acpmux send --no-wait review-astra "Re-review #4182 at its new head 9c1e0f2."'`,
  "Ask the reviewer on build-box to look again",
  "completed",
  { output: "queued" },
);
// The same send over plain ssh (ask-1b0c0b04de): the session is on that host, as through reach.
const viaSsh = bash(
  `ssh -o ConnectTimeout=5 build-box 'acpmux send --no-wait docs-lane "The copy pass is yours; #4182 merged."'`,
  "Hand the copy pass to docs-lane on build-box",
  "completed",
  { output: "steered" },
);
const fromFile = bash(
  `acpmux send --no-wait reports:leo "$(cat /tmp/net-retries/summary.md)"`,
  "Send the summary to Leo's reports",
  "completed",
  { output: "queued" },
);
// A prior Bash call records the message file in the same turn. The send row can show the body
// without reading the machine's filesystem; its command remains behind Raw after expansion.
const writeRecorded = bash(
  `cat > /tmp/net-retries/summary.md <<'EOF'\n## Recorded report\n\n- **#4182** merged; checks pass.\n- Follow-up stays with the toast owner.\nEOF`,
  "Write the report for the send",
  "completed",
  { startedAt: 1, endedAt: 1.5 },
);
const recordedFileSend = bash(
  "acpmux send --no-wait reports:leo - < /tmp/net-retries/summary.md",
  "Send the recorded report to Leo",
  "completed",
  { output: "queued", startedAt: 2 },
);
const failed = bash(
  "acpmux send perf-lane 'Profile the transcript scroll on the long fixture.'",
  "Hand the profile to perf-lane",
  "failed",
  {
    output:
      'Exit code 4\nacpmux: no_session: no session matches "perf-lane"; run `acpmux ls` or `acpmux ensure perf-lane`',
  },
);
const running = bash(
  `acpmux send coord-deputy '${REPORT}'`,
  "Report merge to coord-deputy and wait for the reply",
  "in_progress",
);

/// A cmux-subsessions `send_message` (Claude Code's shape): the same row.
const subsessionSend = tool("mcp__cmux-subsessions__send_message", "other", "completed", {
  inputSummary: JSON.stringify({
    sessionId: "sub-tests",
    text: "Also cover the retry backoff.\nReport the failing cases first.",
  }),
  output: "Delivered into its running turn: it reads it at its next tool step.",
});

const CHILD = session({
  sessionId: "sub-tests",
  title: "Own the tests lane",
  name: "claude-sr2/tests",
  shortName: "tests",
  startedBy: SESSION_ID,
  lane: "working",
  indicator: "working",
  status: "running",
});

const sent = () => {
  const snapshot = chat(
    [
      user("Report the merge, tell scroll-jitter, and ask for the re-review.", 4),
      activity([reported, viaTimeout, viaHeredoc, viaReach, viaSsh, fromFile, subsessionSend], 3.8),
      assistant("Reported to coord-deputy, told scroll-jitter, and asked review-astra for a re-review.", 3.5),
      summary(3.5, { status: "completed" }),
    ],
    { title: "net-retries" },
  );
  return { ...snapshot, sessions: [...snapshot.sessions, CHILD] };
};

const recordedFile = () => {
  const snapshot = chat(
    [
      user("Write the report, then send it without showing the shell plumbing.", 2),
      activity([writeRecorded, recordedFileSend], 1.8),
      assistant("The report is queued for reports:leo.", 1.5),
      summary(1.5, { status: "completed" }),
    ],
    { title: "net-retries" },
  );
  return { ...snapshot, sessions: [...snapshot.sessions, CHILD] };
};

/// Opens the finished turn's "Worked for" line, where its calls are.
const openTurn: Play = async (ctx) => {
  await ctx.click({ selector: ".cv-worked.is-toggle" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-sent"));
};

/// Opens the turn, then its first sent row.
const openFirst: Play = async (ctx) => {
  await openTurn(ctx);
  await ctx.click({ selector: ".cv-sent" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subsession__under .cv-md"));
};

export default agentPaneEntry({
  id: "agent-pane.sent-message-rows",
  title: "Sent message rows",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/SentMessageLine.tsx"],
  variants: {
    sent: {
      note: 'Shell sends as "Sent message to <target>" with the message\'s first line: a plain --no-wait (queued), one under timeout to a host/name (steered: read at its next step), a here-document from a cd, one through reach on build-box (its session named host/name), one whose text comes from a file (target only), and a sub-session send_message drawing the same row.',
      snapshot: sent(),
      play: openTurn,
    },
    "with-preview": {
      note: "The here-document send opened: the whole message as Markdown, the call behind Raw.",
      snapshot: sent(),
      play: async (ctx) => {
        await openTurn(ctx);
        // Trusted clicks settle before the next step, so Raw is clicked where it rests.
        await ctx.click({ role: "button", name: /net-retries: done/ });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subsession__under .cv-md h2"));
        await ctx.click({ selector: ".cv-subsession__under .cv-subsession__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subsession__under .cv-shell"));
      },
    },
    "recorded-file": {
      note: "Before: an acpmux send whose stdin comes from a file shows only its target. After the preceding Bash write is part of this turn, the compact row still says Sent message to reports:leo; opening it renders the recorded Markdown and keeps the shell command behind Raw.",
      snapshot: recordedFile(),
      play: async (ctx) => {
        await openTurn(ctx);
        await ctx.click({ selector: ".cv-sent" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-subsession__under .cv-md h2"));
      },
    },
    failed: {
      note: 'A send acpmux refused (exit 4, no such session): "Couldn\'t send to perf-lane", opened to its output.',
      snapshot: chat(
        [
          user("Hand the profile to perf-lane.", 2),
          activity([failed], 1.8),
          assistant("perf-lane is not running; starting it first.", 1.5),
          summary(1.5, { status: "completed" }),
        ],
        { title: "net-retries" },
      ),
      play: async (ctx) => {
        await openFirst(ctx);
      },
    },
    "running-row": {
      note: "A send that waits for the reply, in flight, with the Codex-style runs off: its own row, with the working spinner (with them on, the live line names it: agent-pane.sending-line).",
      theme: { codexToolRuns: false },
      snapshot: chat(
        [user("Report the merge and wait for the deputy's answer.", 1), activity([reported, running], 0.8)],
        { title: "net-retries", isWorking: true },
      ),
    },
    "look-arrow": {
      note: "Gallery version: #24977's arrow line, → coord-deputy: <first line> (theme sentLook arrow).",
      theme: { sentLook: "arrow" },
      snapshot: sent(),
      play: openTurn,
    },
    "look-quote": {
      note: "Gallery version: the first line quoted after the sentence (theme sentLook quote).",
      theme: { sentLook: "quote" },
      snapshot: sent(),
      play: openTurn,
    },
  },
});
