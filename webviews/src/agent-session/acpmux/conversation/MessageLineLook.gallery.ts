// l10n-allow-file: gallery fixtures (sample lanes, messages and commands), not shipped UI.
// Message rows between agents in a coordinator's running turn, drawn after Leo's 2026-11-02
// captures of the coordinator chat. He said yes to splitting "Sent to build-box/spinner-lane
// · and 5 more commands coordinator: Leo's answer (v…", a count, a target and a message preview
// truncated on one line, and of the same rows: "i also think this is quite weird looking". The turn
// holds `acpmux send` calls that also ran other commands, a SendMessage, another machine's lane's
// message, the live "Sending message to …" line and seven messages from six sessions that wait.
// Each look (messageLineLook.ts, theme `messageLineLook`) draws the same chat: `single`, the default
// since Leo said of the stacked rows (2026-11-03) "i don't think these subtitles are as good as just
// doing it directly in the same line", keeps the verb, the whole recipient name, the count, the
// muted first line and then the chevron on one line, the first line taking the cut; `stacked` (#33249)
// puts the first line on its own line under the row; `quiet` keeps the line alone until the row
// opens. `opened` shows an opened send. `leo-capture` redraws Leo's 2026-11-03 capture: a bot's
// received line, sends to long `host/lane` names with "· and 1 more command", SendMessage rows and a
// "Received 2 messages" run, in each look.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { SESSION_ID, activity, chat, session, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity, AcpmuxSnapshot } from "../model";

const PEER = "studio-mac";
const COORD = "coordinator";

const LONG =
  "coordinator: idle ~65 min on Leo's browser-tab speed ask (optimistic open, no top new-tab animation in the main pane first). What's the PR and head? If it's waiting on something, name the fix you're putting in flight; otherwise continue. Stop when merged and the nightly opens a tab instantly in the right pane.";

/// A coordinator's shell call: a check, then one `acpmux send`, then more commands, so the row reads
/// "Sent to <target> · and N more commands".
const sendAndMore = (target: string, text: string, status = "completed"): AcpmuxActivity => {
  const command = [
    "acpmux ls --json > /tmp/coord-ls.json",
    `acpmux send --no-wait ${target} '${text.replace(/'/g, "'\\''")}'`,
    "python3 /tmp/summarize.py",
    "git -C ~/Projects/leo-workspace fetch -q",
    "tools/now show | head -40",
    "pr-owner orphans",
    "date",
  ].join("; ");
  return tool(command.slice(0, 120), "execute", status, {
    command,
    description: `Nudge ${target.split("/").at(-1)}`,
    ...(status === "completed" ? { output: "queued\n", exitCode: 0 } : {}),
  });
};
const plainSend = (target: string, text: string): AcpmuxActivity => {
  const command = `acpmux send --no-wait ${target} '${text.replace(/'/g, "'\\''")}'`;
  return tool(command.slice(0, 120), "execute", "completed", {
    command,
    description: `Tell ${target.split("/").at(-1)}`,
    output: "queued\n",
    exitCode: 0,
  });
};
const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });
const sendingNow = (target: string, text: string): AcpmuxActivity =>
  tool(`acpmux send ${target} '${text}'`, "execute", "in_progress", {
    command: `acpmux send ${target} '${text}'`,
    description: `Ask ${target}`,
  });

/// Claude Code's SendMessage to a lane (MessageCard.tsx, AgentMessageRow.tsx).
const sendMessage = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", { inputSummary: JSON.stringify({ to, message }) });

const fromPeer = (text: string, minutes: number) =>
  user(text, minutes, {
    incoming: {
      kind: "message",
      message: { name: `${PEER}/fleet-mesh`, sessionId: "s-mesh", harness: "claude", text, raw: text },
    },
    untyped: true,
  });

