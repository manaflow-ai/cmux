import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

// Folder harness profiles (`<folder>/.cmux/harnesses/<id>.toml`, docs/add-your-harness.md): the
// New Tab page's Integrate a harness button, the picker's "This folder" group by state, and the
// host error card of a chat acpmux would not start until the profile is enabled. The Enable
// request carries only {folder, id}: the host confirms with the user and adds the hash itself.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "customElements",
    "Node",
    "getSelection",
    "MutationObserver",
    "IntersectionObserver",
    "ResizeObserver",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "WebSocket",
    "IS_REACT_ACT_ENVIRONMENT",
  ].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  getSelection: dom.window.getSelection.bind(dom.window),
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
Object.assign(dom.window, {
  matchMedia: () => ({ matches: true, addEventListener() {}, removeEventListener() {} }),
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp } = await import("./App");
const { normalizeFolderProfiles, harnessBlock } = await import("./direct");

const doc = dom.window.document;
const host = dom.window as unknown as Record<string, unknown> & {
  cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
};
const FOLDER = "/src/app";
const waitFor = async (done: () => boolean) => {
  for (let tries = 0; tries < 200 && !done(); tries += 1)
    await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
};

/// A loopback acpmux with one chat in FOLDER, whose profiles are Acme (needs Enable), Lint Bot
/// (needs the folder's Trust answer) and Broken (a bad command). Every request lands in `sent`.
function folderDaemon() {
  const sent: { method: string; params: any }[] = [];
  const enabled = new Set<string>();
  class Socket {
    static OPEN = 1;
    readyState = 0;
    onopen?: () => void;
    onerror?: () => void;
    onclose?: () => void;
    onmessage?: (message: { data: string }) => void;
    constructor() {
      queueMicrotask(() => {
        this.readyState = 1;
        this.onopen?.();
      });
    }
    send(raw: string) {
      const { id, method, params } = JSON.parse(raw) as { id: number; method: string; params: any };
      sent.push({ method, params });
      const reply = (body: Record<string, unknown>) =>
        queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ id, ...body }) }));
      const session = { sessionId: "s", harness: "claude", model: "opus", cwd: FOLDER };
      if (method === "session/new") {
        const harness = params?._meta?.acpmux?.harness;
        if ((harness === "acme" && !enabled.has("acme")) || harness === "lint-bot")
          return reply({
            error: {
              code: -32000,
              message: "folder harness is not enabled",
              data: {
                reason: harness === "acme" ? "harness.needs_enable" : "harness.needs_trust",
                harness,
                folder: FOLDER,
              },
            },
          });
        return reply({ result: { sessionId: `n-${harness}` } });
      }
      if (method === "_acpmux/harness_enable") {
        enabled.add(String(params?.id));
        return reply({ result: { enabled: { id: params?.id, folder: params?.folder } } });
      }
      const result =
        method === "_acpmux/watch"
          ? { sessions: [session] }
          : method === "_acpmux/attach"
            ? {
                session:
                  params.sessionId === "s" ? session : { ...session, sessionId: params.sessionId, harness: "acme" },
                events: [],
              }
            : method === "_acpmux/harnesses"
              ? {
                  harnesses: [
                    { id: "claude", name: "Claude Code", models: [{ id: "opus", name: "Opus" }] },
                    { id: "codex", name: "Codex", models: [{ id: "gpt-6-astra" }] },
                  ],
                  ...(params?.cwd === FOLDER
                    ? {
                        folderProfiles: [
                          {
                            id: "acme",
                            folder: FOLDER,
                            path: `${FOLDER}/.cmux/harnesses/acme.toml`,
                            state: enabled.has("acme") ? "enabled" : "needs-enable",
                            displayName: "Acme Agent",
                          },
                          { id: "lint-bot", folder: FOLDER, state: "needs-trust", displayName: "Lint Bot" },
                          {
                            id: "broken",
                            folder: FOLDER,
                            state: "error",
                            displayName: "Broken Agent",
                            diagnostics: [{ message: "command not found: broken-agent" }],
                          },
                        ],
                      }
                    : {}),
                }
              : {};
      reply({ result });
    }
    close() {
      this.readyState = 3;
    }
  }
  return { sent, Socket };
}

