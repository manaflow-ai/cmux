// l10n-allow-file: gallery fixtures (sample prompts, file names, replies and agent names), not shipped UI.
// The edited-files card under "Subagent finished" and under a reply (Lucas, 2026-11-08, on a card
// that touched the "Subagent finished" line above it while a reply's card had room). The card is a
// card, not a line: it stands the run gap from the line or the prose over it (transcriptGrid.ts
// MARK_CARD). The finished line has a report: a click on the line opens it, the name opens the agent.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Subagent } from "./subagentFold";

const REVIEW = `# Review of #11

No blocking problems. Two notes for later.
`;

const subagent: Subagent = {
  id: "changes-agent",
  parent: null,
  name: "Review",
  task: "Review codex-acp fix PR",
  state: "completed",
  startedAt: minutesAgo(9),
  endedAt: minutesAgo(3.5),
  prompt: "Review the codex-acp fix PR",
  result: "The background review found no blocking problems. I made no code change.",
};

const edit = (minutes: number, path: string, id: string) =>
  activity([tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path, oldText: "", newText: REVIEW }] })], minutes, {
    id,
  });

export default agentPaneEntry({
  id: "agent-pane.subagent-changes",
  title: "Edited files under Subagent finished",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/transcriptGrid.ts#transcriptGap", "agent-session/acpmux/model.ts#isEditCard"],
  variants: {
    "subagent-finished": {
      note: 'A running turn: the card under "Subagent finished" stands the run gap from it, as under a reply (before: flush, 0).',
      snapshot: chat([
        user("Review the codex-acp fix PR in the background", 10, { id: "changes-prompt" }),
        {
          id: "subagentDone:changes-agent",
          version: 1,
          kind: "subagentDone",
          at: subagent.endedAt!,
          subagents: [subagent],
        },
        edit(3.4, "2026-11-03-codex-acp-11-review.md", "changes-subagent-edit"),
        assistant("The background review of PR #11 found no blocking problems. I made no code change.", 3.3, {
          id: "changes-reply",
        }),
      ]),
    },
    "reply-then-changes": {
      note: "The card under a reply's prose: the run gap the card takes everywhere.",
      snapshot: chat([
        user("Fix the sign-in failure", 10, { id: "changes-reply-prompt" }),
        assistant("Until a Nightly has the fix, Codex chats with a ChatGPT sign-in will keep failing.", 5, {
          id: "changes-reply-prose",
        }),
        edit(4.9, "sandbox_tests.rs", "changes-reply-edit"),
        summary(4.9, { id: "changes-reply-footer", status: "completed", durationMs: 60_000 }),
      ]),
    },
  },
});
