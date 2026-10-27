// l10n-allow-file: test fixtures.
// The composer's third chip is the agent's permission mode (macOS 15 tester, 2026-10-19, on a
// company-managed Mac: "what is the third dropdown? it does not work"). A mode the agent or the
// company's managed settings refuse (Claude Code's disableBypassPermissionsMode) failed in silence:
// the chip kept showing the refused mode. Now the chip goes back to the mode in force, the refused
// row is disabled with the reason, and with nothing left to pick the chip is a plain label. Its
// tooltip says what the control is.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  const { resetStartModesForTests, setStartModeSource } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(undefined);
  resetStartModesForTests();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Summary = Record<string, unknown> | undefined;

function reported(sessionId: string, currentModeId: string): Summary {
  return {
    sessionId,
    harness: "claude",
    model: "default",
    turnCount: 0,
    modes: {
      currentModeId,
      availableModes: [
        { id: "default", name: "Ask before edits" },
        { id: "bypassPermissions", name: "Bypass permissions" },
      ],
    },
  };
}

async function render(
  summary: Summary,
  onMode: (modeId: string) => void | Promise<unknown>,
  where: Record<string, unknown> = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
  const snapshot = {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [],
    summary,
    ...where,
  } as unknown as Snapshot;
  function Host() {
    const picker = usePickerCatalog(snapshot.catalog, { harness: "claude" });
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        onModel={() => undefined}
        onMode={onMode}
        onEffort={() => undefined}
        onHarness={() => undefined}
        showPlan={false}
        holdsModePick
      />
    );
  }
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={new QueryClient()}>
        <Host />
      </QueryClientProvider>,
    );
  });
}

const flush = () => act(async () => await new Promise((done) => setTimeout(done, 0)));
const chipText = () => (host.querySelector(".acpmux-mode .acpmux-mode-text")?.textContent ?? "").trim();
const trigger = () => host.querySelector<HTMLElement>(".acpmux-access-trigger");
const item = (name: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-access-item")].find((row) =>
    row.textContent?.includes(name),
  );

test("the access chip's tooltip says what the control is", async () => {
  await render(reported("s1", "default"), () => undefined);
  const title = trigger()?.getAttribute("title") ?? "";
  // Claude Code's own name for its default mode (harnessModes.ts), not the reported one.
  expect(title).toContain("Manual");
  expect(title).toContain("What the agent may do without asking you");
});

test("a mode the agent refuses goes back to the mode in force and is marked refused", async () => {
  const picked: string[] = [];
  await render(reported("s1", "default"), (modeId) => {
    picked.push(modeId);
    return Promise.reject(new Error("bypassPermissions is disabled by managed settings"));
  });
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  await act(async () => item("Bypass permissions")!.click());
  await flush();
  expect(picked).toEqual(["bypassPermissions"]);
  // The chip shows the mode the session is really in, not the refused pick.
  expect(chipText()).toBe("Manual");
  expect(host.querySelector(".acpmux-mode")!.classList.contains("acpmux-unrestricted")).toBe(false);
  // Nothing else can be picked: the chip is a plain label, its tooltip says why.
  expect(trigger()).toBeNull();
  expect(host.querySelector(".acpmux-mode")!.getAttribute("title") ?? "").toContain("Not allowed on this Mac");
});

// #23322: an MDM-managed `sessions.allowFullAccess = false` is an upper bound the person can't
// override. acpmux's `_acpmux/start_mode` answer then says `"fullAccess": "managed"` (a mode-less
// answer too), and each full-access row is disabled and says so. An answer without the field (MDM
// unset, MDM true, an older daemon) leaves the menu as it was.
type Client = import("../src/agent-session/acpmux/direct").AcpmuxDirectClient;
async function answer(reply: Record<string, unknown>) {
  const direct = await import("../src/agent-session/acpmux/direct");
  const client: Client = Object.create(direct.AcpmuxDirectClient.prototype);
  (client as unknown as { request: () => Promise<unknown> }).request = async () => reply;
  await act(async () => void (await client.startMode("claude", "/Users/dev/project")));
}
const caption = (name: string) => item(name)?.querySelector(".acpmux-menu-description")?.textContent?.trim();
const disabled = (name: string) => item(name)?.getAttribute("aria-disabled") === "true";

