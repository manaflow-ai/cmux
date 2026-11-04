// l10n-allow-file: gallery fixtures (sample lanes, messages and commands), not shipped UI.
// Every row kind of Leo's 2026-11-02 transcript capture, in one coordinator chat, so one test can
// measure each pair's gap against the settled values (leo-workspace design/transcript-spacing.md;
// Leo, 2026-11-02: "ugh we'll really want to study how chatgpt desktop and claude desktop do their
// spacing i just feel gross looking at these" and "we need to like enforce the good versions when
// we find them later in the specs/comments/tests or something"). A finished two-paragraph reply and
// its footer; an inbox row; then a running turn: "Sent 3 messages", a one-line reply, "Ran 2
// commands", an inbox row, the live line "Sending message to …" and the waiting group "2 messages
// from 2 sessions". transcript-spacing-table.test.ts measures it against transcriptSpacing.ts.
import { minutesAgo } from "../../../gallery/clock";
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import {
  SESSION_ID,
  activity,
  assistant,
  chat,
  row,
  session,
  summary,
  tool,
  user,
} from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity, AcpmuxSnapshot } from "../model";
import { SUBAGENTS } from "../subagents/subagentFold";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { incomingPrompt } from "./incomingMessage";
import { inboxText } from "./inboxNotice";

const send = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", {
    inputSummary: JSON.stringify({ to, message }),
    output: `delivered to ${to}\n`,
  });
const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });
const sending = (target: string, text: string): AcpmuxActivity =>
  tool(`acpmux send ${target} '${text}'`, "execute", "in_progress", {
    command: `acpmux send ${target} '${text}'`,
    description: `Ask ${target}`,
  });

const SESSIONS: Record<string, string> = { "grid-lane": "s-grid", "picker-lane": "s-picker", "review-box": "s-review" };

/// An inbox notice of one message from each of two sessions, as acpmux sends it (hub/inbox.rs
/// `render`; InboxNotice.gallery.ts draws the full range): its line reads "2 messages from 2 sessions".
function inbox(minutes: number, from: [string, string]) {
  const threads = from.map((name, index) => ({
    threadId: `pr:${2210 + index}-${minutes}`,
    label: `#${2210 + index}`,
    from: name,
    session: SESSIONS[name]!,
    text: index === 0 ? "Review passed at e34ce27." : "SHIP at 9c41a07.",
  }));
  const text = [
    "[inbox] New messages from other agents in 2 threads.",
    ...threads.map((t) => `- 1 new in ${t.label} from ${t.from}: ${t.text} (thread ${t.threadId})`),
  ].join("\n");
  const provenance = {
    kind: "inbox_notice",
    noticeId: `inbox-notice-spacing-${minutes}`,
    threads: threads.map((t, index) => ({
      threadId: t.threadId,
      label: t.label,
      new: 1,
      from: [t.from],
      fromSession: t.session,
      promptIds: [`p-spacing-${minutes}-${index}`],
      blocker: false,
      preview: t.text,
      messages: [{ from: t.from, text: t.text }],
    })),
  };
  const incoming = incomingPrompt(text, { client: "acpmux", _meta: { provenance } });
  return incoming?.kind === "inbox"
    ? user(inboxText(incoming.notice), minutes, { incoming, untyped: true })
    : user(text, minutes);
}

const REPLY = [
  "The three lanes have their briefs: grid-lane takes the row pitch, picker-lane the menu polish and review-box the exact-head review.",
  "I'll land each as its review passes and send you the links together once the nightly has picked them up.",
].join("\n\n");

