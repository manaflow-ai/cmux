// A Cloud chat whose agent is not signed in on its machine offers that agent's own sign-in there
// (Leo 2026-11-01, on the one-click sign-in: "yes those are important"): never a copy of this
// Mac's login. The card runs acpmux's `_acpmux/agent_login/*` on the chat's connection, opens the
// provider's page, takes Claude's code (or shows Codex's), then sends the failed prompt again on
// the person's click. These tests drive the card and its wire with a mocked client.
import { afterAll, beforeEach, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import {
  autoSignIn,
  cloudAgentLogin,
  localApiKeyLogin,
  loginAgent,
  loginFailure,
  offersGateway,
  signInURL,
  signsInByPage,
  takesApiKey,
} from "../src/agent-session/acpmux/cloudAgentLogin";

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
  options: {
    harness?: string;
    tickets?: (string | undefined)[];
    opened?: string[];
    /// The host's machine-bound opens; `machine` answers them (none: the host has no such open).
    onMachine?: string[];
    machine?: boolean;
    supported?: boolean;
    local?: boolean;
  } = {},
) {
  const tickets = options.tickets ?? ["ticket-1", "ticket-2"];
  const intents: unknown[] = [];
  const signIn = (options.local ? localApiKeyLogin : cloudAgentLogin)({
    connected: true,
    machineID: options.local ? undefined : "provider-vm-1",
    sessionId: "chat-1",
    harness: options.harness ?? "claude",
    supported: options.supported ?? true,
    gesture: async (intent) => {
      intents.push(intent);
      return tickets.shift();
    },
    openURL: (url) => options.opened?.push(url),
    ...(options.machine !== undefined && {
      openOnMachine: async (url: string) => {
        options.onMachine?.push(url);
        return options.machine!;
      },
    }),
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

test.each(["full", "off", "reduced"])("sign-in steps resize their action row with motion %s", async (motion) => {
  const { client } = mockClient();
  const { signIn } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn });
  const actions = host.querySelector<HTMLElement>(".cv-turn-error__actions")!;
  const frames: Keyframe[][] = [];
  let cancellations = 0;
  const html = dom.window.document.documentElement;
  html.dataset.agentMotion = motion;
  actions.getBoundingClientRect = () => ({ height: actions.querySelector("input") ? 100 : 24 }) as DOMRect;
  actions.animate = (keyframes) => {
    frames.push(keyframes as Keyframe[]);
    return { cancel: () => cancellations++ } as unknown as Animation;
  };
  try {
    await act(async () => button("Use an API key")!.click());
    expect(actions.querySelector('input[type="password"]')).not.toBeNull();
    expect(frames).toEqual(
      motion === "full"
        ? [
            [
              { height: "24px", maxHeight: "24px" },
              { height: "100px", maxHeight: "100px" },
            ],
          ]
        : [],
    );
    // Going away cancels the finite resize and removes the clip immediately.
    await act(async () => root.render(<></>));
    expect(cancellations).toBe(motion === "full" ? 1 : 0);
    expect(actions.style.overflow).toBe("");
  } finally {
    delete html.dataset.agentMotion;
  }
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
  expect(signInURL("https://cursor.com/loginDeepControl?challenge=c")).toBe(
    "https://cursor.com/loginDeepControl?challenge=c",
  );
  expect(signInURL("https://cursor.com.evil.example/login")).toBeUndefined();
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
  expect(cloudAgentLogin({ ...base, harness: "cursor" })?.agent).toBe("cursor");
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
  // One sign-in button (Leo 2026-11-02): Use an API key beside it is a link, not a second button.
  expect(button("Use an API key")!.classList.contains("cv-turn-error__offer-link")).toBe(true);
  expect(button("Switch model")!.classList.contains("cv-turn-error__primary")).toBe(false);
  // Without the Mac-token transfer there is no Set up credentials button.
  expect(button("Set up Claude Code credentials")).toBeUndefined();
});

/// acpmux's explanation when the machine's team has cmux's gateway (`claude_auth::compose_cloud`).
const GATEWAY_ERROR =
  "Claude is not signed in here. Click Set up Claude Code credentials on this message to sign it in from your Mac; the message is sent again. Or click Use cmux's gateway: this machine's team has an account there. (Claude said: Not logged in · Please run /login)";

test("cmux's gateway is offered only where acpmux names it", () => {
  expect(offersGateway(GATEWAY_ERROR)).toBe(true);
  expect(offersGateway("Not logged in · Please run /login")).toBe(false);
  expect(offersGateway(undefined)).toBe(false);
  const refusal = Object.assign(new Error("refused"), { reason: "no_gateway" });
  expect(loginFailure(refusal)).toBe("no_gateway");
});

test("one card, three ways in: Sign in to Claude, Use an API key, Use cmux's gateway", async () => {
  const { client, calls, sent } = mockClient({ start: () => ({ gateway: true, restarted: true }) });
  const { signIn } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn, switchModel: () => undefined }, GATEWAY_ERROR);
  expect(labels().slice(0, 4)).toEqual(["Sign in to Claude", "Use an API key", "Use cmux's gateway", "Switch model"]);
  // The sign-in stays the one filled button; the others are links beside it.
  expect(button("Sign in to Claude")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Use cmux's gateway")!.classList.contains("cv-turn-error__offer-link")).toBe(true);
  await act(async () => button("Use cmux's gateway")!.click());
  await flush();
  // acpmux's own start, for the gateway: no sign-in page, no key.
  expect(calls).toEqual([["start", "claude@gateway", "chat-1"]]);
  expect(button("Send again")).toBeDefined();
  expect(sent).toEqual([]);
});

