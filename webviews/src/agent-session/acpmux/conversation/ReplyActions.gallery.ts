// l10n-allow-file: gallery fixtures (sample replies, lane names and messages), not shipped UI.
// A reply keeps its own action row (MessageActions.tsx ReplyActions: Copy, Pin, Read aloud, More
// and its age) when a steer, another agent's message or a sent message follows it, as Claude
// desktop draws under every reply (Leo, 2026-10-29: "i feel like im frequently missing the
// copy/whatever buttons on these steers... but claude code allows those buttons in these
// situations. let's have those"). Each variant points at that reply, so the row shows; before the
// change it drew none. The turn's answer keeps its footer as its row.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const ACCESS =
  "I gave team access to the cloud-idle helper, which already knows our Freestyle setup. The goal is that anyone on the team can see, open, resume, fork and snapshot the team's Freestyle VMs, not only whoever created them.";
const REVIEW =
  "The review of the Stop fix is still running and has no verdict yet. I told the lane it doesn't need to keep asking; it gets the merge SHA once the review says SHIP.";
const LANE_ASK =
  "Still no merge SHA; the PR remains open at 6982674e. Please report whether the review has posted SHIP.";

const send = (target: string, text: string, status = "completed") =>
  tool(`acpmux send --no-wait ${target} '${text}'`, "execute", status, {
    command: `acpmux send --no-wait ${target} '${text}'`,
    description: `Tell ${target}`,
    output: "queued",
  });

/// Points at the reply `id`, whose row shows while it is pointed at.
const pointAt =
  (id: string): Play =>
  async (ctx) => {
    await ctx.hover({ selector: `[data-row-id="${id}"]` });
    await ctx.waitFor(() => ctx.document.querySelector(`[data-row-id="${id}"] .cv-reply-actions`));
  };

const afterSteer = () =>
  chat(
    [
      user("Give the team access to the helper and write the design.", 6),
      assistant(ACCESS, 5.5, { id: "reply-steer" }),
      user("Also check Lawrence's open work first.", 5, { steer: "landed" }),
      activity([tool("gh pr list --author lawrencecchen", "execute", "completed", { command: "gh pr list" })], 4.8),
      assistant(REVIEW, 4.5),
      summary(4.5, { status: "completed", toolCount: 1 }),
    ],
    { title: "cloud-idle" },
  );

const afterIncoming = () =>
  chat(
    [
      user("Give the team access to the helper and write the design.", 6),
      assistant(ACCESS, 5.5, { id: "reply-incoming" }),
      user(LANE_ASK, 5, {
        untyped: true,
        incoming: {
          kind: "message",
          message: { name: "gcp-codex-lane-12/hb-stop-compact", sessionId: "lane-12", text: LANE_ASK, raw: LANE_ASK },
        },
      }),
      assistant(REVIEW, 4.5),
      summary(4.5, { status: "completed" }),
    ],
    { title: "cloud-idle" },
  );

const afterSent = () =>
  chat(
    [
      user("Give the team access to the helper, then tell the lane.", 3),
      assistant(ACCESS, 2.5, { id: "reply-sent" }),
      activity([send("cloud-idle", "From claude-sr2, a new task for you.")], 2),
      activity([tool("gh pr view 27170", "execute", "in_progress", { command: "gh pr view 27170" })], 1.5),
    ],
    { title: "cloud-idle", isWorking: true },
  );

export default agentPaneEntry({
  id: "agent-pane.reply-actions",
  title: "Reply action rows",
  area: "Agent pane",
  height: 560,
  covers: [
    "agent-session/acpmux/conversation/MessageActions.tsx",
    "agent-session/acpmux/conversation/PendingSteer.tsx",
  ],
  variants: {
    "after-steer": {
      note: "A reply followed by the person's steer, with the finished turn's Worked for opened and the reply pointed at: its Copy, Pin, Read aloud row and age under it. The turn's answer keeps its footer.",
      snapshot: afterSteer(),
      // A finished turn folds everything before its closing answer, this reply and the steer included.
      play: async (ctx) => {
        await ctx.click({ selector: ".cv-worked.is-toggle" });
        await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="reply-steer"]'));
        await pointAt("reply-steer")(ctx);
      },
    },
    "after-incoming": {
      note: "A reply followed by another agent's message, pointed at: its own row, as Claude desktop draws over “Received message from”.",
      snapshot: afterIncoming(),
      play: pointAt("reply-incoming"),
    },
    "after-sent": {
      note: "In a running turn, a reply followed by a “Sent message to” row, pointed at: its own row while the turn goes on.",
      snapshot: afterSent(),
      play: pointAt("reply-sent"),
    },
    "steer-waiting": {
      note: "A steer the agent has not read yet, pointed at: Copy beside Send now and the X.",
      snapshot: chat(
        [
          user("Give the team access to the helper.", 3),
          assistant(ACCESS, 2.5),
          activity([tool("gh pr view 27170", "execute", "in_progress", { command: "gh pr view 27170" })], 2),
          user("Also check Lawrence's open work first.", 1, {
            id: "steer-waiting",
            steer: "waiting",
            steerPromptId: "p-gallery-steer",
          }),
        ],
        { title: "cloud-idle", isWorking: true },
      ),
      play: async (ctx) => {
        await ctx.hover({ selector: '[data-row-id="steer-waiting"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[data-row-id="steer-waiting"] .cv-user__pending'));
      },
    },
  },
});
