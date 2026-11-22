// l10n-allow-file: gallery fixtures (sample prompts, agent names and errors), not shipped UI.
// The composer's queue after a failed turn. Leo, 2026-11-05, on "Paused after an error" over
// "[inbox] New messages from other agents in 3 threads...": "Why is the thing still queued? ... don't
// show these kinds of things. Don't have it work this kind of way." (reference
// cmux/live/composer-queued-inbox-paused-after-error). `before`: the hold as it drew; the others:
// acpmux lets what a failed turn held go in again by itself (hub/queue.rs `waits_for_resume`), the
// inbox notice draws with the waiting messages (conversation/queuedMessages.ts), and the note shows
// only once the person's own prompt has been let go as often as it may be.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";

const NOTICE =
  "[inbox] New messages from other agents in 3 threads. Read one whole with inbox_read (its thread id), answer in it with inbox_reply, or leave it for later.";

const threads = [
  {
    threadId: "pr:2210",
    label: "#2210",
    from: ["grid-lane"],
    count: 1,
    preview: "Review passed; landing it now.",
    blocker: false,
    promptIds: ["m-1"],
  },
  {
    threadId: "topic:rail",
    label: "rail",
    from: ["picker-lane"],
    count: 2,
    preview: "The rail's band now reaches the last tick.",
    blocker: false,
    promptIds: ["m-2", "m-3"],
  },
  {
    threadId: "from:review-box",
    label: "",
    from: ["review-box"],
    count: 1,
    preview: "SHIP at 9c41a07.",
    blocker: false,
    promptIds: ["m-4"],
  },
];

const ERROR = "agent process closed";

function failed(queue: AcpmuxSnapshot["queue"], paused: boolean): AcpmuxSnapshot {
  const base = chat([
    user("Land the polish PRs once their reviews pass.", 6),
    assistant("Checking the three reviews now.", 5),
    summary(5, { status: "failed", error: ERROR }),
  ]);
  return { ...base, summary: { ...base.summary!, status: "ready", queuePaused: paused }, queue };
}

const notice = { id: "inbox-notice-1", prompt: NOTICE };
const noticeDrawn = { ...notice, inbox: { threads } };
const mine = { id: "p-own", prompt: "Then rebase the picker stack onto feat-cmux-next." };

export default agentPaneEntry({
  id: "agent-pane.queue-after-error",
  title: "Queue after a failed turn",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/ComposerQueue.tsx", "agent-session/acpmux/conversation/queuedMessages.ts"],
  variants: {
    before: {
      note: "Before: a failed turn held acpmux's inbox notice as the person's queued prompt, under \"Paused after an error\", until Resume.",
      snapshot: failed([notice], true),
    },
    notice: {
      note: "The pick: the notice is no queue row and pauses nothing; it waits with the other agents' messages and goes in by itself after the retry wait.",
      snapshot: failed([noticeDrawn], false),
    },
    "own-retrying": {
      note: "The person's own prompt a failed turn held: no note, it goes in again by itself after the retry wait (up to 3 times).",
      snapshot: failed([noticeDrawn, mine], false),
    },
    "own-exhausted": {
      note: "Failed turns let the person's prompt go 3 times: only then does the queue say it paused, with Resume.",
      snapshot: failed([noticeDrawn, mine], true),
    },
  },
});