/// Every row kind of Leo's 2026-11-02 23:59Z capture in one Claude Code chat ("these are all so
/// stupid looking" / "the spacing"): a finished reply and its footer, another session's message
/// received, a scheduled check the agent ran on its own, "Ran 2 commands" (the table test opens it to
/// its two commands), a one-line reply and its footer, the next prompt, a finished compaction, a
/// two-line reply, one command and a compaction still running as the chat's last row. Each pair is
/// one row of transcriptSpacing.ts TRANSCRIPT_SPACING_KINDS.
function allKinds(): AcpmuxSnapshot {
  const fromLane = (text: string, minutes: number, id: string) =>
    user(text, minutes, {
      id,
      incoming: {
        kind: "message",
        message: { name: "merge-timeout", sessionId: "s-merge", harness: "claude", text, raw: text },
      },
      untyped: true,
    });
  const snapshot = chat(
    [
      user("Where do the merge timeouts stand?", 14, { id: "kinds-prompt" }),
      assistant(REPLY, 13.5, { id: "kinds-reply" }),
      summary(13.4, { id: "kinds-footer", status: "completed", durationMs: 34_000, toolCount: 0 }),
      fromLane("Deployed; the lander is on 59c1e0a.", 9, "kinds-received"),
      row(BACKGROUND_TURN, 8.5, {
        id: backgroundTurnRowId("spacing-scheduled"),
        background: { id: "spacing-scheduled", trigger: "scheduled", running: false, quiet: true, hasRows: true },
      }),
      activity([tool("git fetch origin", "execute", "completed", { command: "git fetch origin" })], 8.4, {
        inBackground: "spacing-scheduled",
      }),
      activity(
        [run("Checked the lander", "systemctl status next-autoland"), run("Read the head", "git log --oneline -1")],
        8,
        { id: "kinds-run" },
      ),
      assistant("The lander runs 59c1e0a now.", 7.8, { id: "kinds-short" }),
      summary(7.7, { id: "kinds-short-footer", status: "completed", durationMs: 21_000, toolCount: 2 }),
      user("Compact the chat, then land the rest.", 5, { id: "kinds-next-prompt" }),
      row("compaction", 4.9, {
        id: "kinds-compacted",
        compaction: { state: "completed", preTokens: 369_000, postTokens: 24_000 },
      }),
      assistant(
        "Picking up where we left off: #2210 and #2214 both have a passing review at their heads, so I will land them one after the other and watch the nightly pick them up before I report back.",
        4.5,
        { id: "kinds-long" },
      ),
      activity([run("Landed #2210", "gh pr merge 2210 --squash")], 4, { id: "kinds-step" }),
      row("compaction", 3.5, { id: "kinds-compacting", compaction: { state: "running" } }),
    ],
    {
      title: "polish-coordinator",
      sessions: [
        session({ sessionId: SESSION_ID, title: "polish-coordinator", name: "polish-coordinator" }),
        session({ sessionId: "s-merge", title: "merge-timeout", name: "merge-timeout" }),
      ],
    },
  );
  // A Claude Code chat, as acpmux names its family: its runs fold per run (turns.ts), so the work
  // reads "Ran 2 commands" as in Leo's capture, not under "Worked for".
  return { ...snapshot, summary: { ...snapshot.summary!, family: "claude" } };
}

/// Two messages from two sessions that wait for the turn to end (PendingMessagesCard.tsx): "2
/// messages from 2 sessions", as in Leo's capture.
const WAITING = [
  { id: "w1", from: "grid-lane", session: "s-grid", text: "Review passed at e34ce27; landing #2210 now." },
  { id: "w2", from: "review-box", session: "s-review", text: "Still SHIP at 9c41a07." },
].map((m) => ({
  id: m.id,
  prompt: m.text,
  message: { name: m.from, sessionId: m.session, harness: "claude", text: m.text, raw: m.text },
}));

/// Another agent's message, as acpmux hands it in from a lane on another machine: the sender named
/// `<machine>/<name>` (hub/peers.rs), its chat listed on that machine.
const PEER = "lane-vm-01";
const received = (text: string, minutes: number, continues = false) =>
  user(text, minutes, {
    ...(continues && { continues: true }),
    incoming: {
      kind: "message",
      message: {
        name: `${PEER}/merge-timeout`,
        sessionId: "s-merge",
        harness: "claude",
        text,
        raw: text,
      },
    },
    untyped: true,
  });

