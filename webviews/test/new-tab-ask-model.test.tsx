// Return on a New Tab page starts the chat on the model its chip names (dogfood run 5). With
// nothing picked yet the chip names the agent's catalog default ("Claude Sonnet 5"), but the
// page asked `chat.new` with no model, so the chat started on whatever the agent itself
// defaults to (Opus 5.5 on that account): the chip promised one model and the chat ran another.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { ComponentProps } from "react";
import type { NewTabScreen } from "../src/agent-session/acpmux/newtab/NewTabScreen";
import type { Root } from "react-dom/client";
import { noChat } from "../src/gallery/fixtures/acpmux";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "IS_REACT_ACT_ENVIRONMENT",
  "Node",
  "Element",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
  "customElements",
  "MutationObserver",
  "ResizeObserver",
  "getSelection",
  "KeyboardEvent",
  "InputEvent",
  "FocusEvent",
] as const;
const added: string[] = [];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let window: JSDOM["window"];
let host: HTMLElement;

beforeAll(() => {
  window = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "http://localhost/" })
    .window;
  Object.assign(window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    Element: window.Element,
    getComputedStyle: window.getComputedStyle.bind(window),
    requestAnimationFrame: (run: (time: number) => void) => setTimeout(() => run(0), 0),
    cancelAnimationFrame: (id: number) => clearTimeout(id),
    localStorage: window.localStorage,
    customElements: window.customElements,
    // The composer's footer row fits its chips to its width (composerRowFit.ts) on every New Tab.
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  // Pierre's registered elements (App's diff view) read their own DOM constructors at import time.
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const key of added) delete scope[key];
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const noop = () => {};

test("Return on a New Tab asks the agent on the model its chip names", async () => {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { newTabScreenActions } = await import("../src/agent-session/acpmux/newtab/screenActions");
  const { NewTabComposerChips } = await import("../src/agent-session/acpmux/App");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const calls: { method: string; params?: Record<string, unknown> }[] = [];
  (window as unknown as { cmuxAcpmuxActions: unknown }).cmuxAcpmuxActions = new Proxy(
    {},
    { get: () => async () => undefined },
  );
  const actions = newTabScreenActions({
    callNative: async (method, params) => void calls.push({ method, params }),
    leave: noop,
    selectSession: noop,
    showAllChats: noop,
    runShell: noop,
  });
  const root: Root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <QueryClientProvider client={new QueryClient()}>
          <NewTabScreen
            snapshot={noChat()}
            lastAgent="claude"
            cwd="/Users/you/src/app"
            chips={NewTabComposerChips}
            {...actions}
          />
        </QueryClientProvider>,
      ),
    );
    const chip = host.querySelector(".acpmux-model-name")?.textContent ?? "";
    const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
    for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    const handle = field.acpmuxMarkdownField!;
    await act(async () => {
      handle.focus();
      handle.type("fix the flaky upload test");
    });
    expect(handle.value()).toBe("fix the flaky upload test");
    const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
    await act(async () => {
      editor.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    });
    const asked = calls.find((call) => call.method === "chat.new")?.params;
    const models = BUNDLED_MODEL_CATALOG.harnesses.find((entry) => entry.id === "claude")!.models;
    // The model the chip names, by its catalog name, with or without the brand ("Opus 5.5" and
    // "Claude Opus 5.5" name the same model).
    const plain = (name: string) => name.replace(/^Claude /, "");
    const shown = models.find((model) => plain(model.name) === plain(chip));
    expect(shown).toBeDefined();
    expect({ chip, harness: asked?.harness, model: asked?.model }).toEqual({
      chip,
      harness: "claude",
      model: shown!.id,
    });
  } finally {
    await act(async () => root.unmount());
  }
});