test("full access managed off: its row is disabled, says so, and cannot be picked", async () => {
  const picked: string[] = [];
  await answer({ harness: "claude", modeId: null, fullAccess: "managed" });
  await render(reported("s1", "default"), (modeId) => void picked.push(modeId));
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  expect(disabled("Bypass permissions")).toBe(true);
  expect(caption("Bypass permissions")).toBe("Managed by your organization");
  expect(disabled("Manual")).toBe(false);
  await act(async () => item("Bypass permissions")!.click());
  const menu = dom.window.document.querySelector(".acpmux-access-menu")!;
  await act(async () => void menu.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "2", bubbles: true })));
  await flush();
  expect(picked).toEqual([]);
});

test("an answer without the managed field leaves full access as it was", async () => {
  const picked: string[] = [];
  await answer({ harness: "claude", modeId: null, fullAccess: "managed" });
  await answer({ harness: "claude", modeId: "default" });
  await render(reported("s1", "default"), (modeId) => void picked.push(modeId));
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  expect(disabled("Bypass permissions")).toBe(false);
  expect(caption("Bypass permissions")).toBe("Accepts all permissions");
  await act(async () => item("Bypass permissions")!.click());
  await flush();
  expect(picked).toEqual(["bypassPermissions"]);
});

test("an older answer that arrives after a newer ask failed does not change full access", async () => {
  // Managed off, then two asks across a push: the newer one fails (the socket closed) and the
  // older one (from before the push) answers without the field. Only the newest ask counts, so
  // the rows stay managed.
  await answer({ harness: "claude", modeId: null, fullAccess: "managed" });
  const direct = await import("../src/agent-session/acpmux/direct");
  const client: Client = Object.create(direct.AcpmuxDirectClient.prototype);
  let releaseOlder: (reply: unknown) => void = () => undefined;
  const replies: (() => Promise<unknown>)[] = [
    () => new Promise((done) => (releaseOlder = done)),
    () => Promise.reject(new Error("the socket closed")),
  ];
  let asked = 0;
  (client as unknown as { request: () => Promise<unknown> }).request = () => replies[asked++]!();
  let older: Promise<unknown> = Promise.resolve();
  await act(async () => {
    older = client.startMode("claude", "/Users/dev/project");
    await client.startMode("claude", "/Users/dev/project").catch(() => undefined);
  });
  await act(async () => {
    releaseOlder({ harness: "claude", modeId: "default" });
    await older;
  });
  await render(reported("s1", "default"), () => undefined);
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  expect(disabled("Bypass permissions")).toBe(true);
  expect(caption("Bypass permissions")).toBe("Managed by your organization");
});

test("an older answer that arrives after a newer one does not change full access", async () => {
  // Two asks in flight (a probe, then a push's new generation): the newer says managed off, the
  // older (from before the push) arrives last and must not turn the rows back on.
  const direct = await import("../src/agent-session/acpmux/direct");
  const client: Client = Object.create(direct.AcpmuxDirectClient.prototype);
  let releaseOlder: (reply: unknown) => void = () => undefined;
  const replies: Promise<unknown>[] = [
    new Promise((done) => (releaseOlder = done)),
    Promise.resolve({ harness: "claude", modeId: null, fullAccess: "managed" }),
  ];
  let asked = 0;
  (client as unknown as { request: () => Promise<unknown> }).request = () => replies[asked++]!;
  let older: Promise<unknown> = Promise.resolve();
  await act(async () => {
    older = client.startMode("claude", "/Users/dev/project");
    await client.startMode("claude", "/Users/dev/project");
  });
  await act(async () => {
    releaseOlder({ harness: "claude", modeId: "default" });
    await older;
  });
  await render(reported("s1", "default"), () => undefined);
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  expect(disabled("Bypass permissions")).toBe(true);
  expect(caption("Bypass permissions")).toBe("Managed by your organization");
});

