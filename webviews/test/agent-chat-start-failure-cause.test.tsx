// A new chat that fails to start says why (#44964). On 2026-11-12 every agent failed to start
// after acpmux restarted, and each card said only "Couldn't start <agent>: Something went wrong, so
// that didn't go through." with Retry: the pane host's refusal (its method, the param it refused)
// and the code never reached the card or the app's log. Here the page's real start path (the direct
// client over a mock acpmux socket, HarnessSwitch, the failed card) runs against the failures a start
// meets: the host refusing the start frame, and no connection to acpmux at all.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"];
const saved = new Map(keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)]));
let root: Root | undefined;
let logged: string[] = [];
const consoleError = console.error;

beforeAll(() => {
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
});

afterEach(async () => {
  console.error = consoleError;
  logged = [];
  if (root) await act(async () => root!.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(scope, key, descriptor);
    else delete scope[key];
  }
  dom.window.close();
});

type Daemon = { answer(method: string, params: Record<string, unknown>): Promise<unknown> };

/// The page's start path as App.tsx wires it: HarnessSwitch over the direct client's startSession.
async function startPath(
  refuse?: (method: string) => Error | undefined,
  open?: (sessionId: string) => Promise<string | undefined>,
) {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const { HarnessSwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const answer = daemon.answer.bind(daemon);
  daemon.answer = async (method, params) => {
    const refusal = refuse?.(method);
    if (refusal) throw refusal;
    return answer(method, params);
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => socket as unknown as WebSocket,
  );
  client.leave();
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect({
    turnRunning: () => client.turnRunning(),
    shown: () => client.shownSession(),
    create: (harness, cwd, model) => client.startSession(harness, cwd, undefined, undefined, false, model),
    leave: () => client.leave(),
    open: open ?? ((sessionId) => client.select(sessionId)),
    send: async () => undefined,
    setModel: async () => undefined,
    setMode: async () => undefined,
    setConfig: async () => undefined,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  });
  return { client, harnessSwitch };
}

/// The pane host's answer to a frame it refused (AcpmuxPaneMethods.refusal): `data.method` only when
/// the host names the method, `data.detail` the rule it broke.
function hostRefusal(method: string | undefined, detail: string): Error {
  return Object.assign(new Error("Refused by the cmux host"), {
    data: { code: "transport.intent_invalid", origin: "native", ...(method && { method }), detail },
  });
}

async function failedCard(harnessSwitch: import("../src/agent-session/acpmux/harnessSwitch").HarnessSwitch) {
  await harnessSwitch.switchTo("claude", "/tmp/project");
  const intent = harnessSwitch.view().intent;
  expect(intent?.phase).toBe("failed");
  const { SwitchNotice } = await import("../src/agent-session/acpmux/SwitchNotice");
  const container = dom.window.document.getElementById("root")!;
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <SwitchNotice
        switching={{
          harness: intent!.harness,
          name: "Claude Code",
          phase: "failed",
          ...(intent!.error && { error: intent!.error }),
          ...(intent!.code && { code: intent!.code }),
          ...(intent!.cause && { cause: intent!.cause }),
        }}
        onRetry={() => undefined}
      />,
    );
  });
  return {
    sentence: container.querySelector(".acpmux-host-error-message")?.textContent?.trim() ?? "",
    details: container.querySelector("details")?.textContent ?? "",
  };
}

function captureLog() {
  console.error = (...args: unknown[]) => void logged.push(args.map(String).join(" "));
}

test("a start frame the host refuses names the start, with the refused param under Details and in the log", async () => {
  const { client, harnessSwitch } = await startPath((method) =>
    method === "session/new" ? hostRefusal(undefined, 'unknown _meta.acpmux key "launchProfile"') : undefined,
  );
  captureLog();
  try {
    const card = await failedCard(harnessSwitch);
    // Never the generic line: the host named no method, and this was a start.
    expect(card.sentence).toBe(
      "Couldn't start Claude Code: cmux blocked starting this chat. That’s a bug in cmux, not something you did.",
    );
    expect(card.sentence).not.toContain("Something went wrong");
    expect(card.details).toContain('unknown _meta.acpmux key "launchProfile"');
    expect(card.details).toContain("code transport.intent_invalid");
    const line = logged.find((entry) => entry.startsWith("agent pane: couldn't start claude"));
    expect(line).toContain("session=none");
    expect(line).toContain('unknown _meta.acpmux key "launchProfile"');
    expect(line).toContain("code transport.intent_invalid");
  } finally {
    client.close();
  }
});

test("a refused open of the started chat logs the chat's session id", async () => {
  // The open's attach refused as direct.ts rejects it (the host's `data` copied onto the error).
  const refused = Object.assign(new Error("Refused by the cmux host"), {
    code: "transport.intent_invalid",
    method: "_acpmux/attach",
    detail: 'unknown param "settled"',
  });
  const { client, harnessSwitch } = await startPath(undefined, () => Promise.reject(refused));
  captureLog();
  try {
    const card = await failedCard(harnessSwitch);
    const intent = harnessSwitch.view().intent!;
    expect(card.sentence).toBe(
      "Couldn't start Claude Code: cmux blocked opening this chat. That’s a bug in cmux, not something you did.",
    );
    expect(card.details).toContain('unknown param "settled"');
    expect(intent.sessionId).toBeTruthy();
    const line = logged.find((entry) => entry.startsWith("agent pane: couldn't start claude"));
    expect(line).toContain(`session=${intent.sessionId}`);
    expect(line).toContain('unknown param "settled"');
    expect(line).toContain("method _acpmux/attach");
  } finally {
    client.close();
  }
});

test("a start with no connection to acpmux says the agent service is unreachable and what to do", async () => {
  const { client, harnessSwitch } = await startPath();
  client.close();
  captureLog();
  const card = await failedCard(harnessSwitch);
  expect(card.sentence).toBe(
    "Claude Code didn't start because cmux couldn't reach its agent service. Try again, and if it keeps happening, quit and reopen cmux.",
  );
  expect(card.details).toContain("code native.not_connected");
  expect(logged.some((entry) => entry.includes("code native.not_connected"))).toBe(true);
});
