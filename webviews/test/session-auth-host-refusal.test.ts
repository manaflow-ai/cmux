// The composer's sign-in check (`_acpmux/session/auth`, #26643) shipped without an entry on the pane's
// relay allowlist, so the host refused every check and acpmux never saw one (2026-10-29). A host
// refusal is no answer, like a daemon without `sessionAuth`: the check reads unknown, never a
// sign-in prompt, and the console says the method is missing from the allowlist, once per method,
// so a missing entry never fails silently again. acpmux's own errors still reach the caller.
import { afterEach, expect, spyOn, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { AcpmuxRpcError } from "../src/agent-session/acpmux/handoff/protocol";
import { UNKNOWN_AUTH } from "../src/agent-session/acpmux/sessionAuth";

function clientRefusing(error: AcpmuxRpcError): AcpmuxDirectClient {
  const client = Object.create(AcpmuxDirectClient.prototype) as AcpmuxDirectClient;
  (client as unknown as { features: Set<string> }).features = new Set(["sessionAuth"]);
  (client as unknown as { request: () => Promise<unknown> }).request = async () => {
    throw error;
  };
  return client;
}

const hostRefusal = () =>
  Object.assign(
    new AcpmuxRpcError({
      code: -32601,
      message: "Refused by the cmux host",
      data: { origin: "native", code: "transport.method_refused", method: "_acpmux/session/auth" },
    }),
    { code: "transport.method_refused" },
  );

afterEach(() => {
  (console.warn as unknown as { mockRestore?: () => void }).mockRestore?.();
});

test("the host refusing the sign-in check reads as unknown, not as an error or a sign-in prompt", async () => {
  const client = clientRefusing(hostRefusal());
  expect(await client.sessionAuth({ sessionId: "chat-1" })).toEqual(UNKNOWN_AUTH);
  expect(await client.sessionAuth({ target: { harness: "claude" } }, true)).toEqual(UNKNOWN_AUTH);
});

test("acpmux's own failure of the check still reaches the caller", async () => {
  const client = clientRefusing(new AcpmuxRpcError({ code: -32602, message: "sessionId or target is required" }));
  await expect(client.sessionAuth({ sessionId: "chat-1" })).rejects.toBeInstanceOf(AcpmuxRpcError);
});

test("a request the host refuses as not allowlisted is said in the console, once per method", async () => {
  const warn = spyOn(console, "warn").mockImplementation(() => {});
  const client = Object.create(AcpmuxDirectClient.prototype) as AcpmuxDirectClient;
  const sent: string[] = [];
  const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: unknown) => void }>();
  Object.assign(client as unknown as Record<string, unknown>, {
    socket: { readyState: WebSocket.OPEN, send: (text: string) => sent.push(text) },
    nextRequest: 1,
    pending,
    wire: { sent: () => {} },
  });
  const request = (client as unknown as { request: (m: string, p: object) => Promise<unknown> }).request.bind(client);
  for (const method of ["_acpmux/not_listed", "_acpmux/not_listed", "_acpmux/also_not_listed"]) {
    const reply = request(method, {});
    const [id, entry] = [...pending.entries()].at(-1)!;
    pending.delete(id);
    entry.reject(
      Object.assign(
        new AcpmuxRpcError({
          code: -32601,
          message: "Refused by the cmux host",
          data: { origin: "native", code: "transport.method_refused", method },
        }),
        { code: "transport.method_refused" },
      ),
    );
    await expect(reply).rejects.toBeInstanceOf(AcpmuxRpcError);
  }
  const warned = warn.mock.calls.map((call) => String(call[0]));
  expect(warned.filter((line) => line.includes("_acpmux/not_listed"))).toHaveLength(1);
  expect(warned.filter((line) => line.includes("_acpmux/also_not_listed"))).toHaveLength(1);
  expect(sent).toHaveLength(3);
});
