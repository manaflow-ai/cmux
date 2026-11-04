// A signed-out Claude (cx-gz0dz, dogfood run hq #1893): the claude harness acpmux found on PATH
// has no profile, so the catalog names no login command, and the failed turn offered only Copy
// error. The chat's login now falls back to acpmux's harness health row (`claude auth login`), so
// Sign in again opens a terminal tab that runs it, and a sign-in failure also offers Switch model,
// where the chat can move to a Claude route that works.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // The menu places itself with floating-ui, which reads the page's styles.
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent)/.test(key) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
const { TurnActionsContext, chatLoginCommand } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { signedOutHarnesses } = await import("../src/agent-session/acpmux/signIn");

const host = dom.window.document.getElementById("root")!;
const root = createRoot(host);

afterAll(() => {
  act(() => root.unmount());
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const failed = {
  id: "summary-2",
  version: 1,
  at: Date.now(),
  kind: "turnSummary",
  seq: 2,
  status: "failed",
  error: "Invalid API key · Please run /login",
  prompt: "Tighten the retry comment",
  retryRowId: "user-1",
};
const button = (label: string) =>
  [...dom.window.document.querySelectorAll("button")].find((element) => element.textContent === label);

test("a signed-out harness offers Sign in again and Switch model", async () => {
  const opened: string[] = [];
  let switched = 0;
  const login = chatLoginCommand([{ id: "claude", name: "Claude Code", models: [] }], "claude", {
    id: "claude",
    auth: "signedOut",
    login: "claude auth login",
  });
  expect(login).toBe("claude auth login");
  const actions = {
    reauthenticate: () => opened.push(login!),
    switchModel: () => (switched += 1),
  };
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <TurnFooter row={failed} />
      </TurnActionsContext.Provider>,
    ),
  );
  await act(async () => button("Sign in again")!.click());
  await act(async () => button("Switch model")!.click());
  expect(opened).toEqual(["claude auth login"]);
  expect(switched).toBe(1);
  expect(button("Copy error")).toBeDefined();
});

test("the model picker's signed-out harnesses include an expired sign-in", () => {
  expect(
    signedOutHarnesses([
      { id: "claude", auth: "expired", login: "claude auth login" },
      { id: "codex", auth: "signedOut", login: "codex login" },
      { id: "grok", auth: "unknown", login: "grok login" },
      { id: "opencode", auth: "signedIn" },
    ]),
  ).toEqual({ claude: "claude auth login", codex: "codex login" });
});

test("the health row's account-home-qualified login wins over the catalog fallback", () => {
  expect(
    chatLoginCommand([{ id: "claude-sr", name: "Claude", models: [], auth: { login: "sr login" } }], "claude-sr", {
      id: "claude-sr",
      login: "claude auth login",
    }),
  ).toBe("claude auth login");
  expect(chatLoginCommand([], "codex", undefined)).toBeUndefined();
});
