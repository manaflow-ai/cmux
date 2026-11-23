// l10n-allow-file: test fixture rows, not shipped UI.
// The pane's checkpoints read whether the link to acpmux is up from the snapshot's `connection`,
// which names why the client last emitted. A read of `=== "connected"` took every later emit
// ("session changed", a streamed event's kind) for a lost link and marked checkpoints unsupported.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Event: dom.window.Event,
  KeyboardEvent: dom.window.KeyboardEvent,
  MouseEvent: dom.window.MouseEvent,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
(dom.window as unknown as { matchMedia: unknown }).matchMedia = replacements.matchMedia;
// jsdom has no layout. A tall viewport mounts every row of this small chat.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const fixtures = await import("../src/gallery/fixtures/acpmux");
const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
const window_ = dom.window as unknown as {
  webkit: unknown;
  cmuxAcpmuxBridge?: { receive(value: unknown): void };
};

/// The pane on a local chat in a folder whose repository takes checkpoints. The app's bridge
/// answers `ready`, `git.capabilities` says checkpoints are served, and each
/// `pane.checkpointAvailability` the pane sends is recorded.
async function pane() {
  const { assistant, chat, user } = fixtures;
  const snapshot = chat([user("Fix the build", 3, { id: "u1" }), assistant("Fixed.", 2.8, { id: "r1" })]);
  const availability: boolean[] = [];
  window_.webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method?: string; params?: Record<string, unknown> }) => {
          if (message.method === "ready") {
            setTimeout(() => window_.cmuxAcpmuxBridge?.receive(structuredClone(snapshot)), 0);
            return Promise.resolve({
              ok: true,
              value: { protocolVersion: 1, transport: "preview", machineName: "Mac" },
            });
          }
          if (message.method === "git.capabilities") return Promise.resolve({ ok: true, value: { checkpoints: true } });
          if (message.method === "pane.checkpointAvailability") availability.push(message.params?.available === true);
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  const settle = async () => {
    for (let pass = 0; pass < 20; pass += 1) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  };
  await act(async () => root.render(<AcpmuxApp />));
  for (let tries = 0; tries < 500 && availability.at(-1) !== true; tries += 1)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  /// The client's next emit for the same chat, for `reason` (snapshot `connection`).
  const emit = async (reason: string) => {
    await act(async () =>
      window_.cmuxAcpmuxBridge?.receive({ ...structuredClone(snapshot), connection: reason } as Snapshot),
    );
    await settle();
  };
  return { root, availability, emit };
}

// `connection` is why the client emitted, not whether the link is up (newtab/chatStore.ts): after
// the attach's "connected" come "session changed" (#31983 sends it right after a local chat opens)
// and every streamed event's kind. None of them takes the link down.
for (const reason of ["session changed", "agent_message_chunk", "history"])
  test(`checkpoints stay available when the chat's last emit was "${reason}"`, async () => {
    const view = await pane();
    try {
      expect(view.availability.at(-1)).toBe(true);
      await view.emit(reason);
      expect(view.availability.at(-1)).toBe(true);
    } finally {
      await act(async () => view.root.unmount());
    }
  });

test("checkpoints go offline when the link does", async () => {
  const view = await pane();
  try {
    expect(view.availability.at(-1)).toBe(true);
    await view.emit("disconnected");
    expect(view.availability.at(-1)).toBe(false);
  } finally {
    await act(async () => view.root.unmount());
  }
});

// Cloud chat recovery (App.tsx `cloudChatRecoveryActive`) and checkpoints read the same `linkUp`.
test("the link is up for every emit reason but a lost or opening connection", async () => {
  const { linkUp } = await import("../src/agent-session/acpmux/model");
  for (const reason of ["connected", "session changed", "agent_message_chunk", "history", "failed"])
    expect(linkUp(reason)).toBe(true);
  for (const reason of ["disconnected", "connecting", "connecting: socket closed"]) expect(linkUp(reason)).toBe(false);
});

// A Cloud chat whose open failed on a socket that stayed open (direct.ts emits "failed", with no
// rows and no `unavailable`: that is set only while no chat is selected) still reads its machine,
// and a paused machine shows the Resume card. "failed" is not a lost link, but the chat was never
// read, so cloud recovery treats it as one (#27031).
test("a Cloud chat whose open failed on an open socket shows its paused machine's Resume card", async () => {
  const { chat } = fixtures;
  const base = chat([]);
  const snapshot: Snapshot = {
    ...base,
    connection: "failed",
    summary: { ...base.summary!, hostKind: "cloud", turnCount: 3 },
  };
  const account = ["user", null];
  const reads: string[] = [];
  window_.webkit = {
    messageHandlers: {
      agentSession: {
        postMessage: (message: { method?: string }) => {
          if (message.method === "ready") {
            setTimeout(() => window_.cmuxAcpmuxBridge?.receive(structuredClone(snapshot)), 0);
            return Promise.resolve({
              ok: true,
              value: {
                protocolVersion: 1,
                transport: "preview",
                machineName: "Demo machine",
                cloudMachineID: "vm-demo",
                cloudAccount: account,
              },
            });
          }
          if (message.method === "cloudMachine.recoveryList") {
            reads.push(message.method);
            return Promise.resolve({
              ok: true,
              value: {
                signedIn: true,
                loaded: true,
                complete: true,
                account,
                machines: [{ id: "vm-demo", name: "Demo machine", stage: "paused" }],
              },
            });
          }
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  const resume = () => dom.window.document.querySelector('[data-action="resumeMachine"]');
  try {
    await act(async () => root.render(<AcpmuxApp />));
    // The paused card shows once the pause has lasted RESUME_NOTE_DELAY_MS (afterDelay.ts): wait
    // for it, with a cap well past that threshold.
    const deadline = Date.now() + 5_000;
    while (!resume() && Date.now() < deadline) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(reads.length).toBeGreaterThan(0);
    expect(resume()).not.toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});