/// Renders the pane against `Socket` with the chat in FOLDER shown.
async function renderPane(Socket: unknown) {
  globals.WebSocket = Socket;
  host.webkit = {
    messageHandlers: {
      agentSession: {
        postMessage(message: { method: string }) {
          if (message.method !== "ready") return Promise.resolve({ ok: true, value: null });
          return Promise.resolve({
            ok: true,
            value: {
              protocolVersion: 1,
              transport: "acpmux-websocket",
              endpoint: "ws://127.0.0.1:4100/acp",
              token: "t",
              sessionId: "s",
            },
          });
        },
      },
    },
  };
  const root = createRoot(doc.getElementById("root")!);
  await act(async () => root.render(createElement(AcpmuxApp)));
  return async () => {
    await act(async () => root.unmount());
    delete host.webkit;
    delete host.cmuxAcpmuxActions;
  };
}

const enables = (sent: { method: string; params: any }[]) =>
  sent.filter((request) => request.method === "_acpmux/harness_enable").map((request) => request.params);

test("a harnesses reply's folder profiles read as catalog entries; a needs_enable refusal names its profile", () => {
  expect(
    normalizeFolderProfiles({
      folderProfiles: [
        { id: "acme", folder: FOLDER, path: `${FOLDER}/.cmux/harnesses/acme.toml`, state: "needs-enable" },
        { id: "broken", folder: FOLDER, state: "error", diagnostics: ["bad command"] },
        { id: "odd", folder: FOLDER, state: "sideways" },
        { folder: FOLDER, state: "enabled" },
      ],
    }),
  ).toEqual([
    {
      id: "acme",
      name: "acme",
      models: [],
      folder: { folder: FOLDER, path: `${FOLDER}/.cmux/harnesses/acme.toml`, state: "needs-enable" },
    },
    { id: "broken", name: "broken", models: [], folder: { folder: FOLDER, state: "error", diagnostic: "bad command" } },
  ]);
  expect(normalizeFolderProfiles({ harnesses: [] })).toEqual([]);
  expect(harnessBlock({ data: { reason: "harness.needs_enable", harness: "acme", folder: FOLDER } })).toEqual({
    reason: "needs-enable",
    harness: "acme",
    folder: FOLDER,
  });
  expect(harnessBlock({ data: { reason: "trust.pending" } })).toBeUndefined();
});

// Layout "a" is the Terminal | Browser | Agent page; "b" (the default) the one-field screen.
for (const layout of ["a", "b"] as const)
  test(`the New Tab ${layout === "a" ? "page" : "screen"}'s Integrate a harness button runs the host's palette.addHarness action`, async () => {
    const runs: unknown[] = [];
    host.cmuxAcpmuxActions = {
      // No daemon: the page stays the new tab page.
      ready: async () => ({
        protocolVersion: 1,
        transport: "test",
        newTab: layout === "a" ? { layout, kind: "agent" } : {},
      }),
      "action.run": async (params) => {
        runs.push(params);
        return {};
      },
    };
    const root = createRoot(doc.getElementById("root")!);
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      const button = () =>
        [
          ...doc.querySelectorAll<HTMLButtonElement>(
            layout === "a" ? ".acpmux-newtab-actions button" : ".nt-add-harness",
          ),
        ].find((candidate) => candidate.textContent === "Integrate a harness");
      await waitFor(() => button() !== undefined);
      expect(doc.querySelector(layout === "a" ? ".acpmux-newtab" : ".nt-screen")).not.toBeNull();
      await act(async () => button()!.click());
      expect(runs).toEqual([{ id: "palette.addHarness" }]);
    } finally {
      await act(async () => root.unmount());
      delete host.cmuxAcpmuxActions;
    }
  });

