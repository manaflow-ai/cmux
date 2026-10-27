import { expect, test } from "bun:test";
import { MockAcpmuxSocket } from "./mock";
import { SUBAGENT_NAVIGATION_SESSION } from "./mockFixture";
import type { EventRecord } from "./direct";
import { SubagentFold } from "./subagents/subagentFold";
import { subagentName } from "./subagents/subagentNavigation";

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
