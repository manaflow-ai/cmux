import { afterEach, describe, expect, test } from "bun:test";
import { agentPageOp, applyHostEvent, callPageHost, startHostEvents } from "./pageHost";
import { pageError, type PageClient } from "../../pages/shared/pageClient";

/// A fake page client: records calls and subscriptions, answers with `answer`.
function client(answer: (op: string, params: unknown) => unknown) {
  const calls: { op: string; params: unknown }[] = [];
  const streams: { stream: string; onEvent: (data: unknown, seq: number) => void }[] = [];
  const fake: PageClient = {
    async call<R>(op: string, params: unknown) {
      calls.push({ op, params });
      return (await answer(op, params)) as R;
    },
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      streams.push({ stream, onEvent: onEvent as (data: unknown, seq: number) => void });
      return () => undefined;
    },
    handle: () => () => undefined,
  };
  return { fake, calls, streams };
}

async function rejection(promise: Promise<unknown>): Promise<any> {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error("expected a rejection");
}

describe("agent page host", () => {
  afterEach(() => {
    delete (globalThis as any).cmuxAcpmuxBridge;
  });

  test("each old bridge method has its cmux.agent op", () => {
    expect(agentPageOp("ready")).toBe("cmux.agent.handshake");
    expect(agentPageOp("chat.persistSession")).toBe("cmux.agent.session.persist");
    expect(agentPageOp("git.status")).toBe("cmux.agent.git.status");
    expect(agentPageOp("quick.openInWindow")).toBe("cmux.agent.quick.openInWindow");
  });

  test("a call goes to the op with the same params and resolves with its value", async () => {
    const { fake, calls } = client(() => ({ root: "/repo" }));
    expect(await callPageHost(fake, "git.status", { cwd: "/repo" })).toEqual({ root: "/repo" });
    expect(calls).toEqual([{ op: "cmux.agent.git.status", params: { cwd: "/repo" } }]);
  });

  test("a host refusal keeps its code, message, retryable, origin and details", async () => {
    const refusal = Object.assign(pageError("operation.failed", "The changes could not be read.", false), {
      details: { origin: "session_host", details: { exit_code: 128 } },
    });
    const { fake } = client(() => {
      throw refusal;
    });
    const error = await rejection(callPageHost(fake, "git.diff", { cwd: "/repo" }));
    expect(error.name).toBe("NativeError");
    expect(error.message).toBe("The changes could not be read.");
    expect(error.code).toBe("operation.failed");
    expect(error.origin).toBe("session_host");
    expect(error.details).toEqual({ exit_code: 128 });
    expect(error.retryable).toBe(false);
  });

  test("a request the host refused before sending says so (origin native)", async () => {
    const { fake } = client(() => {
      throw pageError("cmux.protocol.invalid_params", "cmux.agent.git.diff");
    });
    const error = await rejection(callPageHost(fake, "git.diff", {}));
    expect(error.code).toBe("native.invalid_request");
    expect(error.origin).toBe("native");
  });

  test("a lost link leaves the outcome unknown (no code, no origin)", async () => {
    const { fake } = client(() => {
      throw pageError("cmux.protocol.closed", "closed", true);
    });
    const error = await rejection(callPageHost(fake, "git.checkpoint.diff", {}));
    expect(error.code).toBeUndefined();
    expect(error.origin).toBeUndefined();
  });

  test("host events run the page bridge function the old host scripts ran", () => {
    const seen: [string, unknown][] = [];
    (globalThis as any).cmuxAcpmuxBridge = {
      applyTheme: (v: unknown) => seen.push(["applyTheme", v]),
      applyShortcuts: (v: unknown) => seen.push(["applyShortcuts", v]),
      applyPreview: (v: unknown) => seen.push(["applyPreview", v]),
      applyCustomization: (v: unknown) => seen.push(["applyCustomization", v]),
      dictation: (v: unknown) => seen.push(["dictation", v]),
      revealTurn: (v: unknown) => seen.push(["revealTurn", v]),
      command: (v: unknown) => seen.push(["command", v]),
    };
    const themed: unknown[] = [];
    (globalThis as any).cmuxTheme = { apply: (v: unknown) => themed.push(v) };
    applyHostEvent({ kind: "theme", value: { web: { w: 1 }, agent: { a: 1 } } });
    applyHostEvent({ kind: "shortcuts", value: { x: "⌘K" } });
    applyHostEvent({ kind: "preview", value: true });
    applyHostEvent({ kind: "customization", value: { themeCSS: "", layout: {} } });
    applyHostEvent({ kind: "dictation", value: { state: "listening" } });
    applyHostEvent({ kind: "revealTurn", value: "t-1" });
    applyHostEvent({ kind: "command", value: "searchChats" });
    applyHostEvent({ kind: "unknown", value: 1 });
    expect(themed).toEqual([{ w: 1 }]);
    expect(seen).toEqual([
      ["applyTheme", { a: 1 }],
      ["applyShortcuts", { x: "⌘K" }],
      ["applyPreview", true],
      ["applyCustomization", { themeCSS: "", layout: {} }],
      ["dictation", { state: "listening" }],
      ["revealTurn", "t-1"],
      ["command", "searchChats"],
    ]);
    delete (globalThis as any).cmuxTheme;
  });

  test("the page subscribes to host events once", async () => {
    const { fake, streams } = client(() => null);
    await startHostEvents(fake);
    await startHostEvents(fake);
    expect(streams.map((s) => s.stream)).toEqual(["cmux.agent.host.events"]);
  });
});