const WAITING = [
  ["course-lane", "s-w1", "Lesson 4 merged; the gallery has its captures."],
  ["build-box/broker-socket", "s-w2", "SHIP at 4be1c09; landing."],
  ["build-box/web-base-reds", "s-w3", "Rerun went green; base is clear."],
  ["build-box/freestyle-pause-resume", "s-w4", "Paused VMs resume on the next open."],
  ["build-box/newtab-flash", "s-w5", "PR #33190 at 7d1e2aa, review running."],
  ["build-box/env-picker", "s-w6", "The picker reads machines first now."],
  ["build-box/newtab-flash", "s-w5", "Review passed; merging."],
].map(([from, sessionId, text], index) => ({
  id: `waiting-${index}`,
  prompt: text!,
  message: { name: from!, sessionId: sessionId!, harness: "codex", text: text!, raw: text! },
}));

function coordinatorTurn(): AcpmuxSnapshot {
  const snapshot = chat(
    [
      user("Check on the routed lanes and nudge the idle ones.", 6, { id: "coord-prompt" }),
      activity([run("Check states of my routed lanes", "acpmux ls --json --status running")], 5.8),
      activity([sendAndMore("build-box/newtab-flash", LONG)], 5.6, { id: "coord-send-1" }),
      activity(
        [
          sendAndMore(
            "build-box/freestyle-pause-resume",
            "coordinator: idle ~40 min on the pause/resume ask. Name the PR and its head, or the fix you are putting in flight.",
          ),
        ],
        5.4,
      ),
      fromPeer(
        'The area→owner table is live. NOW.md has a "## Area owners" section (generated from the registry), and the asks reconciler reads it.',
        5.2,
      ),
      activity(
        [run("Check rerun result; start router-review for HQ#6406", "gh run view 41578642105 --json conclusion")],
        5,
      ),
      activity(
        [
          plainSend(
            "build-box/web-base-reds",
            "coordinator: rerun of 41578642105 --failed was accepted (job 3 of 4 green so far).",
          ),
          plainSend(
            "build-box/env-picker",
            "coordinator: nobody owns Cloud GitHub identity. Build both halves: the picker row and the token handoff.",
          ),
        ],
        4.8,
      ),
      activity([sendingNow("build-box/right-pane", "Is #33102 merged? Name the head.")], 4.6),
    ],
    {
      title: COORD,
      isWorking: true,
      queue: WAITING,
      sessions: [
        session({ sessionId: SESSION_ID, title: COORD, name: COORD }),
        session({ sessionId: "s-newtab", name: "build-box/newtab-flash", title: "newtab-flash" }),
        session({
          sessionId: "s-mesh",
          name: `${PEER}/fleet-mesh`,
          title: "fleet-mesh",
          peer: PEER,
          host: PEER,
          hostKind: undefined,
        }),
      ],
    },
  );
  // A Claude Code chat: its runs fold per run (turns.ts), as in Leo's capture.
  return { ...snapshot, summary: { ...snapshot.summary!, family: "claude" } };
}

/// Leo's 2026-11-03 capture, redrawn: a bot's received line, sends to long `host/lane` names (one with
/// "· and 1 more command"), SendMessage rows to long names whose text starts "From <sender>:", and a
/// received pair, so the names' cut and the chevrons' place show at a glance.
function leoCapture(): AcpmuxSnapshot {
  const bot = (text: string, minutes: number) =>
    user(text, minutes, {
      incoming: {
        kind: "message",
        message: { name: "disk-hygiene", sessionId: "s-disk", text, raw: text },
      },
      untyped: true,
    });
  const snapshot = chat(
    [
      user("Sweep the fleet's stalled lanes.", 9, { id: "leo-prompt" }),
      bot("disk-hygiene on build-box-16: no-run: no full run finished in the last 3 h", 8.8),
      activity(
        [
          sendAndMore(
            "studio-mac/coordinator-fleet-mesh",
            "coordinator: build-box-16's disk cleanup stalled; it is yours (fleet-mesh owns that class).",
          ),
        ],
        8.6,
      ),
      fromPeer("Took it: the cleanup runs read-only checks there until the perf work ends.", 8.4),
      fromPeer("Done: 41 GB freed, the timer is back on its 6 h schedule.", 8.3),
      activity(
        [
          sendMessage(
            "cloud-codex-swarm-10/spinner-chatgpt",
            "From coordinator: please stand down on ask c-8d2b48aedc; it's a duplicate of the spinner lane's.",
          ),
          sendMessage(
            "coordinator-stall-reconciler",
            "From coordinator: stall-reconciler flags a stack in your area: platform#412 has sat 3 h.",
          ),
        ],
        8,
      ),
      activity(
        [
          sendAndMore(
            "studio-mac/coordinator-fleet-mesh",
            "coordinator: the cleanup is yours; report when the timer is green.",
          ),
        ],
        7.8,
      ),
    ],
    {
      title: COORD,
      sessions: [
        session({ sessionId: SESSION_ID, title: COORD, name: COORD }),
        session({
          sessionId: "s-mesh",
          name: `${PEER}/fleet-mesh`,
          title: "fleet-mesh",
          peer: PEER,
          host: PEER,
          hostKind: undefined,
        }),
      ],
    },
  );
  return { ...snapshot, summary: { ...snapshot.summary!, family: "claude" } };
}