test("New Tab preflights its selected harness and keeps a refused draft", async () => {
  // The test above started a chat on Claude: that is the last pick now (lastPick.ts), which a New
  // Tab's harness follows over the app's remembered agent. This page has none.
  window.localStorage.clear();
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { SignInContext } = await import("../src/agent-session/acpmux/signIn");
  const queries: unknown[] = [];
  const asks: unknown[] = [];
  const readSessionAuth = async (query: unknown) => {
    queries.push(query);
    return { state: "expired", source: "authCheck", evidenceAt: 1, harness: "codex", host: null };
  };
  const root = createRoot(host);
  try {
    await act(async () =>
      root.render(
        <QueryClientProvider client={new QueryClient()}>
          <SignInContext.Provider value={{ signedOut: {}, logIn: noop, readSessionAuth }}>
            <NewTabScreen
              snapshot={noChat()}
              lastAgent="codex"
              cwd="/Users/you/src/app"
              onAsk={(...args) => {
                asks.push(args);
              }}
              onOpen={noop}
              onSearch={noop}
              onShell={noop}
              onJump={noop}
              onOpenSession={noop}
              onShowAll={noop}
            />
          </SignInContext.Provider>
        </QueryClientProvider>,
      ),
    );
    expect(queries).toEqual([{ target: { harness: "codex", cwd: "/Users/you/src/app" } }]);
    const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
    for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    const handle = field.acpmuxMarkdownField!;
    handle.writeText("keep this draft", "keep this draft".length, "keep this draft".length);
    const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
    await act(async () =>
      editor.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
    );
    expect(asks).toEqual([]);
    expect(handle.plainText()).toBe("keep this draft");
    expect(host.querySelector("[role=alert]")?.textContent).toContain("expired");
  } finally {
    await act(async () => root.unmount());
  }
});

/// A New Tab with the draft typed whose harness's sign-in check answers `auth`, or never answers.
/// `onAsk` stands in for the start: by default it is taken at once.
async function newTabPage(
  options: {
    auth?: unknown;
    onAsk?: (...args: unknown[]) => unknown;
    launch?: Pick<ComponentProps<typeof NewTabScreen>, "runMode" | "onCloud" | "onSandbox">;
  } = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { SignInContext } = await import("../src/agent-session/acpmux/signIn");
  const asks: unknown[][] = [];
  const queries: unknown[] = [];
  const readSessionAuth = (query: unknown) => {
    queries.push(query);
    return options.auth === undefined ? new Promise<unknown>(noop) : Promise.resolve(options.auth);
  };
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <QueryClientProvider client={new QueryClient()}>
        <SignInContext.Provider value={{ signedOut: {}, logIn: noop, readSessionAuth }}>
          <NewTabScreen
            {...options.launch}
            snapshot={noChat()}
            lastAgent="codex"
            cwd="/Users/you/src/app"
            onAsk={(...args) => {
              asks.push(args);
              return options.onAsk?.(...args) as void;
            }}
            onOpen={noop}
            onSearch={noop}
            onShell={noop}
            onJump={noop}
            onOpenSession={noop}
            onShowAll={noop}
          />
        </SignInContext.Provider>
      </QueryClientProvider>,
    ),
  );
  const field = host.querySelector<MarkdownFieldElement>(".nt-field")!;
  for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const handle = field.acpmuxMarkdownField!;
  const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
  const type = async (text: string) =>
    act(async () => {
      handle.writeText(text, text.length, text.length);
    });
  await type("fix the flaky upload test");
  const pressReturn = async () =>
    act(async () =>
      editor.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
    );
  const status = () => host.querySelector(".nt-composer output.acpmux-hidden-label")?.textContent;
  const sendSpins = () => host.querySelector(".nt-send[data-starting] .cv-spinner") !== null;
  const alert = () => host.querySelector(".nt-composer [role=alert]")?.textContent;
  return {
    root,
    field: {
      get value() {
        return handle.plainText();
      },
    },
    asks,
    queries,
    type,
    pressReturn,
    status,
    sendSpins,
    alert,
  };
}

const READY = { state: "ready", source: "authCheck", evidenceAt: 1, harness: "codex", host: null };

// Return right after Cmd-T, while the harness's sign-in check still runs: the page refused the ask,
// so Return, the Ask row and New chat did nothing (cmuxterm-hq#5368; Leo 2026-10-30: "the fact that
// enter/click/send button doesn't work is extermely shit"). The check has no deadline and a busy
// daemon can take many seconds over it, so it never holds a send: the turn reports a sign-in that
// turns out missing.
test("Return during a sign-in check that never answers asks at once", async () => {
  const page = await newTabPage();
  try {
    await page.pressReturn();
    expect(page.asks).toHaveLength(1);
    expect(page.asks[0]?.slice(0, 2)).toEqual(["codex", "fix the flaky upload test"]);
  } finally {
    await act(async () => page.root.unmount());
  }
});

