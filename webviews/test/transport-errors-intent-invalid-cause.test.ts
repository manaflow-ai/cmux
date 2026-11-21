// A malformed-request refusal names what the app blocked, by the method the host's refusal names
// (`data.method`, AcpmuxPaneMethods `refusal`). Every chat typed on New Tab failed with "Couldn't
// start Codex: Something went wrong, so that didn't go through." and nothing said that the app had
// refused the chat's open (#42460). Still plain words: no request, pane, intent or Try again.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { startFailureView } from "../src/agent-session/acpmux/startFailure";
import { hostLineText } from "../src/agent-session/acpmux/hostLine";
import { failedSendText } from "../src/agent-session/acpmux/sendFailure";
import { errorMessage } from "../src/agent-session/acpmux/transportErrors";

/// The error direct.ts builds from the host's refusal frame.
function refusal(method?: string, detail?: string): Error {
  return Object.assign(new Error("Refused by the cmux host"), {
    code: "transport.intent_invalid",
    ...(method ? { method } : {}),
    ...(detail ? { detail } : {}),
  });
}

function quietly<T>(run: () => T): T {
  const original = console.error;
  console.error = () => {};
  try {
    return run();
  } finally {
    console.error = original;
  }
}

test("a refused open, start, send or setting says which", () => {
  const cases: [string, Parameters<typeof translate>[0]][] = [
    ["initialize", "transport.intentInvalidConnect"],
    ["_acpmux/attach", "transport.intentInvalidOpen"],
    ["session/new", "transport.intentInvalidStart"],
    ["session/prompt", "transport.intentInvalidSend"],
    ["session/set_config_option", "transport.intentInvalidSetting"],
  ];
  for (const [method, key] of cases) {
    const text = quietly(() => errorMessage(refusal(method)));
    expect(text).toBe(translate(key));
    expect(text).not.toBe(translate("transport.intentInvalid"));
    for (const jargon of [/\brequest\b/i, /\bpane\b/i, /intent/i, /try again/i, /went wrong/i])
      expect(text).not.toMatch(jargon);
  }
});

test("a refusal with no known method keeps the generic line", () => {
  for (const method of [undefined, "_acpmux/typing", "_acpmux/watch", "_acpmux/events", "constructor"])
    expect(quietly(() => errorMessage(refusal(method)))).toBe(translate("transport.intentInvalid"));
});

// 2026-11-21: the app's relay refused every chat's `initialize` (`unknown param "_meta"`: the
// page's initialize carried `_meta.acpmux.peerRowBatches` the relay's params rule did not know),
// and every chat said only "Something went wrong, so that didn't go through." with Retry. A
// refused connect says so, keeps the relay's own reason behind Details, and a send that failed on
// it names the connect, not "Try again".
test("a refused connect says the chat's connection was blocked and keeps the host's reason", () => {
  const error = refusal("initialize", 'unknown param "_meta"');
  const line = quietly(() => errorMessage(error));
  expect(line).toBe(translate("transport.intentInvalidConnect"));
  const words = hostLineText(error, line, translate);
  expect(words.line).toBe(translate("transport.intentInvalidConnect"));
  expect(words.detail).toBe('initialize: unknown param "_meta"');
  expect(quietly(() => failedSendText(error, false))).toBe(
    translate("prompt.notSent", { reason: translate("transport.intentInvalidConnect") }),
  );
  expect(quietly(() => failedSendText(error, true))).toBe(
    translate("prompt.stillNotSent", { reason: translate("transport.intentInvalidConnect") }),
  );
});

type Daemon = {
  onopen: (() => void) | null;
  onmessage: ((message: { data: string }) => void) | null;
  send(raw: string): void;
};

/// The app's bridge, refusing the chat's open as AgentPaneTransport does (AcpmuxPaneMethods
/// `refusal`: `data.method` names the refused frame's method); every other frame reaches the mock
/// daemon.
function refusingAttach(daemon: Daemon) {
  return refusing("_acpmux/attach", daemon);
}

/// The app's bridge refusing `method`'s frames, with `detail` (the relay's rule) when given.
function refusing(method: string, daemon: Daemon, detail?: string) {
  const socket = {
    readyState: 0,
    onopen: null as (() => void) | null,
    onerror: null as (() => void) | null,
    onclose: null as ((event: { code: number; reason: string; wasClean: boolean }) => void) | null,
    onmessage: null as ((message: { data: string }) => void) | null,
    send(raw: string) {
      const frame = JSON.parse(raw) as { id?: number | string; method?: string };
      if (frame.method !== method || frame.id === undefined) return daemon.send(raw);
      const data = {
        code: "transport.intent_invalid",
        origin: "native",
        method: frame.method,
        ...(detail ? { detail } : {}),
      };
      const error = { code: -32601, message: "Refused by the cmux host", data };
      queueMicrotask(() => socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: frame.id, error }) }));
    },
    close() {
      socket.readyState = 3;
      queueMicrotask(() => socket.onclose?.({ code: 1000, reason: "", wasClean: true }));
    },
  };
  daemon.onopen = () => {
    socket.readyState = 1;
    socket.onopen?.();
  };
  daemon.onmessage = (message) => {
    if (socket.readyState === 1) socket.onmessage?.(message);
  };
  return socket;
}

test("a chat whose open the app refuses reads as that, through the page's own client", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const open = () => refusingAttach(new MockAcpmuxSocket(() => Promise.resolve()) as never) as unknown as WebSocket;
  let failure: unknown;
  await quietly(() =>
    AcpmuxDirectClient.connect(mockHost, () => {}, undefined, open).then(
      (client) => client.close(),
      (error: unknown) => {
        failure = error;
      },
    ),
  );
  expect(failure).toBeDefined();
  expect(quietly(() => errorMessage(failure))).toBe(translate("transport.intentInvalidOpen"));
});

test("a chat whose connect the app refuses says that, with the relay's reason in Details", async () => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const daemon = () => new MockAcpmuxSocket(() => Promise.resolve()) as never;
  const open = () => refusing("initialize", daemon(), 'unknown param "_meta"') as unknown as WebSocket;
  let failure: unknown;
  await quietly(() =>
    AcpmuxDirectClient.connect(mockHost, () => {}, undefined, open).then(
      (client) => client.close(),
      (error: unknown) => {
        failure = error;
      },
    ),
  );
  expect(failure).toBeDefined();
  // The host line App.tsx shows for a failed handshake: errorMessage, worded by hostLineText.
  const line = quietly(() => errorMessage(failure));
  const words = hostLineText(failure, line, translate);
  expect(words.line).toBe(translate("transport.intentInvalidConnect"));
  expect(words.line).not.toBe(translate("transport.intentInvalid"));
  expect(words.detail).toBe('initialize: unknown param "_meta"');
});

test("the start card for a refused open names it, not 'Something went wrong'", () => {
  const t = (key: Parameters<typeof translate>[0], values?: Record<string, string | number>) => translate(key, values);
  const error = quietly(() => errorMessage(refusal("_acpmux/attach")));
  const view = startFailureView(t, { harness: "codex", name: "Codex", error, code: "transport.intent_invalid" });
  expect(view.sentence).toBe(
    translate("switch.failed", { agent: "Codex", reason: translate("transport.intentInvalidOpen") }),
  );
  expect(view.sentence).not.toContain(translate("transport.intentInvalid"));
});
