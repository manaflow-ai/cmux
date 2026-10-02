import { describe, expect, test } from "bun:test";
import { AcpmuxDirectClient } from "./direct";
import { MockAcpmuxSocket, mockHost, mockReply } from "./mock";
import type { AcpmuxSnapshot } from "./model";

describe("mock transport", () => {
  /// Mock mode runs the real client against the in-page daemon, so a mock turn goes through the
  /// same event folding as an agent's.
  test("a prompt streams a scripted turn through the real client", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    (globalThis as any).window ??= globalThis;
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => snapshots.push(snapshot),
      undefined,
      () => new MockAcpmuxSocket(() => Promise.resolve()) as unknown as WebSocket,
    );
    client.snapshot();
    expect(snapshots.at(-1)?.rows.map((row) => row.kind)).toEqual(["assistant"]);
    expect(snapshots.at(-1)?.summary?.harness).toBe("claude");
    expect(snapshots.at(-1)?.commands?.map((command) => command.name)).toContain("compact");
    expect((await client.harnesses()).map((harness) => harness.id)).toEqual(["claude", "codex"]);

    await client.send("hello");
    for (let tries = 0; tries < 20 && !snapshots.at(-1)?.rows.some((row) => row.kind === "turnSummary"); tries += 1)
      await new Promise((resolve) => setTimeout(resolve, 0));
    const rows = snapshots.at(-1)!.rows;
    expect(snapshots.at(-1)?.isWorking).toBe(false);
    expect(rows.find((row) => row.kind === "user")?.text).toBe("hello");
    expect(rows.filter((row) => row.kind === "assistant").at(-1)?.text).toContain(mockReply("hello"));
    // The turn edits files, so it has changes to review.
    const diffs = rows.flatMap((row) => row.items ?? []).flatMap((item) => item.tool?.diffs ?? []);
    expect(diffs.map((diff) => diff.path)).toEqual(["/mock/project/src/greeting.ts", "/mock/project/NOTES.md"]);
    // The reply splits around its tool calls, and the summary counts all three.
    expect(rows.map((row) => row.kind)).toEqual([
      "assistant",
      "user",
      "assistant",
      "activity",
      "assistant",
      "activity",
      "assistant",
      "turnSummary",
    ]);
    expect(rows.find((row) => row.kind === "turnSummary")?.toolCount).toBe(3);
    client.close();
  });

  test("a prompt sent during a turn shows in the queue until it starts", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    (globalThis as any).window ??= globalThis;
    const waiting: (() => void)[] = [];
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => snapshots.push(snapshot),
      undefined,
      () => new MockAcpmuxSocket(() => new Promise<void>((resolve) => waiting.push(resolve))) as unknown as WebSocket,
    );
    const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
    void client.send("first");
    void client.send("second");
    for (let tries = 0; tries < 20 && !snapshots.at(-1)?.queue.length; tries += 1) await tick();
    expect(snapshots.at(-1)?.queue.map((entry) => entry.prompt)).toEqual(["second"]);
    // Let every step of both turns through.
    for (
      let tries = 0;
      tries < 200 && snapshots.at(-1)?.rows.filter((row) => row.kind === "turnSummary").length !== 2;
      tries += 1
    ) {
      waiting.splice(0).forEach((resolve) => resolve());
      await tick();
    }
    expect(snapshots.at(-1)?.queue).toEqual([]);
    expect(
      snapshots
        .at(-1)
        ?.rows.filter((row) => row.kind === "user")
        .map((row) => row.text),
    ).toEqual(["first", "second"]);
    client.close();
  });

  test("closing the daemon stops a queued prompt too", async () => {
    let steps = 0;
    const waiting: (() => void)[] = [];
    const socket = new MockAcpmuxSocket(() => {
      steps += 1;
      return new Promise<void>((resolve) => waiting.push(resolve));
    });
    const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
    await tick();
    const prompt = (id: number) =>
      socket.send(
        JSON.stringify({
          jsonrpc: "2.0",
          id,
          method: "session/prompt",
          params: { sessionId: mockHost.sessionId, prompt: [{ type: "text", text: `p${id}` }] },
        }),
      );
    prompt(1);
    prompt(2);
    await tick();
    expect(steps).toBe(1);
    socket.close();
    for (let round = 0; round < 5; round += 1) {
      while (waiting.length) waiting.shift()!();
      await tick();
    }
    expect(steps).toBe(1);
  });

  const connectMock = async (
    snapshots: AcpmuxSnapshot[],
    delay: (ms: number) => Promise<void> = () => Promise.resolve(),
  ) => {
    (globalThis as any).window ??= globalThis;
    return AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => snapshots.push(snapshot),
      undefined,
      () => new MockAcpmuxSocket(delay) as unknown as WebSocket,
    );
  };
  const until = async (done: () => boolean) => {
    for (let tries = 0; tries < 50 && !done(); tries += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  };

  test("Stop ends the scripted turn as cancelled", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    let release: () => void = () => {};
    const client = await connectMock(
      snapshots,
      () =>
        new Promise<void>((resolve) => {
          release = resolve;
        }),
    );
    const sent = client.send("hello");
    await until(() => snapshots.at(-1)?.isWorking === true);
    await client.cancel();
    release();
    await sent;
    await until(() => snapshots.at(-1)?.rows.some((row) => row.kind === "turnSummary") === true);
    expect(snapshots.at(-1)?.rows.find((row) => row.kind === "turnSummary")?.status).toBe("cancelled");
    expect(snapshots.at(-1)?.isWorking).toBe(false);
    client.close();
  });

  test("a new chat is a session of its own with an empty transcript", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    const client = await connectMock(snapshots);
    const created = await client.create();
    client.snapshot();
    expect(created).not.toBe(mockHost.sessionId);
    expect(snapshots.at(-1)?.sessionId).toBe(created);
    expect(snapshots.at(-1)?.rows).toEqual([]);
    expect(snapshots.at(-1)?.sessions.map((entry) => entry.sessionId)).toContain(created);
    client.close();
  });

  test("a recorded turn replays with its own timestamps and no greeting", async () => {
    const snapshots: AcpmuxSnapshot[] = [];
    (globalThis as any).window ??= globalThis;
    const script = {
      steps: [
        {
          atMs: 2_000,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Recorded answer." } },
        },
      ],
      endAtMs: 15_000,
    };
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => snapshots.push(snapshot),
      undefined,
      () => new MockAcpmuxSocket(() => Promise.resolve(), script) as unknown as WebSocket,
    );
    client.snapshot();
    expect(snapshots.at(-1)?.rows).toEqual([]);
    await client.send("replay");
    await until(() => snapshots.at(-1)?.rows.some((row) => row.kind === "turnSummary") === true);
    const rows = snapshots.at(-1)!.rows;
    expect(rows.filter((row) => row.kind === "assistant").map((row) => row.text)).toEqual(["Recorded answer."]);
    const user = rows.find((row) => row.kind === "user")!;
    expect(rows.find((row) => row.kind === "assistant")!.at - user.at).toBeGreaterThanOrEqual(2_000);
    expect(rows.find((row) => row.kind === "turnSummary")!.at - user.at).toBeGreaterThanOrEqual(15_000);
    client.close();
  });
});
