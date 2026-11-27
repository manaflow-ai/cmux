// l10n-allow-file: gallery fixtures (subagent names and errors), not shipped UI.
// cmux#52916 (https://github.com/manaflow-ai/cmux/issues/52916): after a daemon restart, a chat drew
// two "Subagent  Failed  ›" lines under a reply: 0s, no task, no reason, a bordered pill on hover
// and a "Failed · 0s" tooltip over the row above. The production fold reads the records here as
// acpmux writes them: two subagents that failed live (one short reason, one long one that is cut),
// then the restart's settle entries, one for each of them and two for subagents whose spawn this
// window never read. The settles of the unread ones draw nothing; the live failures keep their
// lines, named, with their reasons, next to an ordinary tool row for the hover comparison.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SubagentFold } from "./subagentFold";

const CHAT = "gallery-session";
const PUSH = `${CHAT}/toolu_push_relay`;
const AUDIT = `${CHAT}/toolu_audit_banner`;
const UNREAD = [`${CHAT}/toolu_unread_one`, `${CHAT}/toolu_unread_two`];
const SHORT_ERROR = "Agent terminated early due to an API error. The request timed out after 600s.";
const LONG_ERROR =
  "API Error: 529 Overloaded. The upstream model provider is temporarily overloaded; this subagent stopped after its third attempt and its partial work was discarded.";

function snapshot(restart: boolean) {
  const fold = new SubagentFold();
  fold.harness = "claude";
  let seq = 0;
  const feed = (
    minutes: number,
    sessionUpdate: string,
    subagents: Record<string, unknown>[],
    extra: Record<string, unknown> = {},
  ) => {
    const update = { sessionUpdate };
    fold.reduce(
      {
        seq: ++seq,
        at: minutesAgo(minutes),
        msg: { method: "session/update", ...extra, params: { update, _meta: { acpmux: { subagents } } } },
      },
      update,
    );
  };
  const spawn = (id: string, name: string, minutes: number) =>
    feed(minutes, "subagent_spawned", [
      { id, parent: null, name, kind: "general-purpose", prompt: name, state: "running", background: true },
    ]);
  const fail = (id: string, agentId: string, error: string, minutes: number) =>
    feed(minutes, "subagent_state_update", [
      { id, parent: null, agentId, state: "failed", error, retryable: false, retry: null, retryInFlight: null },
    ]);
  spawn(PUSH, "Push relay health check", 6);
  spawn(AUDIT, "Audit the retry banner flicker", 5.9);
  fail(PUSH, "a1c94e6b50cb40c7c", SHORT_ERROR, 4.8);
  fail(AUDIT, "add483bc55fb3da4d", LONG_ERROR, 4.2);
  if (restart) {
    const settle = (id: string, agentId: string) => ({
      id,
      parent: null,
      state: "failed",
      agentId,
      retry: null,
      retryInFlight: null,
      retryable: false,
    });
    // The settles of the two read above, then of two whose spawns are on a page this window never read.
    feed(1, "subagent_state_update", [settle(PUSH, "a1c94e6b50cb40c7c")], { _acpmuxRecovery: true });
    feed(1, "subagent_state_update", [settle(AUDIT, "add483bc55fb3da4d")], { _acpmuxRecovery: true });
    feed(1, "subagent_state_update", [settle(UNREAD[0]!, "a0000000000000001")], { _acpmuxRecovery: true });
    feed(1, "subagent_state_update", [settle(UNREAD[1]!, "a0000000000000002")], { _acpmuxRecovery: true });
  }
  return chat([
    user("Check the push relay and audit the retry banner in parallel.", 6.2),
    ...fold.takeRows(),
    activity(
      [
        tool("git status --short", "execute", "completed", {
          command: "git status --short",
          output: " M src/banner.ts",
          startedAt: minutesAgo(4),
          endedAt: minutesAgo(3.9),
        }),
      ],
      4,
    ),
    assistant("Both subagents failed before they finished; the reasons are on their lines.", 3.8),
  ]);
}

export default agentPaneEntry({
  id: "agent-pane.subagent-failed-rows",
  title: "Failed subagent rows",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/subagents/SubagentDoneLine.tsx#SubagentDoneLine"],
  variants: {
    "after-restart": {
      note: "Two live failures keep their named lines; the restart's settles of unread subagents draw nothing.",
      snapshot: snapshot(true),
    },
    live: {
      note: "The same two failures with no restart.",
      snapshot: snapshot(false),
    },
  },
});
