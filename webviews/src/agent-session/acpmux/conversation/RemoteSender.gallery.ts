// l10n-allow-file: gallery fixtures (sample reports), not shipped UI.
// Reports other agents sent this chat from other machines: a Codex lane's `acpmux send` through
// the peer link, or over ssh with `reach`. acpmux records the sender it was told (`fromAgent`, from
// the lane's session or `ACPMUX_FROM`) as the prompt's provenance (prompt_provenance.rs
// `named_sender`), and the pane draws that lane's card. A daemon that recorded no sender left the
// same report as the person's bubble (claude-sr2, 2026-10-24). A task's result (`acpmux task done`,
// acpmux hub/tasks.rs) is the lane's card too, opening its chat.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, assistant, chat, session, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "./incomingMessage";

const REPORT =
  "#24927 merged at squash 6f0c2d1. Head bb92c90 had a fresh Codex xhigh SHIP and green CI; the gallery run showed the composer at both widths.";
const CLIENT = "acpmux-peer#01a16e";

/// The report as direct.ts reads its recorded `user_message`, with the sender acpmux recorded.
function report(minutes: number, from?: string) {
  const provenance = from && { kind: "agent_message", from: "fromAgent", fromName: from, to: SESSION_ID };
  const incoming = incomingPrompt(REPORT, { client: CLIENT, ...(provenance && { _meta: { provenance } }) });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { incoming, resend: REPORT, untyped: true })
    : user(REPORT, minutes);
}

/// The report from a chat someone gave a name (`acpmux rename @ Mango --handle`): acpmux stamps it
/// as `fromDisplayName` beside the session it sent from (prompt_provenance.rs).
function namedReport(minutes: number, sessionId: string, fromName: string) {
  const provenance = {
    kind: "agent_message",
    from: `acp:${sessionId}`,
    fromName,
    fromDisplayName: "Mango",
    fromHarness: "claude",
    to: SESSION_ID,
  };
  const incoming = incomingPrompt(REPORT, { client: CLIENT, _meta: { provenance } });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { incoming, resend: REPORT, untyped: true })
    : user(REPORT, minutes);
}

/// Mango is the coordinator chat `coordinator-old` on studio-mac.
const mangoSessions = (displayName?: string) => [
  session({ sessionId: SESSION_ID, title: "claude-sr2", name: "claude-sr2" }),
  session({
    sessionId: "coordinator-old-1",
    title: "coordinator-old",
    name: "studio-mac/coordinator-old",
    peer: "studio-mac",
    host: "studio-mac",
    hostKind: "cloud",
    ...(displayName && { displayName }),
  }),
];

const TASK_CARD =
  'Task t-1a2b3c4d "Land #24927" done: Merged at squash 6f0c2d1 after a Codex xhigh SHIP\nPR: https://github.com/example/app/pull/24927\nSHA: 6f0c2d1';

/// The result `acpmux task done` brought back, as direct.ts reads its recorded `user_message`.
function taskResult(minutes: number) {
  const provenance = {
    kind: "task_result",
    from: "codex-lane-1",
    fromName: "codex-lane",
    to: SESSION_ID,
    taskId: "t-1a2b3c4d",
    state: "done",
  };
  const incoming = incomingPrompt(TASK_CARD, { client: "acpmux", _meta: { provenance } });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { incoming, resend: TASK_CARD, untyped: true })
    : user(TASK_CARD, minutes);
}

/// codex-lane runs on studio-mac beside two more chats; one chat there is archived (off its menu).
const ON_STUDIO = { host: "studio-mac", hostKind: "cloud" as const };
const studioSessions = [
  session({ sessionId: SESSION_ID, title: "claude-sr2", name: "claude-sr2" }),
  session({ sessionId: "codex-lane-1", title: "codex-lane", name: "codex-lane", harness: "codex", ...ON_STUDIO }),
  session({
    sessionId: "studio-2",
    title: "perf-diff-poll-events",
    name: "perf-diff-poll-events",
    harness: "codex",
    ...ON_STUDIO,
  }),
  session({
    sessionId: "studio-3",
    title: "studio-mac/session-info",
    name: "studio-mac/session-info",
    peer: "studio-mac",
    ...ON_STUDIO,
  }),
  session({ sessionId: "studio-4", title: "old-lane", name: "old-lane", archived: true, ...ON_STUDIO }),
];

/// Opens the sender's machine menu.
const openMachine: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-menu="sender-machine"]'));
  ctx.document.querySelector<HTMLButtonElement>('[data-menu="sender-machine"]')!.click();
  await ctx.waitFor(() => ctx.document.querySelectorAll('[role="menuitem"]').length >= 2);
};

