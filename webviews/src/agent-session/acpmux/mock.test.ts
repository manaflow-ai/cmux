import { describe, expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { mockReply, startMockHost } from "./mock";

describe("mock transport", () => {
  test("publishes a welcome snapshot and answers a prompt without a daemon", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const pending: (() => void)[] = [];
    const actions = startMockHost((snapshot) => snapshots.push(snapshot), (run) => pending.push(run));
    expect(snapshots[0]?.connection).toBe("mock");
    expect(snapshots[0]?.rows.length).toBe(1);

    await actions["chat.send"]!({ text: "hello" });
    expect(snapshots.at(-1)?.isWorking).toBe(true);
    expect(snapshots.at(-1)?.rows.at(-1)).toMatchObject({ kind: "user", text: "hello" });

    pending.shift()!();
    expect(snapshots.at(-1)?.isWorking).toBe(false);
    expect(snapshots.at(-1)?.rows.at(-1)).toMatchObject({ kind: "assistant", text: mockReply("hello") });
  });

  test("new session clears the transcript", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const actions = startMockHost((snapshot) => snapshots.push(snapshot), () => undefined);
    await actions["chat.new"]!({});
    expect(snapshots.at(-1)?.rows).toEqual([]);
  });
});
