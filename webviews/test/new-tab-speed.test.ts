import { expect, test } from "bun:test";
import { pendingSpeed } from "../src/agent-session/acpmux/pendingSpeed";
import { noChat } from "../src/gallery/fixtures/acpmux";

test("new-tab speed controls use both advertised tiers before a session exists", () => {
  const snapshot = noChat();
  snapshot.summary = { sessionId: "", harness: "codex", model: "m" };
  snapshot.catalog = [
    {
      id: "codex",
      name: "Codex",
      models: [
        {
          id: "m",
          serviceTiers: [
            { id: "priority", name: "Fast" },
            { id: "ultrafast", name: "Ultrafast" },
          ],
        },
      ],
    },
  ];
  expect(pendingSpeed(snapshot)?.options.map((option) => option.value)).toEqual(["default", "priority", "ultrafast"]);
  snapshot.catalog[0]!.models[0]!.serviceTiers = undefined;
  expect(pendingSpeed(snapshot)).toBeUndefined();
});
