// An adopted New Tab spare draws its sign-in line in the first frame it shows (Leo, 2026-11-08: "the
// animation makes the thing blank in between ... until we meet the claude video's performance, i am
// not satisfied"). A spare in the pool knows no chat start folder, so it checks its harness's sign-in
// with no folder (`{ target: { harness } }`); the Cmd-T that adopts it names the folder (`startCwd`,
// applied in place, adoption.ts), which is a new check, and a new check asks acpmux to probe again.
// The page drew no verdict until that probe answered, 470-790 ms after the key on a fleet bench: then
// the signed-out line came in over the composer and pushed the composer and the list down. The page
// now keeps drawing the verdict it has for the same harness and machine while the folder's check
// runs; that check alone still decides, and it still never holds a send (Leo 2026-10-30).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { noChat } from "../src/gallery/fixtures/acpmux";
import { teardownDom } from "./support/domTeardown";

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
    ResizeObserver: (window as unknown as { ResizeObserver: unknown }).ResizeObserver,
    KeyboardEvent: window.KeyboardEvent,
    InputEvent: window.InputEvent,
    FocusEvent: window.FocusEvent,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  for (const key of Object.getOwnPropertyNames(window))
    if (/^(HTML|SVG|CSS|Shadow|Document)/.test(key) && !(key in scope)) {
      added.push(key);
      scope[key] = (window as unknown as Record<string, unknown>)[key];
    }
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  for (const key of added) delete scope[key];
  await teardownDom(saved, { scope });
});

const noop = () => {};
const FOLDER = "/Users/you/src/app";
const SIGNED_OUT = {
  state: "signedOut",
  source: "authCheck",
  evidenceAt: 1,
  harness: "codex",
  host: null,
  login: { kind: "terminal", command: "codex login" },
};

/// The spare's New Tab screen (no start folder), its sign-in check answered, then the adopt that
/// names the folder: `answer` is what the folder's check answers, or never when undefined.
async function adoptedSpare(answer: (() => Promise<unknown>) | undefined) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { NewTabScreen } = await import("../src/agent-session/acpmux/newtab/NewTabScreen");
  const { SignInContext } = await import("../src/agent-session/acpmux/signIn");
  const queries: unknown[] = [];
  const asks: unknown[][] = [];
  const readSessionAuth = (query: unknown) => {
    queries.push(query);
    if (!JSON.stringify(query).includes(FOLDER)) return Promise.resolve(SIGNED_OUT);
    return answer ? answer() : new Promise<unknown>(noop);
  };
  const client = new QueryClient();
  const root: Root = createRoot(host);
  const page = (startCwd: string | undefined) => (
    <QueryClientProvider client={client}>
      <SignInContext.Provider value={{ signedOut: {}, logIn: noop, readSessionAuth }}>
        <NewTabScreen
          template="default"
          snapshot={noChat()}
          lastAgent="codex"
          cwd={FOLDER}
          {...(startCwd ? { startCwd } : {})}
          onAsk={(...args) => void asks.push(args)}
          onOpen={noop}
          onSearch={noop}
          onShell={noop}
          onJump={noop}
          onOpenSession={noop}
          onShowAll={noop}
        />
      </SignInContext.Provider>
    </QueryClientProvider>
  );
  await act(async () => root.render(page(undefined)));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const line = () => host.querySelector(".nt-composer .acpmux-composer-remote-note")?.textContent ?? undefined;
  const spareLine = line();
  // The adopt event renders inside itself (adoption.ts useNewTabAdoption, flushSync): what this
  // render commits is the first frame the pane shows.
  await act(async () => root.render(page(FOLDER)));
  return { root, queries, asks, spareLine, line, editor: () => host.querySelector<MarkdownFieldElement>(".nt-field")! };
}

test("an adopted spare draws its harness's sign-in line in its first shown frame", async () => {
  const page = await adoptedSpare(undefined);
  try {
    expect(page.queries).toEqual([{ target: { harness: "codex" } }, { target: { harness: "codex", cwd: FOLDER } }]);
    expect(page.spareLine).toContain("Codex");
    // The folder's own check has not answered: the line the spare drew stays, so nothing moves.
    expect(page.line()).toBe(page.spareLine);
  } finally {
    await act(async () => page.root.unmount());
  }
});

test("the drawn line never holds a send while the folder's check runs", async () => {
  const page = await adoptedSpare(undefined);
  try {
    const field = page.editor();
    for (let turn = 0; turn < 200 && !(field.acpmuxMarkdownField && field.querySelector("[contenteditable]")); turn++)
      await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    const handle = field.acpmuxMarkdownField!;
    await act(async () => handle.writeText("fix the build", 13, 13));
    const editor = field.querySelector<HTMLElement>("[contenteditable]")!;
    await act(async () =>
      editor.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })),
    );
    expect(page.asks).toHaveLength(1);
  } finally {
    await act(async () => page.root.unmount());
  }
});

test("the folder's own answer replaces the line the spare drew", async () => {
  const page = await adoptedSpare(async () => ({
    state: "ready",
    source: "authCheck",
    evidenceAt: 2,
    harness: "codex",
    host: null,
  }));
  try {
    await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
    expect(page.line()).toBeUndefined();
  } finally {
    await act(async () => page.root.unmount());
  }
});