test("a team without the gateway says so, and Retry asks again", async () => {
  const refused = () => {
    throw Object.assign(new Error("no gateway"), { reason: "no_gateway" });
  };
  const { client, calls } = mockClient({ start: refused });
  const { signIn } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn }, GATEWAY_ERROR);
  await act(async () => button("Use cmux's gateway")!.click());
  await flush();
  expect(host.textContent).toContain("cmux's gateway is not set up for this machine's team.");
  await act(async () => button("Retry")!.click());
  await flush();
  expect(calls).toEqual([
    ["start", "claude@gateway", "chat-1"],
    ["start", "claude@gateway", "chat-1"],
  ]);
});

test("no gateway link where acpmux does not name it", async () => {
  const { client } = mockClient();
  const { signIn } = signInFor(client);
  await render({ route: cloudRoute, cloudSignIn: signIn });
  expect(button("Use cmux's gateway")).toBeUndefined();
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

test("Claude: one click starts the login and opens its page; paste the code, finish, send again", async () => {
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
  // The one Sign in click opened the page too (the host lets its start open it): no second click.
  expect(opened).toEqual(["https://claude.ai/oauth/authorize?code=true"]);
  expect(host.textContent).toContain("Approve in your browser, then paste the code it shows.");
  expect(button("Continue")!.classList.contains("cv-turn-error__primary")).toBe(true);
  // Open sign-in page stays, quiet, to open it again.
  expect(button("Open sign-in page")!.classList.contains("cv-turn-error__primary")).toBe(false);
  await act(async () => button("Open sign-in page")!.click());
  expect(opened).toHaveLength(2);
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

test("Codex: one click opens the page with its device code copied; after approval Send again takes its own click", async () => {
  let approve!: (value: unknown) => void;
  const opened: string[] = [];
  const copied: string[] = [];
  const clipboard = Object.getOwnPropertyDescriptor(dom.window.navigator, "clipboard");
  Object.defineProperty(dom.window.navigator, "clipboard", {
    configurable: true,
    value: { writeText: async (text: string) => void copied.push(text) },
  });
  const { client, calls, sent } = mockClient({
    start: () => ({
      loginId: "login-2",
      url: "https://auth.openai.com/codex/device",
      userCode: "WXYZ-1234",
      needsCode: false,
    }),
    finish: () => new Promise((resolve) => (approve = resolve)),
  });
  const { signIn, intents } = signInFor(client, { harness: "codex", opened });
  await render({ route: { name: "Codex", harness: "codex", hostKind: "cloud" }, cloudSignIn: signIn });
  await act(async () => button("Sign in to Codex")!.click());
  await flush();
  await flush();
  if (clipboard) Object.defineProperty(dom.window.navigator, "clipboard", clipboard);
  else delete (dom.window.navigator as unknown as Record<string, unknown>).clipboard;
  expect(opened).toEqual(["https://auth.openai.com/codex/device"]);
  expect(host.querySelector('[data-testid="cloud-signin-code"]')!.textContent).toBe("WXYZ-1234");
  // The code is on the clipboard already, for the page's field.
  expect(copied).toEqual(["WXYZ-1234"]);
  expect(button("Copied")).toBeDefined();
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

// Cursor (Leo 2026-11-10: "if somebody has a ChatGPT subscription or a Cursor subscription"): one Sign in
// to Cursor and no Use an API key (its key is the Cloud secret CURSOR_API_KEY); the click opens its
// cursor.com page, the card waits for the approve with no code, and Send again takes its own click.
test("Cursor: one click opens its page, the card waits for the approve with no code, then Send again", async () => {
  let approve!: (value: unknown) => void;
  const opened: string[] = [];
  const { client, calls, sent } = mockClient({
    start: () => ({ loginId: "login-c", url: "https://cursor.com/loginDeepControl?challenge=c", needsCode: false }),
    finish: () => new Promise((resolve) => (approve = resolve)),
  });
  const { signIn, intents } = signInFor(client, { harness: "cursor", opened });
  await render(
    { route: { name: "Cursor", harness: "cursor", hostKind: "cloud" }, cloudSignIn: signIn },
    "Authentication required",
  );
  expect(button("Sign in to Cursor")).toBeDefined();
  expect(button("Use an API key")).toBeUndefined();
  await act(async () => button("Sign in to Cursor")!.click());
  await flush();
  await flush();
  expect(opened).toEqual(["https://cursor.com/loginDeepControl?challenge=c"]);
  expect(host.querySelector('[data-testid="cloud-signin-code"]')).toBeNull();
  expect(host.textContent).toContain("Approve on the sign-in page; it finishes on its own.");
  expect(calls).toContainEqual(["finish", "login-c", "chat-1", undefined]);
  await act(async () => approve({ signedIn: true, restarted: true }));
  await flush();
  expect(intents).toEqual([]);
  expect(sent).toEqual([]);
  await act(async () => button("Send again")!.click());
  await flush();
  await flush();
  expect(sent).toHaveLength(1);
});

// A team Cloud machine takes no personal login (the start skipped it: `guest-not-owner`, guest `team`):
// the card says so, Switch model leads, Use an API key stays, and neither Sign in to Claude nor a
// login transfer (which ends in "Personal credentials can only be transferred to a Cloud machine you
// own") is offered, by hand or automatically.
test("a team Cloud machine's sign-in failure names it and offers Switch model and Use an API key", async () => {
  const { client } = mockClient();
  const { signIn } = signInFor(client);
  const transfers: unknown[][] = [];
  const team = { ...cloudRoute, teamMachine: true };
  const rejected = "The provider rejected Claude Code's credentials on this Cloud machine (HTTP 401).";
  await render(
    {
      route: team,
      cloudSignIn: signIn,
      switchModel: () => undefined,
      transferCloudCredentials: async (...args: unknown[]) => void transfers.push(args),
    },
    rejected,
  );
  await flush();
  expect(host.querySelector(".cv-turn-error__cause")!.textContent).toContain(
    "Claude Code on this team Cloud machine has no sign-in it can use. cmux doesn’t pass personal logins to shared team machines.",
  );
  expect(labels().slice(0, 2)).toEqual(["Switch model", "Use an API key"]);
  expect(button("Switch model")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Sign in to Claude")).toBeUndefined();
  expect(button("Set up Claude Code credentials")).toBeUndefined();
  expect(transfers).toEqual([]);
  // An owner machine's card is as it was.
  await render({ route: cloudRoute, cloudSignIn: signIn, switchModel: () => undefined }, rejected);
  expect(labels().slice(0, 3)).toEqual(["Sign in to Claude", "Use an API key", "Switch model"]);
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
      // acpmux ended the login with the refusal: Retry starts a new one, never reusing it.
      await act(async () => button("Retry")!.click());
      await flush();
      expect(calls.filter((call) => call[0] === "start")).toHaveLength(2);
    }
  }
});

test("a resend whose card went away while its attachments loaded never sends", async () => {
  const { client, sent } = mockClient({});
  let release!: () => void;
  const loaded = new Promise<void>((resolve) => (release = resolve));
  const slow = {
    ...client,
    resendPrompt: async (rowId: string, text: string) => {
      await loaded;
      return client.resendPrompt(rowId, text);
    },
  } as typeof client;
  const { signIn } = signInFor(slow);
  let wanted = true;
  const pending = signIn!.resend("user-1", PROMPT, { promptId: "p-1", ticket: "t-1" }, () => wanted);
  wanted = false;
  release();
  await pending;
  expect(sent).toEqual([]);
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

// Leo 2026-10-26: "if user picks a model they don't have api key, we offer them to add credits or add
// their own api key". A chat on this Mac whose built-in Claude Code or Codex is not signed in offers
// Use an API key beside Sign in again; acpmux saves it where the agent's own CLI reads it.
const localRoute = { name: "Claude Code", harness: "claude" };

test("Use an API key is offered only for a connected built-in Claude or Codex chat on this Mac", () => {
  const { client } = mockClient();
  const base = {
    connected: true,
    machineID: undefined,
    sessionId: "chat-1",
    harness: "claude",
    supported: true,
    gesture: async () => undefined,
    openURL: () => undefined,
    isCurrent: () => true,
    currentClient: () => client as never,
  };
  expect(localApiKeyLogin(base)?.agent).toBe("claude");
  expect(localApiKeyLogin({ ...base, harness: "codex" })?.agent).toBe("codex");
  // A route sets its own key and endpoint: a saved key would never reach it.
  expect(localApiKeyLogin({ ...base, harness: "claude-cr" })).toBeUndefined();
  expect(localApiKeyLogin({ ...base, harness: "opencode" })).toBeUndefined();
  // A Cloud chat's card is cloudAgentLogin's.
  expect(localApiKeyLogin({ ...base, machineID: "vm" })).toBeUndefined();
  expect(localApiKeyLogin({ ...base, connected: false })).toBeUndefined();
  expect(localApiKeyLogin({ ...base, supported: false })).toBeUndefined();
});

test("a signed-out chat here offers Sign in again, then Use an API key, which saves and sends again", async () => {
  const { client, calls, sent } = mockClient({ apiKey: () => ({ saved: true, restarted: true }) });
  const { signIn, intents } = signInFor(client, { local: true });
  await render({
    route: localRoute,
    apiKeySignIn: signIn,
    reauthenticate: () => undefined,
    switchModel: () => undefined,
  });
  expect(labels().slice(0, 2)).toEqual(["Sign in again", "Use an API key"]);
  expect(button("Sign in again")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Use an API key")!.classList.contains("cv-turn-error__primary")).toBe(false);
  expect(button("Sign in to Claude")).toBeUndefined();
  await act(async () => button("Use an API key")!.click());
  const input = host.querySelector<HTMLInputElement>(".cv-turn-signin__input")!;
  expect(input.type).toBe("password");
  await typeInto(input, "sk-ant-local-key");
  await act(async () => button("Save")!.click());
  await flush();
  expect(calls).toContainEqual(["apiKey", "claude", "chat-1", "sk-ant-local-key"]);
  expect(host.innerHTML).not.toContain("sk-ant-local-key");
  await act(async () => button("Send again")!.click());
  await flush();
  await flush();
  expect(intents).toHaveLength(1);
  expect(sent).toHaveLength(1);
});

test("no Use an API key here on a failure that is not a sign-in", async () => {
  const { client } = mockClient();
  const { signIn } = signInFor(client, { local: true });
  await render({ route: localRoute, apiKeySignIn: signIn, retry: () => undefined }, "API Error: 529 overloaded_error");
  expect(button("Use an API key")).toBeUndefined();
});

const MANUAL =
  "https://claude.com/cai/oauth/authorize?code=true&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=s";
const AUTO =
  "https://claude.com/cai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=s";
const autoStart = () => ({ loginId: "login-a", url: MANUAL, autoUrl: AUTO, callbackPort: 54545, needsCode: true });

test("Claude's automatic page: an allowed page whose one redirect is the machine's localhost callback", () => {
  expect(autoSignIn(AUTO)).toEqual({ url: AUTO, port: 54545 });
  expect(autoSignIn(MANUAL)).toBeUndefined();
  for (const redirect of [
    "http://evil.example:54545/callback",
    "http://localhost.evil.example:54545/callback",
    "http://127.0.0.1:54545/callback",
    "https://localhost:54545/callback",
    "http://localhost:54545/other",
    "http://localhost/callback",
    "http://localhost:0/callback",
    "http://localhost:070/callback",
    "http://localhost:99999/callback",
  ])
    expect(autoSignIn(`https://claude.com/x?redirect_uri=${encodeURIComponent(redirect)}`)).toBeUndefined();
  expect(
    autoSignIn(
      `https://claude.com/x?redirect_uri=${encodeURIComponent("http://localhost:1/callback")}&redirect_uri=${encodeURIComponent("http://localhost:2/callback")}`,
    ),
  ).toBeUndefined();
  expect(autoSignIn(AUTO.replace("https://claude.com", "https://evil.example"))).toBeUndefined();
});

test("Claude, no paste: one click opens the automatic page on the machine, the approve signs in by itself", async () => {
  let approve!: (value: unknown) => void;
  const opened: string[] = [];
  const onMachine: string[] = [];
  const { client, calls } = mockClient({
    start: autoStart,
    finish: () => new Promise((resolve) => (approve = resolve)),
  });
  const { signIn, intents } = signInFor(client, { opened, onMachine, machine: true });
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  await flush();
  // The one click opened the automatic page in the machine-bound tab, and nothing else.
  expect(onMachine).toEqual([AUTO]);
  expect(opened).toEqual([]);
  // No code field: the approve finishes it.
  expect(host.querySelector(".cv-turn-signin__input")).toBeNull();
  expect(host.textContent).toContain("Approve on the sign-in page; it finishes on its own.");
  expect(calls).toContainEqual(["finish", "login-a", "chat-1", undefined]);
  // Paste a code instead is a quiet link, never a second button.
  expect(button("Paste a code instead")!.classList.contains("cv-turn-error__offer-link")).toBe(true);
  expect(button("Paste a code instead")!.classList.contains("cv-turn-error__primary")).toBe(false);
  // Open sign-in page opens the automatic page again, on the machine.
  await act(async () => button("Open sign-in page")!.click());
  await flush();
  expect(onMachine).toEqual([AUTO, AUTO]);
  await act(async () => approve({ signedIn: true, restarted: true }));
  await flush();
  expect(host.textContent).toContain("Signed in.");
  expect(intents).toEqual([]);
});

test("Claude, no paste: a host that cannot open the machine-bound tab opens the code page", async () => {
  const opened: string[] = [];
  const onMachine: string[] = [];
  const { client, calls } = mockClient({ start: autoStart });
  const { signIn } = signInFor(client, { opened, onMachine, machine: false });
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  await flush();
  expect(onMachine).toEqual([AUTO]);
  expect(opened).toEqual([MANUAL]);
  expect(host.querySelector(".cv-turn-signin__input")).not.toBeNull();
  expect(host.textContent).toContain("Approve in your browser, then paste the code it shows.");
  // No wait for an approve that cannot come.
  expect(calls.filter((call) => call[0] === "finish")).toEqual([]);
});

test("Claude, no paste: a host without the open (older app) pastes as before", async () => {
  const opened: string[] = [];
  const { client } = mockClient({ start: autoStart });
  const { signIn } = signInFor(client, { opened });
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  await flush();
  expect(opened).toEqual([MANUAL]);
  expect(host.querySelector(".cv-turn-signin__input")).not.toBeNull();
});

test("Claude, no paste: Paste a code instead opens the code page; the pasted code finishes the same login", async () => {
  const opened: string[] = [];
  const finishes: unknown[][] = [];
  const { client, sent } = mockClient({
    start: autoStart,
    finish: (...args: unknown[]) => {
      finishes.push(args);
      // The wait for the approve never ends here; the paste does.
      return args[2] === undefined ? new Promise(() => undefined) : { signedIn: true, restarted: false };
    },
  });
  const { signIn } = signInFor(client, { opened, machine: true });
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  await flush();
  await act(async () => button("Paste a code instead")!.click());
  expect(opened).toEqual([MANUAL]);
  const input = host.querySelector<HTMLInputElement>(".cv-turn-signin__input")!;
  await typeInto(input, "abc#def");
  await act(async () => button("Continue")!.click());
  await flush();
  await flush();
  expect(finishes).toEqual([
    ["login-a", "chat-1", undefined],
    ["login-a", "chat-1", "abc#def"],
  ]);
  expect(host.textContent).toContain("Signed in.");
  expect(sent).toHaveLength(1);
});

test("Claude, no paste: the approve's wait ending after a pasted code sent again changes nothing", async () => {
  let approve: (value: unknown) => void = () => undefined;
  const { client, sent } = mockClient({
    start: autoStart,
    finish: (...args: unknown[]) =>
      args[2] === undefined ? new Promise((resolve) => (approve = resolve)) : { signedIn: true, restarted: false },
  });
  const { signIn } = signInFor(client, { opened: [], machine: true });
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  await flush();
  await act(async () => button("Paste a code instead")!.click());
  await typeInto(host.querySelector<HTMLInputElement>(".cv-turn-signin__input")!, "abc#def");
  await act(async () => button("Continue")!.click());
  await flush();
  await flush();
  expect(sent).toHaveLength(1);
  const after = host.textContent;
  await act(async () => approve({ signedIn: true, restarted: false }));
  await flush();
  await flush();
  expect(host.textContent).toBe(after);
  expect(button("Send again")).toBeUndefined();
  expect(sent).toHaveLength(1);
});

test("an automatic page whose port acpmux did not name is not used", async () => {
  const opened: string[] = [];
  const onMachine: string[] = [];
  const { client } = mockClient({ start: () => ({ ...autoStart(), callbackPort: 1234 }) });
  const { signIn } = signInFor(client, { opened, onMachine, machine: true });
  await render({ route: cloudRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Claude")!.click());
  await flush();
  await flush();
  expect(onMachine).toEqual([]);
  expect(opened).toEqual([MANUAL]);
});

// Gemini CLI and the Grok CLI on a Cloud machine (Leo 2026-11-10: "a lot of this is just
// integration code that you can just do"): the same card,
// with each agent's own ways in. Gemini signs in there with an API key only; Grok with its device
// flow only (a page on accounts.x.ai and a code), its key coming from the person's vault.
const geminiRoute = { name: "Gemini CLI", harness: "gemini", hostKind: "cloud" as const };
const grokRoute = { name: "Grok", harness: "grok", hostKind: "cloud" as const };

test("Gemini and Grok are login agents, each with its own ways in", () => {
  expect(loginAgent("gemini")).toBe("gemini");
  expect(loginAgent("grok")).toBe("grok");
  expect(loginAgent("cursor")).toBe("cursor");
  expect(loginAgent("opencode")).toBeUndefined();
  expect(loginAgent(undefined)).toBeUndefined();
  expect([signsInByPage("cursor"), takesApiKey("cursor")]).toEqual([true, false]);
  expect([signsInByPage("gemini"), takesApiKey("gemini")]).toEqual([false, true]);
  expect([signsInByPage("grok"), takesApiKey("grok")]).toEqual([true, false]);
  expect([signsInByPage("codex"), takesApiKey("codex")]).toEqual([true, true]);
  // Grok's sign-in hosts open; look-alikes never do.
  expect(signInURL("https://accounts.x.ai/device")).toBe("https://accounts.x.ai/device");
  expect(signInURL("https://auth.x.ai/activate?user_code=WDJB-MJHT")).toBeDefined();
  expect(signInURL("https://x.ai.evil.example/device")).toBeUndefined();
  expect(signInURL("https://evil.x.ai/device")).toBeUndefined();
  const { client } = mockClient();
  const base = {
    connected: true,
    machineID: "vm",
    sessionId: "chat-1",
    supported: true,
    gesture: async () => undefined,
    openURL: () => undefined,
    isCurrent: () => true,
    currentClient: () => client as never,
  };
  expect(cloudAgentLogin({ ...base, harness: "gemini" })?.agent).toBe("gemini");
  expect(cloudAgentLogin({ ...base, harness: "grok" })?.agent).toBe("grok");
  expect(cloudAgentLogin({ ...base, harness: "grok", supported: false })).toBeUndefined();
  // A chat on this Mac keeps its own card (Sign in again); no Gemini or Grok key card there.
  expect(localApiKeyLogin({ ...base, machineID: undefined, harness: "gemini" })).toBeUndefined();
});

test("Gemini: Use an API key is the card's one filled button, and the key is saved for gemini", async () => {
  const { client, calls, sent } = mockClient({ apiKey: () => ({ saved: true, restarted: true }) });
  const { signIn, intents } = signInFor(client, { harness: "gemini" });
  await render({ route: geminiRoute, cloudSignIn: signIn, switchModel: () => undefined });
  expect(labels().slice(0, 2)).toEqual(["Use an API key", "Switch model"]);
  expect(buttons().some((element) => element.textContent?.startsWith("Sign in to"))).toBe(false);
  expect(button("Use an API key")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Switch model")!.classList.contains("cv-turn-error__primary")).toBe(false);
  await act(async () => button("Use an API key")!.click());
  const input = host.querySelector<HTMLInputElement>('.cv-turn-signin__input[type="password"]')!;
  await typeInto(input, "  AIzaTest123  ");
  await act(async () => button("Save")!.click());
  await flush();
  expect(calls).toContainEqual(["apiKey", "gemini", "chat-1", "AIzaTest123"]);
  // No start ever ran: Gemini has no sign-in page here.
  expect(calls.some((call) => call[0] === "start")).toBe(false);
  expect(host.textContent).toContain("Signed in.");
  expect(host.innerHTML).not.toContain("AIzaTest123");
  expect(sent).toEqual([]);
  await act(async () => button("Send again")!.click());
  await flush();
  await flush();
  expect(intents).toHaveLength(1);
  expect(sent).toHaveLength(1);
});

test("Grok: one Sign in to Grok click opens its page with its device code; no Use an API key", async () => {
  let approve!: (value: unknown) => void;
  const opened: string[] = [];
  const { client, calls } = mockClient({
    start: () => ({
      loginId: "login-grok",
      url: "https://accounts.x.ai/device",
      userCode: "WDJB-MJHT",
      needsCode: false,
    }),
    finish: () => new Promise((resolve) => (approve = resolve)),
  });
  const { signIn } = signInFor(client, { harness: "grok", opened });
  await render({ route: grokRoute, cloudSignIn: signIn, switchModel: () => undefined });
  expect(labels().slice(0, 2)).toEqual(["Sign in to Grok", "Switch model"]);
  expect(button("Use an API key")).toBeUndefined();
  expect(button("Sign in to Grok")!.classList.contains("cv-turn-error__primary")).toBe(true);
  await act(async () => button("Sign in to Grok")!.click());
  await flush();
  await flush();
  expect(calls[0]).toEqual(["start", "grok", "chat-1"]);
  expect(opened).toEqual(["https://accounts.x.ai/device"]);
  expect(host.querySelector('[data-testid="cloud-signin-code"]')!.textContent).toBe("WDJB-MJHT");
  expect(host.textContent).toContain("Enter this code on the page. Waiting for approval…");
  expect(calls).toContainEqual(["finish", "login-grok", "chat-1", undefined]);
  await act(async () => approve({ signedIn: true, restarted: true }));
  await flush();
  expect(host.textContent).toContain("Signed in.");
});

test("Grok on a team machine: the refusal is named, with no Retry", async () => {
  const { client } = mockClient({
    start: () => {
      throw Object.assign(new Error("team machine"), { reason: "shared_machine" });
    },
  });
  const { signIn } = signInFor(client, { harness: "grok" });
  await render({ route: grokRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Grok")!.click());
  await flush();
  expect(host.querySelector(".cv-turn-signin__error")!.textContent).toBe(
    "This is a shared team machine; sign-in is only available on your own machine.",
  );
  expect(button("Retry")).toBeUndefined();
});

test("Grok's start answered unsupported (an older acpmux) leaves the card as it was", async () => {
  const { client } = mockClient({
    start: () => {
      throw Object.assign(new Error("unsupported"), { reason: "unsupported_agent" });
    },
  });
  const { signIn } = signInFor(client, { harness: "grok" });
  await render({ route: grokRoute, cloudSignIn: signIn });
  await act(async () => button("Sign in to Grok")!.click());
  await flush();
  expect(host.querySelector(".cv-turn-signin__error")).toBeNull();
  expect(button("Sign in to Grok")).toBeUndefined();
});
