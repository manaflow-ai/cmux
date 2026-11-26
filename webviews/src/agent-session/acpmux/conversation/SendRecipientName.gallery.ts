// l10n-allow-file: gallery fixtures (sample messages between agents), not shipped UI.
// Who a SendMessage went to, after a reload. Leo, 2026-11-22 (ask-908613f3b2), on the row
// "Sent to a6c31b7e": "some bullshit line about like... cmux... did something" (paraphrased). The
// page loads only the chat's tail. A helper whose Agent call came before that tail had nothing on
// the page to name it, so the row showed the first eight characters of its agent id. acpmux now
// names the subagent on the SendMessage itself (`_meta.acpmux.recipient`, subagents.rs
// `recipient`), and the row reads that name (`tool.recipient`) when the page cannot name the id.
import { minutesAgo } from "../../../gallery/clock";
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { SUBAGENTS } from "../subagents/subagentFold";

const CI_ID = "a6c31b7ee45d67550";
const PANE_ID = "a1f04c9d2b7e83a60";
const OTHER_ID = "a5b7309ddf7afa44d";
const CI_NAME = "Watch the cmux-ci run for lane--beyer-worked";
const PANE_NAME = "Agent chat pane blanked out";

/// Claude Code's SendMessage to a subagent by its agent id, with the name the daemon gave it.
const send = (to: string, message: string, recipient?: string) =>
  tool("SendMessage", "other", "completed", {
    inputSummary: JSON.stringify({ to, summary: message.split(".")[0], message }),
    output: JSON.stringify({ success: true, message: `Message queued for delivery to ${to} at its next tool round.` }),
    ...(recipient ? { recipient } : {}),
  });

/// The Agent call of the helper spawned inside the loaded tail: the page names this one itself.
const paneAgent = (minutes: number) =>
  row(SUBAGENTS, minutes, {
    subagents: [
      {
        id: "gallery-session/toolu_pane",
        parent: null,
        name: PANE_NAME,
        task: PANE_NAME,
        kind: "general-purpose",
        state: "running",
        startedAt: minutesAgo(minutes),
        background: true,
        agentId: PANE_ID,
      },
    ],
  });

const CI_NOTE = "Your cmux-ci run for lane--beyer-worked is queued. Report its verdict and the head sha.";
const PANE_NOTE = "A new lead from Leo: the pane blanked out after a reload. Find what reloaded it.";

/// The tail of Leo's chat as a reload loads it: the CI helper's Agent call is above the window.
const tail = (named: boolean) =>
  chat(
    [
      user("Keep the CI run going and look into the blank pane.", 3),
      activity([send(CI_ID, CI_NOTE, named ? CI_NAME : undefined)], 2.9),
      assistant("I'm separating the ask from the CI run, then handing the pane to a helper.", 2.8),
      paneAgent(2.7),
      activity([send(PANE_ID, PANE_NOTE, named ? PANE_NAME : undefined)], 2.6),
      summary(2.5, { status: "completed" }),
    ],
    { title: "turn-buttons-hover-ui" },
  );

export default agentPaneEntry({
  id: "agent-pane.send-recipient-name",
  title: "Sent to: the subagent's name after a reload",
  area: "Agent pane",
  height: 520,
  covers: [
    "agent-session/acpmux/conversation/MessageCard.tsx",
    "agent-session/acpmux/conversation/SentMessageLine.tsx",
    "agent-session/acpmux/conversation/agentMessages.ts",
  ],
  variants: {
    "before-raw-id": {
      note: 'Before: the tail Leo saw on 2026-11-22. The CI helper\'s Agent call is above the loaded window, so its send reads "Sent to a6c31b7e". The pane helper, spawned inside the window, reads by name.',
      snapshot: tail(false),
    },
    "after-daemon-name": {
      note: "After: the same tail. acpmux named both subagents on their SendMessage records, so the CI helper's row reads its task even though its Agent call is not on the page.",
      snapshot: tail(true),
    },
    "page-name-first": {
      note: "When the page has the Agent call, its name is used; the daemon's name only fills in for an id the page cannot name.",
      snapshot: chat([
        user("Ping the pane helper.", 2),
        paneAgent(1.9),
        activity([send(PANE_ID, PANE_NOTE, "An older name the daemon gave")], 1.8),
      ]),
    },
    "unnamed-stays-short": {
      note: "A send to an id that no subagent of this chat has (no daemon name, no Agent call) still reads as a short id, with the full id in its tooltip.",
      snapshot: chat([
        user("Resume the old helper.", 2),
        activity([send(OTHER_ID, "Resume: rerun the pre-push check and report.")], 1.8),
      ]),
    },
    "one-line": {
      note: "Minimal Mode: the named rows on one line each.",
      snapshot: tail(true),
      display: { "sidebar.minimal": true },
    },
  },
});