/// Leo's 2026-11-02 capture ("wtf these tool call spacing things are still weird"): a finished
/// reply's footer, then another machine's lane's message, then the turn it started, its work folded
/// to "Ran 2 commands, received a message". Every line on one 22px line, its icon in the shared
/// column, the sender named once (transcript-received-line.test.ts).
const peerLines = () => {
  const snapshot = chat(
    [
      user("Where do the merge timeouts stand?", 14),
      assistant(REPLY, 13.5),
      summary(13.4, { status: "completed", durationMs: 34_000, toolCount: 0 }),
      received("merge-timeout: please deploy leo-workspace main 59c1e0a to the lander and confirm.", 9),
      activity(
        [run("Checked the lander", "systemctl status next-autoland"), run("Read the head", "git log --oneline -1")],
        8.8,
      ),
      received("Deployed; the lander is on 59c1e0a.", 8.6, true),
      assistant("The lander runs 59c1e0a now.", 8.4),
      summary(8.3, { status: "completed", durationMs: 21_000, toolCount: 2 }),
    ],
    {
      title: "polish-coordinator",
      sessions: [
        session({ sessionId: SESSION_ID, title: "polish-coordinator", name: "polish-coordinator" }),
        session({
          sessionId: "s-merge",
          name: `${PEER}/merge-timeout`,
          title: "merge-timeout",
          peer: PEER,
          host: PEER,
          hostKind: undefined,
        }),
      ],
    },
  );
  // A Claude Code chat, as acpmux names its family: its turn's runs fold per run (turns.ts), so the
  // work reads "Ran 2 commands, received a message" as in Leo's capture, not under "Worked for".
  return { ...snapshot, summary: { ...snapshot.summary!, family: "claude" } };
};

/// Leo's 2026-11-03 04:44Z captures ("this is pretty bad spacing and formatting" / "i thought we made
/// this stuff smaller"), the bottom of a running Claude Code turn, two ways. `working-bottom`: its
/// work folded to "Sent a message, ran 3 commands, used 3 tools", a subagent that finished, the live
/// "Thinking" line and "1 message from 1 session" waiting. `reply-received`: a finished reply, then
/// another machine's lane's message, the turn it started sending a message on, and "Thinking". Every
/// one of those status rows sits on the tool rows' 22 pitch, 16 from the prose around them
/// (design/transcript-spacing.md rules 3 and 4); transcript-spacing-kinds.test.ts measures them
/// against transcriptSpacing.ts TRANSCRIPT_STATUS_ROWS.
const SPACING_PEER = "lane-vm-02";
const OWNER_PEER = "lane-vm-03";
const statusSessions = () => [
  session({ sessionId: SESSION_ID, title: "spacing-coordinator", name: "spacing-coordinator" }),
  session({
    sessionId: "s-spacing",
    name: `${SPACING_PEER}/row-rhythm`,
    title: "row-rhythm",
    peer: SPACING_PEER,
    host: SPACING_PEER,
    hostKind: undefined,
  }),
  session({
    sessionId: "s-owner",
    name: `${OWNER_PEER}/daemon-owner`,
    title: "daemon-owner",
    peer: OWNER_PEER,
    host: OWNER_PEER,
    hostKind: undefined,
  }),
];
const fromPeer = (text: string, minutes: number, id: string) =>
  user(text, minutes, {
    id,
    incoming: {
      kind: "message",
      message: { name: `${SPACING_PEER}/row-rhythm`, sessionId: "s-spacing", harness: "claude", text, raw: text },
    },
    untyped: true,
  });
const claudeChat = (snapshot: AcpmuxSnapshot): AcpmuxSnapshot => ({
  ...snapshot,
  summary: { ...snapshot.summary!, family: "claude" },
});