test("a daemon that predates start_mode clears what the previous daemon said", async () => {
  // Managed off from the first daemon; the pane reconnects to an older one, which answers
  // method-not-found: the rows are no longer managed.
  await answer({ harness: "claude", modeId: null, fullAccess: "managed" });
  const direct = await import("../src/agent-session/acpmux/direct");
  const { AcpmuxRpcError } = await import("../src/agent-session/acpmux/handoff/protocol");
  const client: Client = Object.create(direct.AcpmuxDirectClient.prototype);
  (client as unknown as { request: () => Promise<unknown> }).request = () =>
    Promise.reject(new AcpmuxRpcError({ code: -32601, message: "Method not found" }));
  await act(async () => void (await client.startMode("claude", "/Users/dev/project")));
  await render(reported("s1", "default"), () => undefined);
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  expect(disabled("Bypass permissions")).toBe(false);
});

test("a refusal other than method-not-found keeps the managed mark", async () => {
  // Managed off, then the same daemon refuses one ask (invalid params, or any refusal other than
  // a missing method): it still manages full access, so the rows stay managed.
  await answer({ harness: "claude", modeId: null, fullAccess: "managed" });
  const direct = await import("../src/agent-session/acpmux/direct");
  const { AcpmuxRpcError } = await import("../src/agent-session/acpmux/handoff/protocol");
  const client: Client = Object.create(direct.AcpmuxDirectClient.prototype);
  (client as unknown as { request: () => Promise<unknown> }).request = () =>
    Promise.reject(new AcpmuxRpcError({ code: -32602, message: "Invalid params" }));
  await act(async () => void (await client.startMode("claude", "/Users/dev/project")));
  await render(reported("s1", "default"), () => undefined);
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  expect(disabled("Bypass permissions")).toBe(true);
  expect(caption("Bypass permissions")).toBe("Managed by your organization");
});

test("a full-access pick the agent refused says managed once full access is managed off", async () => {
  const startMode = await import("../src/agent-session/acpmux/startMode");
  await act(async () => startMode.setStartModeSource(async () => undefined));
  // The two-row menu: refusing Bypass leaves nothing else to pick, but managed keeps its row.
  await render(reported("s1", "default"), () =>
    Promise.reject(new Error("bypassPermissions is disabled by managed settings")),
  );
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  await act(async () => item("Bypass permissions")!.click());
  await flush();
  await answer({ harness: "claude", modeId: null, fullAccess: "managed" });
  await act(async () => void openPicker("Mode"));
  expect(disabled("Bypass permissions")).toBe(true);
  expect(caption("Bypass permissions")).toBe("Managed by your organization");
});

test("the managed mark is this Mac's: a peer's or another host's chat keeps its full access", async () => {
  // Review 37: the mark comes from this Mac's daemon, so a chat another machine runs (a peer, a
  // cloud or remote host) shown in the same pane is not managed by it.
  await answer({ harness: "claude", modeId: null, fullAccess: "managed" });
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  for (const [where, summary] of [
    [{ origin: "peer" }, reported("s1", "default")],
    [{}, { ...reported("s2", "default"), host: "studio" }],
    [{}, { ...reported("s3", "default"), hostKind: "cloud" }],
    // Review 110: a peers chat comes over this Macs own connection (origin "local"); only its
    // summary or its listed row says it is a peers. The attachs detail names no peer
    // (server/peer_forward.rs adds it to the reply, not to the session), so the listed row may
    // be all there is.
    [{ origin: "local" }, { ...reported("s4", "default"), peer: "studio" }],
    [{ origin: "local", sessions: [{ sessionId: "s5", peer: "studio" }] }, reported("s5", "default")],
  ] as const) {
    await render(summary, () => undefined, where);
    await act(async () => void openPicker("Mode"));
    expect(disabled("Bypass permissions")).toBe(false);
    expect(caption("Bypass permissions")).toBe("Accepts all permissions");
    act(() => root?.unmount());
    root = undefined;
  }
});

