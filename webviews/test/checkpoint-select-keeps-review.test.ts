// A chat switch selects the checkpoint client's new target (checkpoints/client.ts `select`). On a host
// with no checkpoints, the unsupported error from the capability read is the same for every target,
// so a select keeps it: the fields the pane draws (checkpoints/controller.tsx REVIEW_FIELDS) stay the
// same objects, and the pane does not draw again for them. It dropped the error on every select, a
// new review state each switch and a second sync render of the whole pane inside the switch's frame
// (bench/settled-page.bench.ts chat_switch). A supported client still starts each target clean.
import { expect, test } from "bun:test";
import { CheckpointClient } from "../src/agent-session/acpmux/checkpoints/client";

const memory = { get: async () => undefined, set: async () => {}, delete: async () => {} };
const target = (sessionId: string) => ({ cwd: "/repo", sessionId, hostKind: "local" as const });

test("an unsupported client keeps its error across chat switches", async () => {
  const client = new CheckpointClient(async () => ({}), {
    persistence: memory,
    capabilities: async () => {
      throw { code: "native.unsupported", origin: "native", message: "native.unsupported" };
    },
  });
  client.select(target("a"));
  expect(await client.refreshCapabilities()).toBe(false);
  const error = client.getSnapshot().error;
  expect(error?.code).toBe("native.unsupported");
  for (const id of ["b", "c", "a"]) {
    client.select(target(id));
    expect(client.getSnapshot().error).toBe(error!);
    expect(client.getSnapshot().target?.sessionId).toBe(id);
  }
});

test("a supported client starts each target with no error, list or record", async () => {
  const client = new CheckpointClient(async () => ({}), {
    persistence: memory,
    capabilities: async () => ({ checkpoints: true }) as never,
  });
  client.select(target("a"));
  await client.refreshCapabilities();
  client.state = { ...client.state, error: { code: "operation.failed" } as never };
  client.select(target("b"));
  expect(client.getSnapshot().error).toBeUndefined();
  expect(client.getSnapshot().list).toBeUndefined();
  expect(client.getSnapshot().record).toBeUndefined();
});