function workingBottom(): AcpmuxSnapshot {
  const read = (path: string) => tool(`Read ${path}`, "read", "completed");
  return claudeChat(
    chat(
      [
        user("Fix the status row spacing and land it.", 4, { id: "status-prompt" }),
        activity(
          [
            send(`${OWNER_PEER}/daemon-owner`, "Is the notice change merged?"),
            run("Read the spec", "git show origin/main:design/transcript-spacing.md"),
            run("Found the gap rules", "rg -n transcriptGap src"),
            run("Checked the head", "git log --oneline -1"),
            read("src/transcriptGrid.ts"),
            read("src/model.ts"),
            read("src/turns.ts"),
          ],
          3.5,
          { id: "status-work" },
        ),
        row(SUBAGENTS, 3, {
          id: "status-subagents",
          subagents: [
            {
              id: "agent-gap-audit",
              parent: null,
              name: "gap-audit",
              task: "Measure every status row gap",
              state: "completed",
              startedAt: minutesAgo(3),
              endedAt: minutesAgo(1),
            },
          ],
        }),
      ],
      {
        title: "spacing-coordinator",
        isWorking: true,
        queue: [
          {
            id: "status-waiting",
            prompt: "The notice change is merged; build on it.",
            message: {
              name: `${SPACING_PEER}/row-rhythm`,
              sessionId: "s-spacing",
              harness: "claude",
              text: "The notice change is merged; build on it.",
              raw: "The notice change is merged; build on it.",
            },
          },
        ],
        sessions: statusSessions(),
      },
    ),
  );
}

function replyReceived(): AcpmuxSnapshot {
  return claudeChat(
    chat(
      [
        user("Where does the row spacing stand?", 9, { id: "received-prompt" }),
        assistant(
          "The gaps come from the live line's footer slot and the waiting group's block gap; both go to the 22 pitch next.",
          8.5,
          { id: "received-reply" },
        ),
        summary(8.4, { id: "received-footer", status: "completed", durationMs: 41_000, toolCount: 0 }),
        fromPeer("Agent links merged: the notice rows are one received line now.", 2, "received-line"),
        activity([send(`${OWNER_PEER}/daemon-owner`, "From the coordinator: rebase on the merged notice rows.")], 1.5, {
          id: "received-sent",
        }),
      ],
      { title: "spacing-coordinator", isWorking: true, sessions: statusSessions() },
    ),
  );
}

/// Leo's 2026-11-03 06:20Z capture ("this feels like too awkward of a gap :("): a finished reply and
/// its footer, five background tasks' ends noted for calls on a page not loaded (direct.ts
/// `background_task_update`), six other agents' messages that started a turn ("Received 6
/// messages"), one more task's end noted in that turn, and the live "Thinking" line under it, which
/// sits on the 22 pitch like every one-line row (design/transcript-spacing.md rule 3, step-to-live).
function notesThenLive(): AcpmuxSnapshot {
  const note = (n: number, command: string, minutes: number, id = `notes-task-${n}`) =>
    row("backgroundTask", minutes, {
      id,
      backgroundTask: { toolCallId: `notes-call-${n}`, command, state: "completed" },
    });
  const message = (n: number, text: string) =>
    user(text, 4 - n * 0.1, {
      id: `notes-message-${n}`,
      incoming: {
        kind: "message",
        message: { name: `${SPACING_PEER}/row-rhythm`, sessionId: "s-spacing", text, raw: text },
      },
      resend: text,
      untyped: true,
    });
  return claudeChat(
    chat(
      [
        user("Land the spacing fixes once their reviews pass.", 12, { id: "notes-prompt" }),
        assistant("All three are landed; the reviews passed at their heads.", 11, { id: "notes-reply" }),
        summary(10.9, { id: "notes-footer", status: "completed", durationMs: 52_000, toolCount: 0 }),
        note(1, "Wait for remote CI run", 9),
        note(2, "Wait for the webview verdict", 8.5),
        note(3, "Wait for the nightly build", 8),
        note(4, "Wait for remote CI run", 7.5),
        note(5, "Wait for the gallery capture", 7),
        ...[1, 2, 3, 4, 5, 6].map((n) => message(n, `Review ${n} passed at its head.`)),
        note(6, "router-review manaflow-ai/cmux 33062", 2, "notes-last"),
      ],
      { title: "spacing-coordinator", isWorking: true, sessions: statusSessions() },
    ),
  );
}