test("an Ask row click and New chat during the sign-in check ask at once", async () => {
  for (const selector of ['.nt-row[data-type="ask"]', '[data-create="chat"]']) {
    const page = await newTabPage();
    try {
      const target = window.document.querySelector(selector);
      expect(target).not.toBeNull();
      await act(async () => {
        target!.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
        target!.dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
      });
      expect(page.asks).toHaveLength(1);
      expect(page.asks[0]?.slice(0, 2)).toEqual(["codex", "fix the flaky upload test"]);
    } finally {
      await act(async () => page.root.unmount());
    }
  }
});

// Leo typed "helo" (the page offered "Ask Claude Code · …", Search the web for helo, New terminal,
// New chat): Return asks the agent with that prompt, the check answered or not.
test("Return on a one-word prompt asks with that prompt", async () => {
  for (const auth of [undefined, READY]) {
    const page = await newTabPage({ auth });
    try {
      await page.type("helo");
      await page.pressReturn();
      expect(page.asks).toHaveLength(1);
      expect(page.asks[0]?.slice(0, 2)).toEqual(["codex", "helo"]);
    } finally {
      await act(async () => page.root.unmount());
    }
  }
});

// A start that has not answered, while the page still shows (a chat on another machine or in no
// project leaves only once it started; before acpmux's handshake every start waits): the page says
// the chat is starting (Send spins in its own box; the words are for screen readers, so nothing
// moves, Leo 2026-11-01), and a second Return sends nothing more.
test("a chat start that has not answered says it is starting", async () => {
  const page = await newTabPage({ auth: READY, onAsk: () => new Promise(noop) });
  try {
    await page.pressReturn();
    expect(page.asks).toHaveLength(1);
    expect(page.status()).toBe("Starting Codex…");
    expect(page.sendSpins()).toBe(true);
    expect(host.querySelector(".nt-composer .acpmux-composer-remote-note")).toBeNull();
    await page.pressReturn();
    expect(page.asks).toHaveLength(1);
  } finally {
    await act(async () => page.root.unmount());
  }
});

test("a chat start that fails says why over the kept draft, and Return tries again", async () => {
  let fail = true;
  const page = await newTabPage({
    auth: READY,
    onAsk: () => (fail ? Promise.reject(new Error("no harness session within 90s")) : undefined),
  });
  try {
    await page.pressReturn();
    expect(page.asks).toHaveLength(1);
    expect(page.status()).toBeUndefined();
    expect(page.alert()).toContain("no harness session within 90s");
    expect(page.field.value).toBe("fix the flaky upload test");
    fail = false;
    await page.pressReturn();
    expect(page.asks).toHaveLength(2);
    expect(page.asks[1]?.slice(0, 2)).toEqual(["codex", "fix the flaky upload test"]);
  } finally {
    await act(async () => page.root.unmount());
  }
});

for (const mode of ["cloud", "sandboxed"] as const) {
  test(`${mode} launch does not query or obey auth on the local machine`, async () => {
    const launches: unknown[][] = [];
    const launch = (...args: unknown[]) => {
      launches.push(args);
      return true;
    };
    const page = await newTabPage({
      auth: { ...READY, state: "expired" },
      launch: {
        runMode: { mode, onMode: noop },
        ...(mode === "cloud" ? { onCloud: launch } : { onSandbox: launch }),
      },
    });
    try {
      await page.pressReturn();
      expect(page.queries).toEqual([]);
      expect(launches).toHaveLength(1);
      expect(launches[0]?.slice(0, 2)).toEqual(["codex", "fix the flaky upload test"]);
      expect(page.asks).toEqual([]);
    } finally {
      await act(async () => page.root.unmount());
    }
  });
}

test("Cloud mode without its launch handler still checks the local fallback", async () => {
  const page = await newTabPage({
    auth: { ...READY, state: "expired" },
    launch: { runMode: { mode: "cloud", onMode: noop } },
  });
  try {
    await page.pressReturn();
    expect(page.queries).toEqual([{ target: { harness: "codex", cwd: "/Users/you/src/app" } }]);
    expect(page.asks).toEqual([]);
    expect(page.field.value).toBe("fix the flaky upload test");
  } finally {
    await act(async () => page.root.unmount());
  }
});