/// Opens the first send, to show the opened message with Raw under it. In the one-line default
/// (#34464) a sent row has no Copy (cmux#34865); only the stacked version keeps one under the
/// message beside Raw (`.cv-subsession__actions`), so the play waits for Raw. It clicks the
/// message's first line on the row, as a person does: the recipient's chip is a button of its own
/// that opens that chat.
const openFirstSend: Play = async (ctx) => {
  await ctx.click({ selector: ".cv-sent .cv-sent__preview" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-subsession__under .cv-subsession__toggle"));
};

export default agentPaneEntry({
  id: "agent-pane.message-line-look",
  title: "Message rows: line and first line",
  area: "Agent pane",
  height: 560,
  covers: [
    "agent-session/acpmux/conversation/messageLineLook.ts",
    "agent-session/acpmux/conversation/SentMessageLine.tsx",
    "agent-session/acpmux/conversation/AgentMessageRow.tsx",
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
    "agent-session/acpmux/conversation/MessageGroupHead.tsx",
    "agent-session/acpmux/conversation/Thinking.tsx",
    "agent-session/acpmux/subagents/DisclosureRow.tsx",
  ],
  keywords: [
    "message",
    "sent",
    "received",
    "preview",
    "one line",
    "inline",
    "two lines",
    "stacked",
    "and more commands",
    "sending",
    "long names",
  ],
  variants: {
    single: {
      note: "The default: each message row on one line, the verb, the recipient's whole name, the count, the message's first line muted and cut, then the chevron right after the words. Rows read in the transcript's text tone.",
      snapshot: coordinatorTurn(),
    },
    "leo-capture": {
      note: "Leo's 2026-11-03 capture redrawn in the default: a bot's received line, sends to long host/lane names, two SendMessages folded into one closed \"Sent 2 messages\" line (cmux#34865) and a received pair, each name whole and the first line on the same line.",
      snapshot: leoCapture(),
    },
    "leo-capture-stacked": {
      note: "Before (cmux#33249's stacked look, gallery version): the same capture with each first line on its own line under the row.",
      theme: { messageLineLook: "stacked" },
      snapshot: leoCapture(),
    },
    stacked: {
      note: "Gallery version (theme messageLineLook stacked, cmux#33249): each message row's verb, recipient chip, count and chevron on its line, the message's first line on its own line under it, cut there.",
      theme: { messageLineLook: "stacked" },
      snapshot: coordinatorTurn(),
    },
    opened: {
      note: "The first send opened in the default one-line look: its message at the row's text column, Raw quiet under it at the same indent; the row has no Copy.",
      snapshot: coordinatorTurn(),
      play: openFirstSend,
    },
    quiet: {
      note: "Gallery version (theme messageLineLook quiet): the line alone, the first line only once the row opens.",
      theme: { messageLineLook: "quiet" },
      snapshot: coordinatorTurn(),
    },
  },
});
