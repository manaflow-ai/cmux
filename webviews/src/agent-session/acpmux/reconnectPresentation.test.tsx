import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ChatHeaderStatus } from "./header/ChatHeaderStatus";
import { isTerminalConnectionFailure } from "./connectionState";
import { NativeError } from "./nativeError";
import { paneHeader, type AcpmuxSnapshot } from "./model";

const snapshot = (overrides: Partial<AcpmuxSnapshot>): AcpmuxSnapshot =>
  ({
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "connected",
    isWorking: false,
    queue: [],
    catalog: [],
    canLoadOlder: false,
    ...overrides,
  }) as AcpmuxSnapshot;

const translate = (key: string) =>
  ({
    "header.agentChat": "Agent chat",
    "header.reconnecting": "Reconnecting…",
    "header.failed": "Failed",
    "header.disconnected": "Disconnected",
  })[key] ?? key;

test("active daemon retry is a neutral reconnecting header with a spinner", () => {
  const header = paneHeader(
    snapshot({
      summary: {
        sessionId: "s",
        retry: { attempt: 1, of: 4, nextAt: 1, promptId: "p", turnId: "t", reason: "transport" },
      },
    }),
    translate,
  );
  expect(header.status).toBe("Reconnecting…");
  expect(header.kind).toBe("reconnecting");
  const html = renderToStaticMarkup(<ChatHeaderStatus status={header.status} detail={header.detail} kind={header.kind} />);
  expect(html).toContain("cv-spinner");
  expect(html).not.toContain("status.warning");
});

test("terminal exhaustion stays an honest failure even with a connecting message", () => {
  const header = paneHeader(
    snapshot({
      connection: "connecting",
      connectionState: { phase: "terminal", message: "Automatic reconnects are exhausted. Try again." },
    }),
    translate,
  );
  expect(header.status).toBe("Failed");
  expect(header.kind).toBe("problem");
  expect(header.detail).toBe("Automatic reconnects are exhausted. Try again.");
});


test("definite authorization refusal is terminal and never transient", () => {
  expect(isTerminalConnectionFailure(new NativeError({ code: "auth.required", retryable: false }))).toBe(true);
  expect(isTerminalConnectionFailure(new NativeError({ code: "native.not_connected", retryable: true }))).toBe(false);
});