// Review 42: a New Tab's ask outside the roots the host relays fails. Review 45: a daemon's own
// refusal (an unavailable harness) answers nothing about full access either. Either way a local chat
// shown next in the same connection still asks, and its menu says managed.
for (const [why, first] of [
  [
    "an ask the host refused",
    {
      code: -32000,
      message: "outside the roots",
      data: { origin: "native", code: "transport.path_outside_roots", method: "_acpmux/start_mode" },
    },
  ],
  ["an ask the daemon refused", { code: -32602, message: "harness codex is not available" }],
] as const) {
  test(`${why} does not stop a shown chat from learning the managed mark`, async () => {
    const startMode = await import("../src/agent-session/acpmux/startMode");
    const direct = await import("../src/agent-session/acpmux/direct");
    const { AcpmuxRpcError } = await import("../src/agent-session/acpmux/handoff/protocol");
    const client: Client = Object.create(direct.AcpmuxDirectClient.prototype);
    let asked = 0;
    (client as unknown as { request: () => Promise<unknown> }).request = () => {
      asked += 1;
      return asked === 1
        ? Promise.reject(new AcpmuxRpcError(first))
        : Promise.resolve({ harness: "claude", modeId: null, fullAccess: "managed" });
    };
    await act(async () => startMode.setStartModeSource((harness, cwd) => client.startMode(harness, cwd)));
    await act(async () => void (await startMode.askStartMode("claude", "/Users/dev").catch(() => undefined)));
    expect(asked).toBe(1);
    await render(reported("s1", "default"), () => undefined);
    await flush();
    expect(asked).toBe(2);
    const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
    await act(async () => void openPicker("Mode"));
    expect(disabled("Bypass permissions")).toBe(true);
    expect(caption("Bypass permissions")).toBe("Managed by your organization");
  });
}

test("a full-access choice a chat offers only as a config option is managed too", async () => {
  // Review 48: a local chat reports its modes only as a `mode` config option (the Options chip).
  // It learns the managed mark, and the full-access choice there is disabled and says so.
  const startMode = await import("../src/agent-session/acpmux/startMode");
  let asked = 0;
  await act(async () =>
    startMode.setStartModeSource(async () => {
      asked += 1;
      startMode.rememberFullAccess("managed");
      return undefined;
    }),
  );
  const summary = {
    sessionId: "s1",
    harness: "custom",
    model: "default",
    turnCount: 1,
    configOptions: [
      {
        id: "mode",
        name: "Mode",
        category: "mode",
        currentValue: "default",
        options: [
          { value: "default", name: "Ask" },
          { value: "bypassPermissions", name: "Bypass permissions" },
        ],
      },
    ],
  };
  await render(summary, () => undefined);
  await flush();
  expect(asked).toBe(1);
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Options"));
  const row = [...dom.window.document.querySelectorAll<HTMLElement>("[role=menuitemradio]")].find((r) =>
    r.textContent?.includes("Bypass permissions"),
  );
  expect(row?.getAttribute("aria-disabled")).toBe("true");
  expect(row?.textContent).toContain("Managed by your organization");
});

test("a chat in full access whose narrower mode was refused keeps its menu once managed", async () => {
  // Review 48: the inverse of the two-row case. The current row is the full-access one; the only
  // other mode was refused. Managed off keeps the menu, with the current row saying why.
  await render(reported("s1", "bypassPermissions"), () => Promise.reject(new Error("default is not allowed here")));
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  await act(async () => item("Manual")!.click());
  await flush();
  await answer({ harness: "claude", modeId: null, fullAccess: "managed" });
  expect(trigger()).not.toBeNull();
  await act(async () => void openPicker("Mode"));
  expect(caption("Bypass permissions")).toBe("Managed by your organization");
});

test("a new connection forgets the managed mark, and a late answer from the old one changes nothing", async () => {
  const startMode = await import("../src/agent-session/acpmux/startMode");
  const direct = await import("../src/agent-session/acpmux/direct");
  const client: Client = Object.create(direct.AcpmuxDirectClient.prototype);
  let releaseOld: (reply: unknown) => void = () => undefined;
  (client as unknown as { request: () => Promise<unknown> }).request = () => new Promise((done) => (releaseOld = done));
  await answer({ harness: "claude", modeId: null, fullAccess: "managed" });
  let old: Promise<unknown> = Promise.resolve();
  await act(async () => {
    old = client.startMode("claude", "/Users/dev/project");
  });
  // The pane's connection is replaced (a reconnect, another daemon).
  await act(async () => {
    startMode.setStartModeSource(async () => undefined);
  });
  await act(async () => {
    releaseOld({ harness: "claude", modeId: null, fullAccess: "managed" });
    await old;
  });
  await render(reported("s1", "default"), () => undefined);
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Mode"));
  expect(disabled("Bypass permissions")).toBe(false);
  await act(async () => {
    startMode.setStartModeSource(undefined);
  });
});
