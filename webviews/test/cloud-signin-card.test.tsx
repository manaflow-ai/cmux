// A Cloud chat whose agent is not signed in on its machine offers that agent's own sign-in there
// (Leo 2026-11-01, on the one-click sign-in: "yes those are important"): never a copy of this
// Mac's login. The card runs acpmux's `_acpmux/agent_login/*` on the chat's connection, opens the
// provider's page, takes Claude's code (or shows Codex's), then sends the failed prompt again on
// the person's click. These tests drive the card and its wire with a mocked client.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { cloudAgentLogin, loginFailure, signInURL } from "../src/agent-session/acpmux/cloudAgentLogin";

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
  Event: dom.window.Event,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (
    /^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|PointerEvent|MouseEvent|FocusEvent|InputEvent|SubmitEvent)/.test(
      key,
    ) &&
    !(key in scope)
  )
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { TurnFooter } = await import("../src/agent-session/acpmux/conversation/TurnRows");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
type TurnActions = import("../src/agent-session/acpmux/conversation/turnActions").TurnActions;

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

const PROMPT = "Run the sidebar tests and fix what fails";
const failed = (error = "Not logged in · Please run /login") => ({
  id: "summary-1",
  kind: "turnSummary" as const,
  version: 1,
  at: 1000,
  status: "failed" as const,
  error,
  prompt: PROMPT,
  retryRowId: "user-1",
});
const cloudRoute = { name: "Claude Code", harness: "claude", hostKind: "cloud" as const };

const flush = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
const buttons = () => [...host.querySelectorAll("button")];
const button = (label: string) => buttons().find((element) => element.textContent === label);
const labels = () => [...host.querySelectorAll(".cv-turn-error__actions button")].map((element) => element.textContent);
const typeInto = async (input: HTMLInputElement, value: string) =>
  act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, value);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });

/// A client with acpmux's agent_login methods, recording each call; `replies` answers them.
function mockClient(replies: Partial<Record<string, (...args: unknown[]) => unknown>> = {}) {
  const calls: unknown[][] = [];
  const sent: unknown[][] = [];
  const answer = (name: string, args: unknown[]) => {
    calls.push([name, ...args]);
    const reply = replies[name];
    return Promise.resolve().then(() => (reply ? reply(...args) : undefined));
  };
  const client = {
    selectedSession: "chat-1",
    agentLoginStart: (...args: unknown[]) => answer("start", args),
    agentLoginFinish: (...args: unknown[]) => answer("finish", args),
    agentLoginApiKey: (...args: unknown[]) => answer("apiKey", args),
    agentLoginCancel: (...args: unknown[]) => answer("cancel", args),
    resendPrompt: async (rowId: string, text: string) => {
      calls.push(["resendPrompt", rowId, text]);
      return { input: text, attachments: [] };
    },
    send: async (...args: unknown[]) => {
      sent.push(args);
      return undefined;
    },
  };
  return { client, calls, sent };
}

function signInFor(
  client: ReturnType<typeof mockClient>["client"],
  options: { harness?: string; tickets?: (string | undefined)[]; opened?: string[]; supported?: boolean } = {},
) {
  const tickets = options.tickets ?? ["ticket-1", "ticket-2"];
  const intents: unknown[] = [];
  const signIn = cloudAgentLogin({
    connected: true,
    machineID: "provider-vm-1",
    sessionId: "chat-1",
    harness: options.harness ?? "claude",
    supported: options.supported ?? true,
    gesture: async (intent) => {
      intents.push(intent);
      return tickets.shift();
    },
    openURL: (url) => options.opened?.push(url),
    isCurrent: () => true,
    currentClient: () => client as never,
  });
  return { signIn, intents };
}

async function render(actions: TurnActions, error?: string) {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <TurnFooter row={failed(error)} />
      </TurnActionsContext.Provider>,
    ),
  );
}

beforeEach(async () => {
  await act(async () => root.render(<></>));
});

test("only an allowed provider page over https opens", () => {
  expect(signInURL("https://claude.ai/oauth/authorize?code=true")).toBe("https://claude.ai/oauth/authorize?code=true");
  expect(signInURL("https://auth.openai.com/codex/device")).toBe("https://auth.openai.com/codex/device");
  expect(signInURL("https://platform.claude.com/oauth/code/callback")).toBeDefined();
  expect(signInURL("http://claude.ai/oauth/authorize")).toBeUndefined();
  expect(signInURL("https://claude.ai.evil.example/oauth")).toBeUndefined();
  expect(signInURL("https://user:pass@claude.ai/oauth")).toBeUndefined();
  expect(signInURL("https://evil.example/?next=https://claude.ai")).toBeUndefined();
  expect(signInURL("javascript:alert(1)")).toBeUndefined();
  expect(signInURL(undefined)).toBeUndefined();
});