/// Leo's 2026-11-03 06:55Z capture ("why is the spacing like this it's weird"): an earlier turn
/// ending on status rows ("2 background updates", "Subagent finished"), the person's next prompt,
/// and the first status row of its turn ("Sent to …"). The prompt stays centred, 32 from the
/// rows on each side (design/transcript-spacing.md rule 5, `step-to-prompt` and `prompt-to-step`).
function statusPrompt(): AcpmuxSnapshot {
  const note = (n: number, state: "completed" | "stopped", minutes: number) =>
    row("backgroundTask", minutes, {
      id: `sp-task-${n}`,
      backgroundTask: { toolCallId: `sp-call-${n}`, command: `Wait for run ${n}`, state },
    });
  return claudeChat(
    chat(
      [
        user("Check the nightly and the cloud machines.", 50, { id: "sp-first" }),
        activity([run("Checked the nightly", "gh run list -w nightly -L 1")], 49, { id: "sp-work" }),
        row(SUBAGENTS, 48.8, {
          id: "sp-subagents",
          subagents: [
            {
              id: "agent-sp-cloud",
              parent: null,
              name: "cloud-check",
              task: "Check the cloud machines",
              state: "completed",
              startedAt: minutesAgo(48),
              endedAt: minutesAgo(6),
            },
          ],
        }),
        assistant("The nightly is green; a subagent checks the cloud machines.", 48.5, { id: "sp-reply" }),
        summary(48.4, { id: "sp-footer", status: "completed", durationMs: 96_000, toolCount: 1 }),
        note(1, "completed", 7),
        note(2, "stopped", 6.5),
        // The background turn the subagent's end started, which said nothing: its footer draws nothing.
        summary(5.9, { id: "sp-bg-footer", status: "completed", durationMs: 2_000, toolCount: 0 }),
        user("does this nightly cloud work!?", 3, { id: "sp-prompt" }),
        // Claude's blank text before its first call.
        assistant("\n\n", 2.8, { id: "sp-blank" }),
        activity([send(`${OWNER_PEER}/daemon-owner`, "Don't end turns to wait: check the nightly yourself.")], 2.5, {
          id: "sp-sent",
        }),
      ],
      { title: "spacing-coordinator", isWorking: true, sessions: statusSessions() },
    ),
  );
}

/// The session chip's looks compared over `reply-received` (the pick, shipped in AgentTag.css: the
/// row's words on a light wash, 1em + 4px tall, no ring): the 22 bordered chip it replaces, and
/// Claude Code desktop's underlined name with no wash (reference claude/live/transcript-peer-session-message).
/// Gallery only: a style laid over the shipped rule.
const chipLook =
  (css: string): Play =>
  async (ctx) => {
    const style = ctx.document.createElement("style");
    style.textContent = css;
    ctx.document.head.append(style);
  };
const CHIP_BEFORE = `button.cv-agent-tag.is-open { height: 22px; line-height: 22px; font-size: var(--text-control); border-radius: 6px; background: color-mix(in srgb, var(--cv-text) 9%, transparent); box-shadow: inset 0 0 0 var(--cmux-hairline, 0.5px) color-mix(in srgb, var(--cv-text) 18%, transparent); }`;
const CHIP_UNDERLINE = `button.cv-agent-tag.is-open { padding: 0; background: none; box-shadow: none; text-decoration: underline; text-decoration-color: color-mix(in srgb, currentColor 40%, transparent); text-underline-offset: 3px; }`;

