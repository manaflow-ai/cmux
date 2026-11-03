// l10n-allow-file: gallery fixtures (sample notices, PR numbers and paths), not shipped UI.
// Automated notices an older sender puts in a prompt as plain text (agentNotice.ts
// AUTOMATED_NOTICE_HEADS): the stall reconciler's conflict notice and spend guard, a Stop hook's
// feedback. Leo, 2026-11-03, asked whether `[stall-reconciler] #31356 conflicts with main …`, drawn as
// his own bubble, could show "as a quiet, collapsed row, like the background-task replies": "yeah
// let's"; and on hiding such things, "well there are cases (rare) that you would want to see it".
// Each draws as a notice's one line (IncomingMessageCard.tsx): the quiet info mark in the tool rows'
// icon column, the sender, the first sentence, a chevron that opens the rest. The agent's reply under
// it draws as before. `before` is the same chat as the pane drew it. Numbers and paths are made up.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import { noticeRowText } from "./agentNotice";
import { incomingPrompt } from "./incomingMessage";

const CONFLICT =
  "[stall-reconciler] #31356 conflicts with main at 42ed8159e6c1: .github/workflows/cloud-capture-provision.yml, webviews/src/agent-session/acpmux/direct.ts. Rebase or merge base; this notice won't repeat for head 3dc49e20c151.";
const PLATFORM =
  "[stall-reconciler] cmux-platform#270 conflicts with main at 9b1f04c2d7aa: api/openapi.json. Rebase or merge base; this notice won't repeat for head 51c0e7a9b2f4.";
const SPEND =
  "Spend guard (stall reconciler): this session shows $212 in 24h (thresholds: $150/day, 40 subagents/day; machines/spend-guard.json). Pick each subagent's model by task kind: mechanical work on Haiku, triage on Sonnet, judgment on Opus. No reply needed; this is sent once a day.";
const HOOK =
  "Stop hook feedback:\n[~/.claude/hooks/check.sh]: 2 tests still fail in webviews/test/composer.test.ts.\nFix them before stopping.";

/// The prompt as `acpmux send --no-wait` at a shell delivers it, read as direct.ts reads it.
function sent(text: string, minutes: number) {
  const incoming = incomingPrompt(text, { client: "acpmux-outbox#01a16e@lane-box-2" });
  return incoming?.kind === "message"
    ? user(incoming.message.notice ? noticeRowText(incoming.message.notice, incoming.message.text) : incoming.message.text, minutes, {
        incoming,
        untyped: true,
        resend: text,
      })
    : user(text, minutes);
}

const sessions = [session({ sessionId: SESSION_ID, title: "Session Info drag handles", name: "session-info" })];
const opening = [
  user("Make the Session Info rows draggable; keep the handle on hover only.", 40),
  assistant("On it: the handle shows on hover and the row drags by it. PR #31356 is open.", 39.5),
  summary(39.4, { status: "completed", durationMs: 92_000, toolCount: 14 }),
];

function after(read: (text: string, minutes: number) => ReturnType<typeof user>) {
  return chat(
    [
      ...opening,
      read(CONFLICT, 22),
      assistant("Merged main into #31356; the conflict in direct.ts was the new import. Pushed.", 21.5),
      summary(21.4, { status: "completed", durationMs: 48_000, toolCount: 6 }),
      read(PLATFORM, 14),
      assistant("cmux-platform#270 is not mine; leaving it to its owner.", 13.9),
      summary(13.8, { status: "completed", durationMs: 3_000, toolCount: 0 }),
      read(SPEND, 9),
      assistant("Noted.", 8.9),
      summary(8.8, { status: "completed", durationMs: 2_000, toolCount: 0 }),
      read(HOOK, 4),
      assistant("Fixed the two composer tests; they pass now.", 3.4),
      summary(3.3, { status: "completed", durationMs: 41_000, toolCount: 5 }),
    ],
    { title: "Session Info drag handles", sessions },
  );
}

const LINE = ".cv-received.cv-notice .cv-disclosure__toggle";

/// Opens the first notice's line (the conflict notice).
const openFirst: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(LINE), { capMs: 10_000 });
  if (ctx.document.querySelector(LINE)?.getAttribute("aria-expanded") !== "true") await ctx.click({ selector: LINE });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-notice .cv-received__text"), { capMs: 10_000 });
};

const variants: Record<string, AgentPaneVariant> = {
  collapsed: {
    note: "Default: each automated notice is one quiet line (info mark, sender, first sentence, chevron); the agent's reply under it as before.",
    snapshot: after(sent),
  },
  open: {
    note: "The conflict notice opened: the rest of its text under the line, Find and Copy reading the whole notice.",
    snapshot: after(sent),
    play: openFirst,
  },
  before: {
    note: "Before: the same chat as the pane drew it, each notice the person's own bubble.",
    snapshot: after((text, minutes) => user(text, minutes)),
  },
};

export default agentPaneEntry({
  id: "agent-pane.automated-notice",
  title: "Automated notice",
  area: "Agent pane",
  height: 760,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/agentNotice.ts#automatedNotice"],
  variants,
});