/// The received line, opened by a click on it (its chevron then points down).
const openLine: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('.cv-agentmsg[data-direction="received"] .cv-agentmsg__line'));
  await ctx.click({ selector: '.cv-agentmsg[data-direction="received"] .cv-agentmsg__line' });
  await ctx.waitFor(() => ctx.document.querySelector('.cv-agentmsg[data-direction="received"][data-open]'));
};

function snapshot(
  from?: string,
  last = report(3, from),
  sessions = [
    session({ sessionId: SESSION_ID, title: "claude-sr2", name: "claude-sr2" }),
    session({ sessionId: "codex-lane-1", title: "codex-lane", name: "codex-lane" }),
  ],
) {
  return chat(
    [
      user("Land #24927 once its review passes, then report here.", 9),
      assistant("Sent the order to codex-lane on build-box.", 8.5),
      summary(8.5, { status: "completed" }),
      last,
    ],
    {
      title: "claude-sr2",
      sessions,
    },
  );
}

export default agentPaneEntry({
  id: "agent-pane.remote-sender",
  title: "A report from another machine's agent",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/incomingMessage.ts",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
  ],
  variants: {
    named: {
      note: "acpmux recorded codex-lane as the sender: its card, with the chip.",
      snapshot: snapshot("codex-lane"),
    },
    machine: {
      note: "codex-lane runs on studio-mac: the line names the machine after the name, and the machine is a control of its own.",
      snapshot: snapshot("codex-lane", report(3, "codex-lane"), studioSessions),
    },
    "machine-open": {
      note: 'Leo, 2026-11-27, on "· gcp-agent-lane-19⌄": "these chevrons are too close dont we have any guidelines for these yet?" Opened, the machine ends the line\'s words: its chevron keeps the ink gap after the machine\'s name (design/chevrons.md), never the chip\'s pull-back.',
      snapshot: snapshot("codex-lane", report(3, "codex-lane"), studioSessions),
      play: openLine,
    },
    "machine-open-quiet": {
      note: "The same, in the quiet look (no first line on the line, even closed).",
      theme: { messageLineLook: "quiet" },
      snapshot: snapshot("codex-lane", report(3, "codex-lane"), studioSessions),
    },
    "machine-open-quiet-open": {
      note: "The quiet look, opened.",
      theme: { messageLineLook: "quiet" },
      snapshot: snapshot("codex-lane", report(3, "codex-lane"), studioSessions),
      play: openLine,
    },
    "machine-menu": {
      note: "Play: the machine opens a menu of the chats on studio-mac (archived ones left out), each opening beside this chat, and Copy machine name.",
      snapshot: snapshot("codex-lane", report(3, "codex-lane"), studioSessions),
      play: openMachine,
    },
    "given-name": {
      note: "The sender has a given name (acpmux rename @ Mango --handle): the line reads Mango, and its machine, studio-mac, follows.",
      snapshot: snapshot(
        undefined,
        namedReport(3, "coordinator-old-1", "studio-mac/coordinator-old"),
        mangoSessions("Mango"),
      ),
    },
    "given-name-unlisted": {
      note: "A given name from a chat this Mac does not list: the message carries the name (fromDisplayName), and the line reads Mango.",
      snapshot: snapshot(undefined, namedReport(3, "unlisted-9", "studio-mac/coordinator-old")),
    },
    "given-name-old-peer": {
      note: "The same chat listed by a peer on an older acpmux, with no displayName in its row: the message's own name still reads Mango.",
      snapshot: snapshot(undefined, namedReport(3, "coordinator-old-1", "studio-mac/coordinator-old"), mangoSessions()),
    },
    "task-result": {
      note: "codex-lane ended its task with acpmux task done: one card from the lane, its PR and squash under the summary.",
      snapshot: snapshot(undefined, taskResult(3)),
    },
    unnamed: {
      note: "A daemon that recorded no sender: the same report reads as the person's bubble.",
      snapshot: snapshot(),
    },
    "person-cli": {
      note: "The person's own acpmux send from a terminal on studio-mac: their bubble, and where they sent it from.",
      snapshot: chat(
        [
          user("Land #24927 once its review passes, then report here.", 9, { viaCli: "studio-mac" }),
          assistant("Sent the order to codex-lane on build-box.", 8.5),
          summary(8.5, { status: "completed" }),
        ],
        {
          title: "claude-sr2",
          sessions: [session({ sessionId: SESSION_ID, title: "claude-sr2", name: "claude-sr2" })],
        },
      ),
    },
  },
});
