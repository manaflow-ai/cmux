import { expect, test } from "bun:test";
import { MockAcpmuxSocket } from "./mock";
import { SUBAGENT_NAVIGATION_SESSION } from "./mockFixture";
import type { EventRecord } from "./direct";
import { SubagentFold } from "./subagents/subagentFold";
import { subagentFullName, subagentName, subagentTitle } from "./subagents/subagentNavigation";

test("independent mock pages retain completed subagents and each child's transcript", async () => {
  // Native side tabs create independent pages; no mutable state is shared with the source.
  for (let page = 0; page < 2; page += 1) {
    const socket = new MockAcpmuxSocket(() => Promise.resolve());
    try {
      const history = await new Promise<{ session: { sessionId: string }; events: EventRecord[] }>(
        (resolve, reject) => {
          socket.onmessage = ({ data }) => {
            const reply = JSON.parse(data);
            if (reply.id !== 1) return;
            if (reply.error) reject(new Error(reply.error.message));
            else resolve(reply.result);
          };
          socket.send(
            JSON.stringify({
              id: 1,
              method: "_acpmux/attach",
              params: { sessionId: SUBAGENT_NAVIGATION_SESSION },
            }),
          );
        },
      );
      expect(history.session.sessionId).toBe(SUBAGENT_NAVIGATION_SESSION);
      const fold = new SubagentFold();
      for (const event of history.events) {
        if (event.dir === "in" && event.msg.method === "session/update") fold.reduce(event, event.msg.params.update);
      }
      expect(fold.all().map((agent) => [agent.id, agent.state, subagentName(agent)])).toEqual([
        ["child-a", "completed", "Audit pane placement"],
        ["child-b", "completed", "Review tab reuse"],
      ]);
      expect(fold.views()["child-a"]?.map((row) => row.text)).toEqual(["The child chat stays beside its parent."]);
      expect(fold.views()["child-b"]?.map((row) => row.text)).toEqual([
        "Opening the same child selects its existing tab.",
      ]);
    } finally {
      socket.close();
    }
  }
});

test("a hidden transport id stays in the full name and the hover text", () => {
  const opaque = { id: "child-x", name: "0123abcd-4567/toolu_01", task: "Audit pane placement" } as Parameters<typeof subagentName>[0];
  expect(subagentName(opaque)).toBe("Audit pane placement");
  expect(subagentFullName(opaque)).toBe("Audit pane placement (0123abcd-4567/toolu_01)");
  expect(subagentTitle(opaque)).toBe("Audit pane placement (0123abcd-4567/toolu_01)");
  const unnamed = { id: "child-y", task: "Review tab reuse" } as Parameters<typeof subagentName>[0];
  expect(subagentFullName(unnamed)).toBe("Review tab reuse (child-y)");
  const named = { id: "child-z", name: "Reviewer", task: "Check it" } as Parameters<typeof subagentName>[0];
  expect(subagentFullName(named)).toBe("Reviewer");
  expect(subagentTitle(named)).toBe("Check it");
});