test("the picker groups the folder's profiles by state; a needs-enable pick sends harness_enable with only {folder, id}", async () => {
  const { sent, Socket } = folderDaemon();
  const unmount = await renderPane(Socket);
  const chip = () => doc.querySelector<HTMLButtonElement>('[aria-label="Model"].acpmux-picker-button');
  const menu = () => doc.querySelector<HTMLElement>(".acpmux-mp");
  const harnessRow = (name: string) =>
    [...doc.querySelectorAll<HTMLButtonElement>(".acpmux-mp-harness")].find(
      (row) => row.querySelector("span")?.textContent === name,
    );
  const models = () => doc.querySelector<HTMLElement>(".acpmux-mp-models");
  const open = async () => {
    if (!menu()) await act(async () => chip()!.click());
    await waitFor(() => harnessRow("Acme Agent") !== undefined);
  };
  try {
    // The chat's folder goes with the catalog request, so its profiles come back with it.
    await waitFor(() =>
      sent.some((request) => request.method === "_acpmux/harnesses" && request.params?.cwd === FOLDER),
    );
    await waitFor(() => chip() !== null);
    await open();
    // The folder's profiles stand after the harnesses, under their own heading, each with its state.
    const names = [...doc.querySelectorAll(".acpmux-mp-harness")].map((row) => row.querySelector("span")?.textContent);
    expect(names.slice(-3)).toEqual(["Acme Agent", "Lint Bot", "Broken Agent"]);
    expect(names).toContain("Codex");
    expect(menu()?.querySelector(".acpmux-mp-section")?.textContent).toBe("This folder");
    expect(harnessRow("Acme Agent")?.textContent).toContain("Enable…");
    expect(harnessRow("Lint Bot")?.textContent).toContain("Needs trust");
    expect(harnessRow("Broken Agent")?.textContent).toContain("Unavailable");

    // Needs trust and broken rows start nothing; they say why in place of models.
    await act(async () => harnessRow("Lint Bot")!.click());
    expect(models()?.textContent).toBe("Answer the folder's Trust question first");
    await act(async () => harnessRow("Broken Agent")!.click());
    expect(models()?.textContent).toBe("command not found: broken-agent");
    expect(sent.some((request) => request.method === "session/new")).toBe(false);
    expect(enables(sent)).toEqual([]);

    await act(async () => harnessRow("Acme Agent")!.click());
    expect(enables(sent)).toEqual([{ folder: FOLDER, id: "acme" }]);
    expect(menu()).toBeNull();
    // Once enabled, the chat starts on it.
    await waitFor(() =>
      sent.some((request) => request.method === "session/new" && request.params?._meta?.acpmux?.harness === "acme"),
    );
    expect(
      sent.some((request) => request.method === "session/new" && request.params?._meta?.acpmux?.harness === "acme"),
    ).toBe(true);
  } finally {
    await unmount();
  }
});

test("a chat refused for a needs-enable profile offers Enable harness…, which enables it and starts the chat again", async () => {
  const { sent, Socket } = folderDaemon();
  const unmount = await renderPane(Socket);
  const card = () => doc.querySelector<HTMLElement>(".acpmux-host-error-card");
  try {
    await waitFor(() => Boolean(host.cmuxAcpmuxActions?.["chat.new"]));
    await waitFor(() =>
      sent.some((request) => request.method === "_acpmux/harnesses" && request.params?.cwd === FOLDER),
    );

    // Needs trust: the card says what to do, with no button.
    await act(async () => void host.cmuxAcpmuxActions!["chat.new"]!({ harness: "lint-bot" }).catch(() => undefined));
    await waitFor(() => card()?.textContent?.includes("Trust question") === true);
    expect(card()?.textContent).toContain("Lint Bot");
    expect(card()?.querySelector("button")).toBeNull();

    await act(async () => void host.cmuxAcpmuxActions!["chat.new"]!({ harness: "acme" }).catch(() => undefined));
    await waitFor(() => card()?.textContent?.includes("Acme Agent") === true);
    expect(card()?.textContent).toContain(FOLDER);
    const button = card()!.querySelector<HTMLButtonElement>("button")!;
    expect(button.textContent).toBe("Enable harness…");
    const before = sent.filter((request) => request.method === "session/new").length;
    await act(async () => button.click());
    expect(enables(sent)).toEqual([{ folder: FOLDER, id: "acme" }]);
    await waitFor(() => sent.filter((request) => request.method === "session/new").length > before);
    expect(sent.filter((request) => request.method === "session/new").at(-1)?.params?._meta?.acpmux?.harness).toBe(
      "acme",
    );
    await waitFor(() => card() === null);
    expect(card()).toBeNull();
  } finally {
    await unmount();
  }
});