test("each refusal reason has its own failure", () => {
  const refusal = (reason: string) => Object.assign(new Error("refused"), { reason });
  expect(loginFailure(refusal("bad_code"))).toBe("bad_code");
  expect(loginFailure(refusal("expired"))).toBe("expired");
  expect(loginFailure(refusal("unknown_login"))).toBe("expired");
  expect(loginFailure(refusal("shared_machine"))).toBe("shared_machine");
  expect(loginFailure(refusal("cli_missing"))).toBe("cli_missing");
  expect(loginFailure(refusal("busy"))).toBe("busy");
  expect(loginFailure(refusal("remote_refused"))).toBe("remote_refused");
  expect(loginFailure(refusal("unknown_session"))).toBe("unknown_session");
  expect(loginFailure(refusal("no_url"))).toBe("failed");
  expect(loginFailure(refusal("unsupported_agent"))).toBe("unsupported");
  expect(loginFailure(Object.assign(new Error("Method not found"), { code: -32601 }))).toBe("unsupported");
  expect(loginFailure(Object.assign(new Error("Refused"), { code: "transport.method_refused" }))).toBe("unsupported");
  expect(loginFailure(Object.assign(new Error("Refused"), { code: "remote.unsupported" }))).toBe("unsupported");
  // A Cloud chat's daemon without the relay, or a machine's acpmux without the method.
  expect(
    loginFailure(Object.assign(new Error("refused"), { code: "agent_login.refused", reason: "unsupported" })),
  ).toBe("unsupported");
  expect(loginFailure(new Error("socket closed"))).toBe("failed");
});

test("the sign-in is offered only for a connected Cloud Claude or Codex chat on an acpmux with agent_login", () => {
  const { client } = mockClient();
  const base = {
    connected: true,
    machineID: "vm",
    sessionId: "chat-1",
    harness: "claude",
    supported: true,
    gesture: async () => undefined,
    openURL: () => undefined,
    isCurrent: () => true,
    currentClient: () => client as never,
  };
  expect(cloudAgentLogin(base)?.agent).toBe("claude");
  expect(cloudAgentLogin({ ...base, harness: "codex" })?.agent).toBe("codex");
  expect(cloudAgentLogin({ ...base, harness: "opencode" })).toBeUndefined();
  expect(cloudAgentLogin({ ...base, machineID: undefined })).toBeUndefined();
  expect(cloudAgentLogin({ ...base, connected: false })).toBeUndefined();
  expect(cloudAgentLogin({ ...base, supported: false })).toBeUndefined();
});

test("a Cloud sign-in failure leads with Sign in to Claude, then Use an API key", async () => {
  const { client } = mockClient();
  const { signIn } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn, switchModel: () => undefined });
  expect(labels().slice(0, 3)).toEqual(["Sign in to Claude", "Use an API key", "Switch model"]);
  expect(button("Sign in to Claude")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Use an API key")!.classList.contains("cv-turn-error__primary")).toBe(false);
  expect(button("Switch model")!.classList.contains("cv-turn-error__primary")).toBe(false);
  // Without the Mac-token transfer there is no Set up credentials button.
  expect(button("Set up Claude Code credentials")).toBeUndefined();
});

test("no sign-in where acpmux lacks agent_login, or on another failure", async () => {
  await render({ route: cloudRoute, switchModel: () => undefined });
  expect(button("Sign in to Claude")).toBeUndefined();
  const { client } = mockClient();
  const { signIn } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn, retry: () => undefined }, "API Error: 529 overloaded_error");
  expect(button("Sign in to Claude")).toBeUndefined();
});

test("in DEV the credential transfer stays beside the sign-in", async () => {
  const { client } = mockClient();
  const { signIn } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn, transferCloudCredentials: async () => undefined });
  expect(button("Sign in to Claude")).toBeDefined();
  expect(button("Set up Claude Code credentials")).toBeDefined();
});

