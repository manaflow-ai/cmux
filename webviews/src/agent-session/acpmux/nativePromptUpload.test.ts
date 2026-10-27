import { expect, test } from "bun:test";
import { createNativePromptUploadTransport } from "./nativePromptUpload";

test("native upload control waits for event readiness and terminal status, without binding bytes", async () => {
  let subscribe!: () => void;
  const ready = new Promise<void>((resolve) => (subscribe = resolve));
  const calls: { op: string; params: Record<string, unknown> }[] = [];
  const transport = createNativePromptUploadTransport(async <T>(op, params): Promise<T> => {
    calls.push({ op, params });
    return { token: "token", uploadId: "id", state: "finished", size: 3 } as T;
  }, () => ready);
  const result = transport.beginBlob({
    token: "token", fileName: "one.png", mimeType: "image/png", size: 3,
    sessionId: "session", promptId: "prompt", ticket: "ticket",
  });
  await Promise.resolve();
  expect(calls).toHaveLength(0);
  subscribe();
  expect(await result).toEqual({ uploadId: "id", size: 3, offset: 3 });
  expect(calls).toEqual([
    { op: "cmux.agent.uploads.begin", params: {
      token: "token", name: "one.png", type: "image/png", size: 3,
      sessionId: "session", promptId: "prompt", ticket: "ticket",
    } },
    { op: "cmux.agent.uploads.status", params: { token: "token" } },
  ]);
});

test("explicit cancellation settles even when the host sends no terminal event", async () => {
  const calls: string[] = [];
  const transport = createNativePromptUploadTransport(async <T>(op): Promise<T> => {
    calls.push(op);
    if (op.endsWith(".begin")) return new Promise<T>(() => {});
    return {} as T;
  });
  const result = transport.beginBlob({
    token: "cancel", fileName: "one.png", mimeType: "image/png", size: 3,
    sessionId: "session", promptId: "prompt", ticket: "ticket",
  });
  await transport.cancelBlob!("cancel");
  await expect(result).rejects.toMatchObject({ code: "upload.cancelled" });
  expect(calls.at(-1)).toBe("cmux.agent.uploads.cancel");
});
