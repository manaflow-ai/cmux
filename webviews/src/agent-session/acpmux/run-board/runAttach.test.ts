import { describe, expect, test } from "bun:test";
import { RunApiHttpError } from "./runApi";
import { attachRunTerminal, runAttachCommand } from "./runAttach";

const ticket = {
  runId: "run-1",
  attemptId: "attempt-1",
  sessionId: "session-1",
  cursor: "7",
  ticket: "one-use",
  transport: "cmux-remote",
  route: "ws://10.4.0.7:1337/v1/link",
  session: "main",
  trustedCarrier: true,
} as const;

describe("run terminal attach bridge", () => {
  test("uses the redeemed route through the existing cmux remote client", () => {
    expect(runAttachCommand(ticket)).toBe(
      "cmux remote connect 'ws://10.4.0.7:1337/v1/link' --session 'main' --carrier",
    );
  });

  test("quotes route and session values before handing them to the terminal", () => {
    expect(runAttachCommand({ ...ticket, route: "ws://worker/a'b", session: "main'b" })).toContain(
      "'ws://worker/a'\\''b'",
    );
  });

  test("rejects an endpoint that cannot use the trusted cmux carrier", () => {
    expect(() => runAttachCommand({ ...ticket, trustedCarrier: false })).toThrow(RunApiHttpError);
  });

  test("refuses a redeemed endpoint after its local expiry", () => {
    expect(() => runAttachCommand({ ...ticket, expiresAtUnix: 100 }, 100_000)).toThrow(/expired/);
  });

  test("opens the enrolled worker terminal through the native page bridge", async () => {
    const calls: Array<[string, Record<string, unknown> | undefined]> = [];
    await attachRunTerminal(ticket, async (method, params) => {
      calls.push([method, params]);
      return undefined;
    });
    expect(calls).toEqual([
      [
        "run.attach",
        {
          runId: "run-1",
          attemptId: "attempt-1",
          provider: undefined,
          providerVmId: undefined,
          providerWorkspaceId: undefined,
          providerTerminalId: undefined,
          route: "ws://10.4.0.7:1337/v1/link",
          session: "main",
          trustedCarrier: true,
          expiresAtUnix: undefined,
        },
      ],
    ]);
  });
});