test("Claude: start, open the page, paste the code, finish, then send the failed prompt again", async () => {
  const opened: string[] = [];
  const { client, calls, sent } = mockClient({
    start: () => ({
      loginId: "login-1",
      url: "https://claude.ai/oauth/authorize?code=true",
      needsCode: true,
      expiresAtMs: Date.now() + 600_000,
    }),
    finish: () => ({ signedIn: true, restarted: true }),
  });
  const { signIn, intents } = signInFor(client, { opened });
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  // Every call names the chat, so the sign-in runs on the chat's machine.
  expect(calls[0]).toEqual(["start", "claude", "chat-1"]);
  // The Sign in click's gesture went to the start: the page opens on its own click, which leads.
  expect(opened).toEqual([]);
  expect(host.textContent).toContain("Approve in your browser, then paste the code it shows.");
  expect(button("Open sign-in page")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Continue")!.classList.contains("cv-turn-error__primary")).toBe(false);
  await act(async () => button("Open sign-in page")!.click());
  expect(opened).toEqual(["https://claude.ai/oauth/authorize?code=true"]);
  expect(button("Continue")!.classList.contains("cv-turn-error__primary")).toBe(true);
  // Nothing goes again before the code: no gesture taken, nothing sent.
  expect(intents).toEqual([]);
  const input = host.querySelector<HTMLInputElement>(".cv-turn-signin__input")!;
  expect(input.getAttribute("autocomplete")).toBe("off");
  await typeInto(input, "  abc#def  ");
  await act(async () => button("Continue")!.click());
  await flush();
  await flush();
  expect(calls).toContainEqual(["finish", "login-1", "chat-1", "abc#def"]);
  // The Continue click's gesture, for one prompt, is the resend's ticket.
  expect(intents).toHaveLength(1);
  const promptId = (intents[0] as { params: { promptId: string } }).params.promptId;
  expect(intents[0]).toEqual({ method: "session/prompt", params: { promptId } });
  expect(calls).toContainEqual(["resendPrompt", "user-1", PROMPT]);
  expect(sent).toEqual([[PROMPT, [], promptId, undefined, "ticket-1"]]);
  expect(host.textContent).toContain("Signed in.");
  // The code is gone from the page once used.
  expect(host.innerHTML).not.toContain("abc#def");
});

test("Codex: the device code shows with Copy; after approval Send again takes its own click", async () => {
  let approve!: (value: unknown) => void;
  const { client, calls, sent } = mockClient({
    start: () => ({
      loginId: "login-2",
      url: "https://auth.openai.com/codex/device",
      userCode: "WXYZ-1234",
      needsCode: false,
    }),
    finish: () => new Promise((resolve) => (approve = resolve)),
  });
  const { signIn, intents } = signInFor(client, { harness: "codex" });
  await render({ route: { name: "Codex", harness: "codex", hostKind: "cloud" }, cloudSignIn: signIn });
  await act(async () => button("Sign in to Codex")!.click());
  await flush();
  expect(host.querySelector('[data-testid="cloud-signin-code"]')!.textContent).toBe("WXYZ-1234");
  expect(button("Copy code")).toBeDefined();
  expect(host.textContent).toContain("Enter this code on the page. Waiting for approval…");
  expect(calls).toContainEqual(["finish", "login-2", "chat-1", undefined]);
  await act(async () => approve({ signedIn: true, restarted: true }));
  await flush();
  // Approval came with no click of the person's: nothing is sent until Send again.
  expect(intents).toEqual([]);
  expect(sent).toEqual([]);
  await act(async () => button("Send again")!.click());
  await flush();
  await flush();
  expect(intents).toHaveLength(1);
  expect(sent).toHaveLength(1);
  expect(sent[0]![4]).toBe("ticket-1");
});

test("API key: a password field, saved on the machine, then Send again", async () => {
  const { client, calls, sent } = mockClient({ apiKey: () => ({ saved: true, restarted: true }) });
  const { signIn, intents } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Use an API key")!.click());
  expect(host.textContent).toContain("The key is stored only on this machine.");
  const input = host.querySelector<HTMLInputElement>(".cv-turn-signin__input")!;
  expect(input.type).toBe("password");
  expect(input.getAttribute("autocomplete")).toBe("off");
  await typeInto(input, "sk-ant-test-key");
  await act(async () => button("Save")!.click());
  await flush();
  expect(calls).toContainEqual(["apiKey", "claude", "chat-1", "sk-ant-test-key"]);
  expect(host.innerHTML).not.toContain("sk-ant-test-key");
  expect(sent).toEqual([]);
  await act(async () => button("Send again")!.click());
  await flush();
  await flush();
  expect(intents).toHaveLength(1);
  expect(sent).toHaveLength(1);
});

test("never sends without a gesture ticket", async () => {
  const { client, sent } = mockClient({
    start: () => ({ loginId: "login-3", url: "https://claude.ai/oauth/authorize", needsCode: true }),
    finish: () => ({ signedIn: true }),
  });
  const { signIn } = signInFor(client, { tickets: [undefined, undefined] });
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  await typeInto(host.querySelector<HTMLInputElement>(".cv-turn-signin__input")!, "code-1");
  await act(async () => button("Continue")!.click());
  await flush();
  await flush();
  expect(sent).toEqual([]);
  // The card offers its own Send again for a fresh click.
  expect(button("Send again")).toBeDefined();
  await signIn!.resend("user-1", PROMPT, undefined);
  expect(sent).toEqual([]);
});

test("a refused step names its reason, with Retry", async () => {
  const cases: [string, string, boolean][] = [
    ["bad_code", "That code didn't work. Try again.", true],
    ["expired", "The sign-in expired. Start again.", true],
    ["shared_machine", "This is a shared team machine; sign-in is only available on your own machine.", false],
    ["cli_missing", "The agent isn't installed on this machine.", true],
    ["remote_refused", "Sign-in on this machine works only from your own Mac.", false],
    ["unknown_session", "This chat isn't on that machine anymore. Open the chat again.", true],
    ["failed", "Sign-in didn't finish. Try again.", true],
  ];
  for (const [reason, copy, retry] of cases) {
    await act(async () => root.render(<></>));
    const { client, calls } = mockClient({
      start: () => ({ loginId: "login-4", url: "https://claude.ai/oauth/authorize", needsCode: true }),
      finish: () => {
        throw Object.assign(new Error("refused"), { reason });
      },
    });
    const { signIn } = signInFor(client);
    await render({ route: cloudRoute, cloudSignIn: signIn });
    await act(async () => button("Sign in to Claude")!.click());
    await flush();
    await typeInto(host.querySelector<HTMLInputElement>(".cv-turn-signin__input")!, "wrong");
    await act(async () => button("Continue")!.click());
    await flush();
    expect(host.querySelector(".cv-turn-signin__error")!.textContent).toBe(copy);
    expect(button("Retry") !== undefined).toBe(retry);
    if (reason === "bad_code") {
      // A wrong code keeps the login: Retry asks for the code again, no new start.
      await act(async () => button("Retry")!.click());
      expect(host.querySelector(".cv-turn-signin__input")).not.toBeNull();
      expect(calls.filter((call) => call[0] === "start")).toHaveLength(1);
    }
  }
});

test("Cancel stops the login on the machine", async () => {
  const { client, calls } = mockClient({
    start: () => ({ loginId: "login-5", url: "https://claude.ai/oauth/authorize", needsCode: true }),
  });
  const { signIn } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  await act(async () => button("Cancel")!.click());
  await flush();
  expect(calls).toContainEqual(["cancel", "login-5", "chat-1"]);
  expect(button("Sign in to Claude")).toBeDefined();
});

test("a start reply whose page is not an allowed host is a failure, and nothing opens", async () => {
  const opened: string[] = [];
  const { client, calls } = mockClient({
    start: () => ({ loginId: "login-6", url: "https://evil.example/login", needsCode: true }),
  });
  const { signIn } = signInFor(client, { opened });
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  expect(opened).toEqual([]);
  // The login acpmux started for it is stopped.
  expect(calls).toContainEqual(["cancel", "login-6", "chat-1"]);
  expect(host.querySelector(".cv-turn-signin__error")!.textContent).toBe("Sign-in didn't finish. Try again.");
});

test("the wire log keeps no sign-in code, API key or device code", async () => {
  const { AcpWireLog } = await import("../src/agent-session/acpmux/wire");
  const log = new AcpWireLog();
  const frame = (id: number, method: string, params: Record<string, unknown>) =>
    JSON.stringify({ jsonrpc: "2.0", id, method, params });
  log.sent(frame(1, "_acpmux/agent_login/start", { agent: "codex" }), "_acpmux/agent_login/start", 1);
  log.received(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      result: {
        loginId: "l",
        url: "https://auth.openai.com/codex/device",
        userCode: "DEVICE-CODE-9",
        needsCode: false,
      },
    }),
  );
  log.sent(
    frame(2, "_acpmux/agent_login/finish", { loginId: "l", sessionId: "s", code: "PASTED-CODE-7" }),
    "_acpmux/agent_login/finish",
    2,
  );
  log.sent(
    frame(3, "_acpmux/agent_login/api_key", { agent: "claude", sessionId: "s", key: "sk-ant-SECRET" }),
    "_acpmux/agent_login/api_key",
    3,
  );
  const text = JSON.stringify(log.entries());
  for (const secret of ["DEVICE-CODE-9", "PASTED-CODE-7", "sk-ant-SECRET"]) expect(text).not.toContain(secret);
  expect(text).toContain("auth.openai.com");
});

test("a card that goes away cancels its login and sends nothing after", async () => {
  let finish!: (value: unknown) => void;
  const { client, calls, sent } = mockClient({
    start: () => ({ loginId: "login-7", url: "https://claude.ai/oauth/authorize", needsCode: true }),
    finish: () => new Promise((resolve) => (finish = resolve)),
  });
  const { signIn } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  await typeInto(host.querySelector<HTMLInputElement>(".cv-turn-signin__input")!, "code-7");
  await act(async () => button("Continue")!.click());
  await act(async () => root.render(<></>));
  expect(calls).toContainEqual(["cancel", "login-7", "chat-1"]);
  await act(async () => finish({ signedIn: true }));
  await flush();
  expect(sent).toEqual([]);
});