export default agentPaneEntry({
  id: "agent-pane.transcript-spacing-table",
  title: "Transcript spacing: every row kind against the settled values",
  area: "Agent pane",
  height: 1000,
  covers: [
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/transcriptGrid.ts",
    "agent-session/acpmux/transcriptSpacing.ts",
  ],
  variants: {
    "all-kinds": {
      note: 'Every row kind of Leo\'s 2026-11-02 capture: a reply and its footer, a received message, "Scheduled check", "Ran 2 commands", a reply and footer, the next prompt, a finished compaction, a two-line reply, a command and "Compacting the conversation…".',
      height: 1100,
      snapshot: allKinds(),
    },
    shipped: {
      note: 'A finished reply and its footer; an inbox row; then a running turn: a send, a command and a send, a reply line, "Ran 2 commands", an inbox row, "Sending message to …" and "2 messages from 2 sessions".',
      snapshot: chat(
        [
          user("Where are the three polish lanes?", 14),
          assistant(REPLY, 13.5),
          summary(13.4, { status: "completed", durationMs: 34_000, toolCount: 0 }),
          inbox(9, ["grid-lane", "review-box"]),
          user("Hand the three polish lanes their briefs.", 6),
          activity(
            [
              // A command between the sends keeps three one-line rows: two sends in a row would be one
              // "Sent 2 messages" line (toolGroups.ts `sendGroup`; Leo, 2026-11-04).
              send("grid-lane", "Take the one-line row pitch."),
              run("Listed the polish lanes", "acpmux ls --json"),
              send("review-box", "Review #2214 at its head."),
            ],
            5.9,
          ),
          assistant("Briefs are out; checking #2210 before I land it.", 5.5),
          activity([run("Checked #2210", "gh pr checks 2210"), run("Read the head", "git log --oneline -1")], 5),
          inbox(3, ["picker-lane", "grid-lane"]),
          activity([sending("review-box", "Is #2214 still SHIP at its head?")], 1.8),
        ],
        {
          title: "polish-coordinator",
          isWorking: true,
          queue: WAITING,
          sessions: [
            session({ sessionId: SESSION_ID, title: "polish-coordinator", name: "polish-coordinator" }),
            session({ sessionId: "s-grid", title: "grid-lane", name: "grid-lane" }),
            session({ sessionId: "s-picker", title: "picker-lane", name: "picker-lane", harness: "codex" }),
            session({ sessionId: "s-review", title: "review-box", name: "review-box", harness: "codex" }),
          ],
        },
      ),
    },
    "working-bottom": {
      note: 'Leo\'s 2026-11-03 capture, the bottom of a running turn: "Sent a message, ran 3 commands, used 3 tools", a finished subagent, "Thinking" and "1 message from 1 session", each on the 22 pitch.',
      snapshot: workingBottom(),
    },
    "reply-received": {
      note: "The pick (version B). Leo's 2026-11-03 capture after a reply: another machine's lane's message, \"Sent to\" and \"Thinking\" 22 apart, each session chip the row's words on a light wash, no ring.",
      snapshot: replyReceived(),
    },
    "notes-live": {
      note: 'Leo\'s 2026-11-03 06:20Z capture: a reply\'s footer, five "Background task finished" notes, "Received 6 messages", one more note, and "Thinking" 22 under it.',
      snapshot: notesThenLive(),
    },
    "status-prompt": {
      note: 'Leo\'s 2026-11-03 06:55Z capture: "2 background updates" and "Subagent finished" end a turn, then the next prompt, then "Sent to …": the prompt 32 from the rows on each side.',
      snapshot: statusPrompt(),
    },
    "reply-received-before": {
      note: "Version A, the replaced look: the 22 bordered chip at the control size, taller than its row's words.",
      snapshot: replyReceived(),
      play: chipLook(CHIP_BEFORE),
    },
    "reply-received-underline": {
      note: "Version C: Claude Code desktop's underlined name, no wash. Lightest, but reads as prose, not a way to another chat.",
      snapshot: replyReceived(),
      play: chipLook(CHIP_UNDERLINE),
    },
    "peer-lines": {
      note: "A reply's footer, a lane on another machine's message, then \"Ran 2 commands, received a message\": one line height, one icon column, the sender once.",
      snapshot: peerLines(),
    },
  },
});
