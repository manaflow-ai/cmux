// l10n-allow-file: test fixture subagent names and text, not shipped UI.
// A subagent's own view never shows a tool call's raw id (Leo's view of "Fix merge hook" opened on
// a row reading "toolu_01RqigDE1xKq7LfoCN2m0Wop"). Its first record can be an update to a call
// whose start it never saw, with no title: a row of nothing but the id. And the Agent call that
// spawned it is the parent's, not a step of its own.
import { expect, test } from "bun:test";
import { SubagentFold } from "../src/agent-session/acpmux/subagents/subagentFold";

const update = (update: Record<string, unknown>, acpmux: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update, _meta: { acpmux } },
});
let seq = 0;
const feed = (fold: SubagentFold, msg: ReturnType<typeof update>) => {
  seq += 1;
  fold.reduce({ seq, at: 1_000 * seq, msg }, msg.params.update);
};
/// Every text the view's rows show: their text, and each tool item's text and title.
const shown = (fold: SubagentFold, id: string) =>
  (fold.views()[id] ?? []).flatMap((row) => [
    row.text ?? "",
    ...(row.items ?? []).flatMap((item) => [item.text ?? "", item.tool?.title ?? ""]),
  ]);

test("a subagent's view shows no raw tool call id, and not the call that spawned it", () => {
  const fold = new SubagentFold();
  const sub = { subagent: "acp-1/toolu_spawn" };
  feed(
    fold,
    update(
      { sessionUpdate: "subagent_spawned" },
      {
        subagents: [
          {
            id: "acp-1/toolu_spawn",
            parent: null,
            name: "Fix merge hook",
            state: "running",
            toolCallId: "toolu_spawn",
          },
        ],
      },
    ),
  );
  // An update to a call whose start this view never saw, with no title.
  feed(
    fold,
    update(
      { sessionUpdate: "tool_call_update", toolCallId: "toolu_01RqigDE1xKq7LfoCN2m0Wop", status: "completed" },
      sub,
    ),
  );
  // The spawning Agent call's own progress, tagged with the subagent.
  feed(fold, update({ sessionUpdate: "tool_call_update", toolCallId: "toolu_spawn", status: "in_progress" }, sub));
  feed(
    fold,
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Checking the hook." } }, sub),
  );
  feed(
    fold,
    update(
      {
        sessionUpdate: "tool_call",
        toolCallId: "toolu_read",
        title: "Read hook.sh",
        kind: "read",
        status: "completed",
      },
      sub,
    ),
  );
  const texts = shown(fold, "acp-1/toolu_spawn").filter(Boolean);
  expect(texts.filter((text) => text.startsWith("toolu_"))).toEqual([]);
  expect(texts).toContain("Checking the hook.");
  expect(texts).toContain("Read hook.sh");
});
