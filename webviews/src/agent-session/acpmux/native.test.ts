import { afterEach, describe, expect, test } from "bun:test";
import { postNative } from "./native";

/// Fakes Swift's `agentSession` handler with one reply for every request.
function answerWith(reply: unknown) {
  (globalThis as any).window ??= globalThis;
  (globalThis as any).webkit = {
    messageHandlers: { agentSession: { postMessage: () => Promise.resolve(reply) } },
  };
}

async function rejection(promise: Promise<unknown>): Promise<any> {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error("expected the request to reject");
}

const fields = (error: any) => ({
  name: error.name,
  message: error.message,
  code: error.code,
  details: error.details,
  retryable: error.retryable,
  origin: error.origin,
});

describe("postNative", () => {
  afterEach(() => {
    delete (globalThis as any).webkit;
  });

  test("resolves with the host's value", async () => {
    answerWith({ ok: true, value: { root: "/repo" } });
    expect(await postNative<unknown>("git.status", { cwd: "/repo" })).toEqual({ root: "/repo" });
  });

  test("a session host error reaches the caller with its code, details and retryable", async () => {
    answerWith({
      ok: false,
      error: {
        code: "operation.failed",
        userMessage: "The changes could not be read.",
        details: { stderr: "fatal: not a git repository", exit_code: 128 },
        retryable: false,
        origin: "session_host",
      },
    });
    const error = await rejection(postNative("git.diff", { cwd: "/repo", scope: "staged" }));
    expect(error).toBeInstanceOf(Error);
    expect(fields(error)).toEqual({
      name: "NativeError",
      message: "The changes could not be read.",
      code: "operation.failed",
      details: { stderr: "fatal: not a git repository", exit_code: 128 },
      retryable: false,
      origin: "session_host",
    });
  });

  test("a native error reaches the caller with its code and no details", async () => {
    answerWith({
      ok: false,
      error: { code: "native.timed_out", userMessage: "The changes could not be read.", origin: "native" },
    });
    const error = await rejection(postNative("git.status", { cwd: "/repo" }));
    expect(error).toBeInstanceOf(Error);
    expect(fields(error)).toEqual({
      name: "NativeError",
      message: "The changes could not be read.",
      code: "native.timed_out",
      details: undefined,
      retryable: undefined,
      origin: "native",
    });
  });

  test("a refusal without a code or origin is a native failure with a generic message", async () => {
    answerWith({ ok: false });
    expect(fields(await rejection(postNative("git.status", { cwd: "/repo" })))).toMatchObject({
      name: "NativeError",
      message: "Request failed",
      code: "native.failed",
      origin: "native",
    });
  });

  test("outside the app the request is never sent", async () => {
    (globalThis as any).window ??= globalThis;
    expect(fields(await rejection(postNative("git.status", { cwd: "/repo" })))).toMatchObject({
      name: "NativeError",
      message: "Native bridge is unavailable",
      code: "native.not_connected",
      origin: "native",
    });
  });
});
