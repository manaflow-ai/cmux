import { expect, test } from "bun:test";
import { createNativePromptUploadTransport } from "./nativePromptUpload";

test("native upload control waits for event readiness and terminal status, without binding bytes", async () => {
  let subscribe!: () => void;
  const ready = new Promise<void>((resolve) => (subscribe = resolve));
  const calls: { op: string; params: Record<string, unknown> }[] = [];
  const transport = createNativePromptUploadTransport(
    async <T>(op, params): Promise<T> => {
      calls.push({ op, params });
      return { token: "token", uploadId: "id", state: "finished", size: 3 } as T;
    },
    () => ready,
  );
  const result = transport.beginBlob({
    token: "token",
    fileName: "one.png",
    mimeType: "image/png",
    size: 3,
    sessionId: "session",
    promptId: "prompt",
    ticket: "ticket",
  });
  await Promise.resolve();
  expect(calls).toHaveLength(0);
  subscribe();
  expect(await result).toEqual({ uploadId: "id", size: 3, offset: 3 });
  expect(calls).toEqual([
    {
      op: "cmux.agent.uploads.begin",
      params: {
        token: "token",
        name: "one.png",
        type: "image/png",
        size: 3,
        sessionId: "session",
        promptId: "prompt",
        ticket: "ticket",
      },
    },
    { op: "cmux.agent.uploads.status", params: { token: "token" } },
  ]);
});

test("explicit cancellation settles even when the host sends no terminal event", async () => {
  const calls: string[] = [];
  const transport = createNativePromptUploadTransport(
    async <T>(op): Promise<T> => {
      calls.push(op);
      if (op.endsWith(".begin")) return new Promise<T>(() => {});
      return {} as T;
    },
    async () => {},
  );
  const result = transport.beginBlob({
    token: "cancel",
    fileName: "one.png",
    mimeType: "image/png",
    size: 3,
    sessionId: "session",
    promptId: "prompt",
    ticket: "ticket",
  });
  await transport.cancelBlob!("cancel");
  await expect(result).rejects.toMatchObject({ code: "upload.cancelled" });
  expect(calls.at(-1)).toBe("cmux.agent.uploads.cancel");
});

test("legacy hosts never receive a raw uploads binding call", async () => {
  const transport = createNativePromptUploadTransport();
  await expect(
    transport.gesture!({
      method: "session/prompt",
      params: { promptId: "prompt", sessionId: "session" },
    }),
  ).rejects.toThrow("Native prompt uploads are unavailable");
});

test("the shared PageClient uses call envelopes and preserves typed native errors", async () => {
  const scope = globalThis as Record<string, unknown>;
  const previous = scope.webkit;
  const calls: any[] = [];
  let refuse = false;
  scope.webkit = {
    messageHandlers: {
      cmuxPage: {
        async postMessage(message: any) {
          calls.push(message);
          const value =
            message.t === "sub"
              ? { sub: 1 }
              : message.op.endsWith(".gesture")
                ? { ticket: "ticket" }
                : message.op.endsWith(".status")
                  ? { token: "envelope", state: "finished", uploadId: "id", size: 3 }
                  : { uploadId: "id" };
          return refuse && message.op?.endsWith(".begin")
            ? { t: "err", id: message.id, code: "gesture_required", message: "Send again" }
            : { t: "ok", id: message.id, value };
        },
      },
    },
  };
  try {
    const transport = createNativePromptUploadTransport();
    const ticket = await transport.gesture!({
      method: "session/prompt",
      params: { sessionId: "session", promptId: "prompt" },
    });
    const params = {
      token: "envelope",
      fileName: "one.png",
      mimeType: "image/png",
      size: 3,
      sessionId: "session",
      promptId: "prompt",
      ticket,
    };
    await transport.beginBlob(params);
    expect(calls.filter((call) => call.t === "call").map((call) => call.op)).toEqual([
      "cmux.agent.transport.gesture",
      "cmux.agent.uploads.begin",
      "cmux.agent.uploads.status",
    ]);
    expect(calls.find((call) => call.op === "cmux.agent.uploads.begin")).toMatchObject({
      t: "call",
      id: expect.any(Number),
      params: { token: "envelope", name: "one.png", ticket: "ticket" },
    });
    refuse = true;
    await expect(transport.beginBlob(params)).rejects.toMatchObject({
      code: "gesture_required",
      message: "Send again",
    });
  } finally {
    if (previous === undefined) delete scope.webkit;
    else scope.webkit = previous;
  }
});
