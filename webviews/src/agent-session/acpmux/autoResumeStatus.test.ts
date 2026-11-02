import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";
import { autoResumeAttempt } from "./autoResumeStatus";

type Feed = {
  emit: (target: string, step: unknown, at?: number) => void;
  touch: (target: string, fields: Record<string, unknown>, moved?: boolean) => void;
  record: (target: string, step: unknown, at?: number) => void;
};

const settle = async (check: () => boolean) => {
  const deadline = performance.now() + 2_000;
  while (!check()) {
    if (performance.now() > deadline) throw new Error("timed out waiting for auto-resume snapshot");
    await new Promise<void>((resolve) => setTimeout(resolve, 0));
  }
};

async function connect(seedAttempt?: number) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const feed = socket as unknown as Feed;
  const target = mockHost.sessionId!;
  if (seedAttempt !== undefined) {
    feed.record(target, {
      mux: "user_message",
      msg: {
        promptId: "p-auto",
        text: "continue",
        _meta: { provenance: { kind: "auto_resume", promptId: "p-root", attempt: seedAttempt, turnId: "t-root" } },
      },
    });
  }
  let shown: AcpmuxSnapshot | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      shown = snapshot;
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  await settle(() => shown?.summary?.sessionId === target);
  return {
    client,
    feed,
    target,
    snapshot: () => shown,
    close: () => client.close?.(),
  };
}

test("derives automatic resume attempts while excluding manual and subagent retries", () => {
  expect(autoResumeAttempt({ _meta: { provenance: { kind: "auto_resume", attempt: 2 } } })).toBe(2);
  expect(
    autoResumeAttempt({ _meta: { provenance: { kind: "auto_resume", attempt: 2, manual: true } } }),
  ).toBeUndefined();
  expect(autoResumeAttempt({ _meta: { provenance: { kind: "subagent_retry", attempt: 2 } } })).toBeUndefined();
  expect(autoResumeAttempt({ _meta: { provenance: { kind: "auto_resume", attempt: 0 } } })).toBeUndefined();
});

test("replayed and live session changes expose local auto-resume state, then clear on the next prompt", async () => {
  const io = await connect(2);
  try {
    await settle(() => io.snapshot()?.autoResume?.attempt === 2);
    expect(io.snapshot()?.autoResume).toEqual({ attempt: 2 });

    io.feed.touch(
      io.target,
      {
        retry: {
          attempt: 1,
          of: 4,
          reason: "capacity",
          nextAt: Date.now() + 60_000,
          promptId: "p-root",
          turnId: "t-root",
        },
      },
      false,
    );
    await settle(() => io.snapshot()?.autoResume?.retry?.reason === "capacity");
    expect(io.snapshot()?.autoResume?.attempt).toBe(2);
    expect(io.snapshot()?.autoResume?.retry).toMatchObject({ attempt: 1, of: 4, reason: "capacity" });

    io.feed.touch(io.target, { retry: null }, false);
    await settle(() => io.snapshot()?.autoResume?.retry === undefined);
    expect(io.snapshot()?.autoResume).toEqual({ attempt: 2 });

    io.feed.emit(io.target, {
      mux: "user_message",
      msg: { promptId: "p-next", text: "start the next task" },
    });
    await settle(() => io.snapshot()?.autoResume === undefined);
    expect(io.snapshot()?.autoResume).toBeUndefined();
  } finally {
    io.close();
  }
});

test("keeps the same resume status for a cloud session summary", async () => {
  const io = await connect();
  try {
    io.feed.touch(io.target, { host: "cloud-vm", hostKind: "cloud" }, false);
    io.feed.emit(io.target, {
      mux: "user_message",
      msg: {
        promptId: "p-cloud-resume",
        text: "continue",
        _meta: { provenance: { kind: "auto_resume", promptId: "p-cloud", attempt: 1, turnId: "t-cloud" } },
      },
    });
    await settle(() => io.snapshot()?.autoResume?.attempt === 1);
    expect(io.snapshot()?.summary?.hostKind).toBe("cloud");
    expect(io.snapshot()?.autoResume).toEqual({ attempt: 1 });
  } finally {
    io.close();
  }
});
