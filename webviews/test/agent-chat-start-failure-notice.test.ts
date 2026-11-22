// The notice a sessionless chat's failed first-send start leaves in the chat (#44964): one line, no
// Details, so it carries the reason itself when the reason is plain words, and only then. Raw text
// (a panic, a JSON-RPC body, a path) stays in the log; a start that waited on an away acpmux stays
// quiet, as the host line already says so; a start another chat's selection overtook says nothing.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { isStartSuperseded, startFailureNotice } from "../src/agent-session/acpmux/startFailure";

let logged: string[] = [];
const consoleError = console.error;
beforeEach(() => {
  logged = [];
  console.error = (...args: unknown[]) => void logged.push(args.map(String).join(" "));
});
afterEach(() => {
  console.error = consoleError;
});

const acpmux = (message: string, data: Record<string, unknown> = {}, code = -32603) =>
  Object.assign(new Error(message), { code, data });

test("an unnamed agent's plain refusal is the notice's reason", () => {
  const error = acpmux("agent launch is disabled in this build session", { reason: "agent_launch_disabled" }, -32010);
  expect(startFailureNotice(translate, undefined, error)).toBe(
    "Couldn't start the agent: agent launch is disabled in this build session",
  );
  expect(logged[0]).toContain("session=none: agent launch is disabled in this build session (code -32010");
});

test("a named agent's plain refusal names the agent", () => {
  const error = acpmux("agent launch is disabled in this build session", { reason: "agent_launch_disabled" }, -32010);
  expect(startFailureNotice(translate, "claude", error)).toBe(
    "Couldn't start Claude Code: agent launch is disabled in this build session",
  );
});

test("raw text never reaches the notice; it stays in the log", () => {
  const panic = acpmux("internal error: thread 'main' panicked at src/session.rs:42:5: called Option::unwrap()");
  const json = new Error('{"code":-32603,"message":"Internal error","data":{"trace":"x"}}');
  for (const [harness, error] of [
    [undefined, panic],
    [undefined, json],
    ["claude", panic],
    ["claude", json],
  ] as const) {
    const line = startFailureNotice(translate, harness, error) ?? "";
    expect(line).not.toContain("panicked");
    expect(line).not.toContain("{");
    expect(line).not.toContain("session.rs");
  }
  expect(startFailureNotice(translate, undefined, panic)).toBe("Couldn't start the chat. Try again.");
  expect(startFailureNotice(translate, "claude", panic)).toBe("Claude Code couldn’t start.");
  expect(logged.some((entry) => entry.includes("panicked at src/session.rs:42:5"))).toBe(true);
});

test("a start that met an away acpmux says nothing more than the host line", () => {
  for (const code of ["native.not_connected", "native.timed_out", "transport.closed", "transport.connect_failed"])
    expect(startFailureNotice(translate, "claude", Object.assign(new Error("x"), { code }))).toBeUndefined();
  expect(
    startFailureNotice(translate, undefined, Object.assign(new Error("x"), { interrupted: true })),
  ).toBeUndefined();
  expect(logged.length).toBe(5);
});

test("a host-refused start without a named agent reads as a sentence", () => {
  const error = Object.assign(new Error("Refused by the cmux host"), { code: "transport.intent_invalid" });
  expect(startFailureNotice(translate, undefined, error)).toBe(
    "Couldn't start the agent: cmux blocked starting this chat. That’s a bug in cmux, not something you did.",
  );
});

test("a peer chat whose machine is down names the machine", () => {
  const error = acpmux("peer_unreachable: devbox (offline, last seen 3m ago)", { reason: "peer_unreachable" });
  expect(startFailureNotice(translate, "claude", error)).toContain("devbox");
});

test("a start another chat's selection overtook is superseded, not failed", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as { answer(method: string, params: unknown): Promise<unknown> };
  const answer = daemon.answer.bind(daemon);
  let release!: () => void;
  const held = new Promise<void>((resolve) => (release = resolve));
  let hold = false;
  daemon.answer = async (method, params) => {
    if (method === "session/new" && hold) await held;
    return answer(method, params);
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    // Another chat the person can open.
    const other = await client.startSession("claude", "/tmp/other", undefined, undefined, false);
    client.leave();
    hold = true;
    const start = client.ensureSession().catch((error: unknown) => error);
    // The person opens that chat while this one's session/new is out.
    await client.select(other!);
    release();
    const error = await start;
    expect(error).toBeInstanceOf(Error);
    expect(isStartSuperseded(error)).toBe(true);
  } finally {
    client.close();
  }
});

test("the start card says an unclassified plain reason in its sentence; raw text stays under Details", async () => {
  const { startFailureView } = await import("../src/agent-session/acpmux/startFailure");
  const plain = startFailureView(translate, {
    harness: "claude-sr2",
    name: "Claude Code (sr2 internal)",
    error: "the subrouter has no account free for this model right now",
  });
  expect(plain.sentence).toBe(
    "Couldn't start Claude Code (sr2 internal): the subrouter has no account free for this model right now",
  );
  const raw = startFailureView(translate, {
    harness: "claude-sr2",
    name: "Claude Code (sr2 internal)",
    error: "internal error: thread 'main' panicked at src/session.rs:42:5",
  });
  expect(raw.sentence).toBe("Claude Code (sr2 internal) couldn’t start.");
  expect(raw.detail).toContain("panicked");
});
