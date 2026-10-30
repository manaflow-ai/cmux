// l10n-allow-file: gallery fixtures (sample agent names and messages), not shipped UI.
// Messages this agent sent other agents in a row (toolGroups.ts `messages`, MessageGroupRow.tsx):
// one line over a quiet card, "Messaging <target> 11s" while one goes out and "Messaged <target> 3
// times" once all went, a row per message that opens in place to its text with Copy. The versions
// beside the default (`theme.messageGroupLook`) keep the rows on the edit group's tree guide
// (`guide`) or flush with hairlines and no ring (`list`); `off` draws each message as its own row,
// as before groups. The calls have Claude Code's SendMessage shape; names and messages are made up.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const PICKER = "Model picker spruce-up";

const BRIEFS = [
  [
    "## Model picker: keep the list, drop the chrome",
    "",
    "- Keep the provider sections and the search field exactly as they are.",
    "- Drop the second divider under the header; it doubles the one the list draws.",
    "- Done when a screenshot shows the picker open over a long chat in both themes.",
  ].join("\n"),
  "Rebased on feat-cmux-next. The menu now opens on the click with no fade; please re-run the gallery capture.",
  "One more: the checkmark column should line up with the composer's lead. Report back with the PR link when it lands.",
];

/// Claude Code's SendMessage as acpmux records it; `secondsAgo` places its start.
const sendMessage = (to: string, message: string, status: string, secondsAgo: number, took = 2) =>
  tool("SendMessage", "other", status, {
    inputSummary: JSON.stringify({ to, message }),
    startedAt: minutesAgo(secondsAgo / 60),
    ...(status === "completed" && {
      endedAt: minutesAgo((secondsAgo - took) / 60),
      output: JSON.stringify({ success: true, message: `Message sent to ${to}'s inbox` }),
    }),
  });

const finished = () =>
  chat(
    [
      user("Send the picker brief, then follow up on the rebase and the check column.", 3),
      activity(
        BRIEFS.map((text, at) => sendMessage(PICKER, text, "completed", 170 - at * 20)),
        2.9,
      ),
      assistant("Sent the brief and both follow-ups to the model picker lane.", 2.2),
      summary(2.2, { status: "completed" }),
    ],
    { title: "Polish lane" },
  );

const mixed = () =>
  chat(
    [
      user("Hand out the three polish briefs.", 3),
      activity(
        [
          sendMessage(PICKER, BRIEFS[0]!, "completed", 170),
          sendMessage(
            "Thread rail: left, fast, scrollable",
            "Keep the rail on the left; it scrolls with the transcript and never lags it.",
            "completed",
            150,
          ),
          sendMessage(
            "Composer menu timing",
            "Menus open on the click. Closing may fade; nothing fades in.",
            "completed",
            130,
          ),
        ],
        2.9,
      ),
      assistant("All three lanes have their briefs.", 2.2),
      summary(2.2, { status: "completed" }),
    ],
    { title: "Polish lane" },
  );

/// Two messages went and a third goes out now, 11 seconds in. The Codex-style runs are off, so the
/// call in flight draws in the transcript (with them on, the live line names it).
const running = () =>
  chat(
    [
      user("Brief the three polish lanes.", 0.5),
      activity(
        [
          sendMessage(
            "Thread rail: left, fast, scrollable",
            "Keep the rail on the left; it scrolls with the transcript and never lags it.",
            "completed",
            11,
            3,
          ),
          sendMessage(
            "Composer menu timing",
            "Menus open on the click. Closing may fade; nothing fades in.",
            "completed",
            7,
            3,
          ),
          sendMessage(PICKER, BRIEFS[0]!, "in_progress", 3),
        ],
        0.2,
      ),
    ],
    { title: "Polish lane", isWorking: true },
  );

/// Opens the finished turn's "Worked for" line, where its calls are.
const openTurn: Play = async (ctx) => {
  await ctx.click({ selector: ".cv-worked.is-toggle" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-msggroup, .cv-message"));
};

/// Opens the turn, the group and its first message, pointed at so its Copy shows.
const openFirst: Play = async (ctx) => {
  await openTurn(ctx);
  if (ctx.document.querySelector(".cv-msggroup__line")) {
    await ctx.click({ selector: ".cv-msggroup__line" });
    await ctx.waitFor(() => ctx.document.querySelector(".cv-msggroup__entry"));
  }
  await ctx.click({ selector: ".cv-message .cv-agentmsg__toggle" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-agentmsg__card .cv-md"));
  await ctx.hover({ selector: ".cv-message .cv-agentmsg__line" });
};

const RUNNING =
  "Two messages went and a third is going out: the line reads Messaging <target> with the time since the first left, over the open card.";
const OPEN = "The finished group opened, its first message opened in place as text, Copy shown under the pointer.";

export default agentPaneEntry({
  id: "agent-pane.message-groups",
  title: "Message groups",
  area: "Agent pane",
  height: 560,
  covers: [
    "agent-session/acpmux/conversation/MessageGroupRow.tsx",
    "agent-session/acpmux/conversation/MessageGroupRow.css",
    "agent-session/acpmux/conversation/toolGroups.ts",
  ],
  variants: {
    running: { note: RUNNING, theme: { codexToolRuns: false }, snapshot: running() },
    done: {
      note: 'Once all went the group closes to one line: "Messaged <target> 3 times".',
      snapshot: finished(),
      play: openTurn,
    },
    "done-open": { note: OPEN, snapshot: finished(), play: openFirst },
    mixed: {
      note: 'Three messages to three agents: "Messaged 3 agents", opened.',
      snapshot: mixed(),
      play: async (ctx) => {
        await openTurn(ctx);
        await ctx.click({ selector: ".cv-msggroup__line" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-msggroup__entry"));
      },
    },
    "look-guide-running": {
      note: `Gallery version (theme messageGroupLook guide): the rows on the edit group's tree guide. ${RUNNING}`,
      theme: { codexToolRuns: false, messageGroupLook: "guide" },
      snapshot: running(),
    },
    "look-guide-open": {
      note: `Gallery version (theme messageGroupLook guide). ${OPEN}`,
      theme: { messageGroupLook: "guide" },
      snapshot: finished(),
      play: openFirst,
    },
    "look-list-running": {
      note: `Gallery version (theme messageGroupLook list): hairlines, no ring. ${RUNNING}`,
      theme: { codexToolRuns: false, messageGroupLook: "list" },
      snapshot: running(),
    },
    "look-list-open": {
      note: `Gallery version (theme messageGroupLook list). ${OPEN}`,
      theme: { messageGroupLook: "list" },
      snapshot: finished(),
      play: openFirst,
    },
    "before-running": {
      note: "Before (theme messageGroupLook off): each message its own row, the one in flight with the spinner.",
      theme: { codexToolRuns: false, messageGroupLook: "off" },
      snapshot: running(),
    },
    "before-open": {
      note: "Before (theme messageGroupLook off): three rows, the first opened.",
      theme: { messageGroupLook: "off" },
      snapshot: finished(),
      play: openFirst,
    },
  },
});
