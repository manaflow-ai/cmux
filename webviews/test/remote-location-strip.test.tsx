// Composer destination pickers share the searchable Combobox and keep picks scoped to listed rows.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, { had: boolean; value: unknown }>();
let dom: JSDOM;
let host: HTMLElement;
let root: Root | undefined;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const replacements: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(replacements)) {
    saved.set(key, { had: key in scope, value: scope[key] });
    scope[key] = value;
  }
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  await act(async () => root?.unmount());
  root = undefined;
  host.replaceChildren();
});

afterAll(() => {
  dom.window.close();
  for (const [key, entry] of saved) {
    if (entry.had) scope[key] = entry.value;
    else delete scope[key];
  }
});

async function click(button: HTMLElement) {
  await act(async () => {
    button.dispatchEvent(new dom.window.MouseEvent("pointerdown", { bubbles: true }));
    button.click();
  });
}

test("remote strip reflects real peer state and reconnects the existing command", async () => {
  const calls: string[] = [];
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  root = (await import("react-dom/client")).createRoot(host);
  const props = {
    environments: true,
    peers: ["air-blue"],
    peerKinds: { "air-blue": "ssh" as const },
    peerConnected: { "air-blue": false },
    peerStates: { "air-blue": "offline" },
    summary: { sessionId: "remote-chat", host: "air-blue", peer: "air-blue" },
    projectChoices: [],
    onProject: () => undefined,
    onReconnectRemote: (peer: string) => calls.push(peer),
  };
  await act(async () => root!.render(<ComposerContext {...props} />));
  expect(host.querySelector(".acpmux-remote-location")?.getAttribute("data-state")).toBe("offline");
  expect(host.querySelector(".acpmux-remote-location-face")?.textContent).toContain("Remote");
  expect(host.querySelector(".acpmux-remote-location-machine")?.textContent).toBe("air-blue");
  const reconnect = host.querySelector<HTMLButtonElement>(".acpmux-remote-location-reconnect");
  expect(reconnect?.getAttribute("aria-label")).toBe("Reconnect");
  await click(reconnect!);
  expect(calls).toEqual(["air-blue"]);

  await act(async () =>
    root!.render(
      <ComposerContext {...props} peerConnected={{ "air-blue": true }} peerStates={{ "air-blue": "connected" }} />,
    ),
  );
  expect(host.querySelector(".acpmux-remote-location")?.getAttribute("data-state")).toBe("connected");
  expect(host.querySelector(".acpmux-remote-location-reconnect")).toBeNull();
  await act(async () => root!.render(<ComposerContext {...props} peerConnected={{}} peerStates={{}} />));
  expect(host.querySelector(".acpmux-remote-location")?.getAttribute("data-state")).toBe("unknown");
  expect(host.querySelector(".acpmux-remote-location-reconnect")).toBeNull();
});

test("a remote machine pick leaves the project optional even when it has recent folders", async () => {
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const picked: string[] = [];
  const projects: string[] = [];
  root = (await import("react-dom/client")).createRoot(host);
  await act(async () =>
    root!.render(
      <ComposerContext
        environments
        peers={["air-blue"]}
        peerKinds={{ "air-blue": "ssh" }}
        peerConnected={{ "air-blue": true }}
        peerStates={{ "air-blue": "connected" }}
        summary={{ sessionId: "local-chat" }}
        sessions={[{ sessionId: "old-remote", host: "air-blue", peer: "air-blue", cwd: "/srv/old-project" }]}
        projectChoices={[]}
        onComputer={(peer) => picked.push(peer)}
        onProject={(cwd) => projects.push(cwd)}
      />,
    ),
  );
  await click(host.querySelector<HTMLButtonElement>('[data-kind="computer"] button')!);
  const row = Array.from(document.querySelectorAll<HTMLElement>('[role="option"]')).find((node) =>
    node.textContent?.includes("air-blue"),
  );
  expect(row).toBeDefined();
  await click(row!);
  expect(picked).toEqual(["air-blue"]);
  expect(projects).toEqual([]);
});

test("a remote prompt without a project starts on that peer without a cwd", async () => {
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const sent: { method: string; params?: Record<string, unknown> }[] = [];
  const noop = () => {};
  const actions = newTabScreenActions({
    callNative: async (method, params) => {
      sent.push({ method, params });
      return method === "chat.new" ? "remote-chat" : undefined;
    },
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  actions.onAsk("claude", "hello remote", undefined, undefined, undefined, undefined, { peer: "air-blue" });
  await act(async () => {});
  expect(sent.find((call) => call.method === "chat.new")?.params).toEqual({ harness: "claude", peer: "air-blue" });
  expect(sent.find((call) => call.method === "chat.send")?.params).toEqual({ text: "hello remote" });
});

test.each([true, false])("peer events update a closed remote control only with the feature (%s)", async (supported) => {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const requests: string[] = [];
  let snapshotPeers = [{ name: "studio-mac", state: "connecting", lastSeen: null, error: null }];
  class PeerSocket extends MockAcpmuxSocket {
    override send(raw: string) {
      const request = JSON.parse(raw);
      requests.push(request.method);
      let result: unknown;
      if (request.method === "initialize")
        result = { protocolVersion: 1, _meta: { acpmux: { features: supported ? ["peerStateEvents"] : [] } } };
      else if (request.method === "_acpmux/status")
        result = { peers: [{ name: "studio-mac", transport: "ssh", state: "connected" }] };
      else if (request.method === "_acpmux/peers") result = { peers: snapshotPeers };
      else return super.send(raw);
      queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: request.id, result }) }));
    }
  }
  root = (await import("react-dom/client")).createRoot(host);
  const socket = new PeerSocket(() => Promise.resolve());
  let client: Awaited<ReturnType<typeof AcpmuxDirectClient.connect>> | undefined;
  try {
    await act(async () => {
      client = await AcpmuxDirectClient.connect(
        mockHost,
        (snapshot) =>
          root!.render(
            <ComposerContext
              summary={{ sessionId: "remote", host: "studio-mac", peer: "studio-mac" }}
              peers={snapshot.peers}
              peerKinds={snapshot.peerKinds}
              peerConnected={snapshot.peerConnected}
              peerStates={snapshot.peerStates}
              projectChoices={[]}
              onProject={() => undefined}
            />,
          ),
        undefined,
        () => socket as unknown as WebSocket,
      );
    });
    const state = () => host.querySelector(".acpmux-remote-location")?.getAttribute("data-state");
    expect(state()).toBe(supported ? "connecting" : "connected");
    for (const [wire, visual] of [
      ["connected", "connected"],
      ["reconnecting", "offline"],
      ["degraded", "connecting"],
      ["offline", "offline"],
    ]) {
      await act(async () =>
        socket.onmessage?.({
          data: JSON.stringify({
            jsonrpc: "2.0",
            method: "_acpmux/peer_state_changed",
            params: {
              peer: "studio-mac",
              state: wire,
              lastSeen: 1,
              error: wire === "offline" ? "removed" : null,
              at: 10,
            },
          }),
        }),
      );
      expect(state()).toBe(supported ? visual : "connected");
      expect(host.querySelector('[aria-expanded="true"]')).toBeNull();
    }
    if (supported) {
      snapshotPeers = [];
      await act(async () => client?.refreshPeers());
      expect(state()).toBe("unknown");
    }
    expect(requests.filter((method) => method === "_acpmux/peers")).toHaveLength(supported ? 2 : 0);
  } finally {
    await act(async () => client?.close());
  }
});
