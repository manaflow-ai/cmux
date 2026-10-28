// l10n-allow-file: deterministic recovery fixtures.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const scope = globalThis as Record<string, unknown>;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root;
let mount: HTMLElement;
beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id='root'></div>", { url: "https://cmux.test" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  mount = dom.window.document.getElementById("root")!;
  root = (await import("react-dom/client")).createRoot(mount);
});
afterAll(async () => {
  await act(async () => root.unmount());
  dom.window.close();
  for (const [key, present, value] of saved) {
    if (present) scope[key] = value;
    else delete scope[key];
  }
});

test("Resume uses native attach, then rereads the missing chat; disposal stops recovery", async () => {
  const { useCloudChatRecovery } = await import("../src/agent-session/acpmux/useCloudChatRecovery");
  const { ChatUnavailableState } = await import("../src/agent-session/acpmux/ChatUnavailableState");
  const { cloudChatUnavailable } = await import("../src/agent-session/acpmux/cloudChatRecovery");
  const calls: string[] = [];
  let stage = "paused";
  let failRead = true;
  Object.assign(dom.window, {
    webkit: {
      messageHandlers: {
        agentSession: {
          postMessage: ({ method }: { method: string }) => {
            calls.push(method);
            if (method === "cloudMachine.recoveryList" && failRead) {
              failRead = false;
              return { ok: false, error: { code: "network" } };
            }
            if (method === "cloudMachine.attach") {
              stage = "connecting";
              return { ok: true, value: {} };
            }
            return {
              ok: true,
              value: {
                signedIn: true,
                loaded: true,
                complete: true,
                account: ["user", null],
                machines: [{ id: "vm-demo", name: "Demo machine", stage }],
              },
            };
          },
        },
      },
    },
  });
  let opened = false;
  const recheck = async () => {
    opened = stage === "connecting";
  };
  const noop = () => {};
  function Recovery() {
    const recovery = useCloudChatRecovery({
      cloud: { id: "vm-demo", account: ["user", null] },
      session: "chat-demo",
      active: true,
      recheck,
    });
    return (
      <ChatUnavailableState
        unavailable={cloudChatUnavailable({ reason: "offline" }, recovery.state, "Demo machine")}
        onResumeMachine={recovery.resume}
        onRemove={noop}
        onReconnect={recovery.refresh}
        resuming={recovery.resuming}
      />
    );
  }
  await act(async () => root.render(<Recovery />));
  const retry = mount.querySelector<HTMLButtonElement>('[data-action="reconnect"]');
  expect(retry).not.toBeNull();
  await act(async () => retry!.click());
  expect(calls.filter((method) => method === "cloudMachine.recoveryList")).toHaveLength(2);
  const button = mount.querySelector<HTMLButtonElement>('[data-action="resumeMachine"]');
  expect(button).not.toBeNull();
  await act(async () => button!.click());
  expect(calls.filter((method) => method === "cloudMachine.attach")).toHaveLength(1);
  expect(calls).not.toContain("cloudMachine.open");
  expect(opened).toBe(true);
  await act(async () => root.render(null));
});
