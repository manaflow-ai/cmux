// A failed turn showed acpmux's bare "agent process closed" with an outlined Copy error, and a full
// disk or a tailnet that no longer reached the chat's machine read the same way (Leo 2026-10-22:
// "we need to have prettier errors" and "we also wanna make sure we have good
// recoverable/informative disk errors tailscale erros for acpmux"). The card says the cause in one
// human line, offers the way out first, and keeps the agent's own words under Details with Copy.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { failureCopy, failureKind, failureRecovery, offersOwnRoute } from "../src/agent-session/acpmux/failureCopy";
import { codeRouterOffer, ownRouteOf, readChatAccounts } from "../src/agent-session/acpmux/chatAccounts";
import { translatorFor } from "../src/agent-session/acpmux/i18n";

const t = translatorFor("en");
const claude = { name: "Claude Code", harness: "claude" };

test("disk, tailnet, quit and start failures each name their cause", () => {
  const cases: [string, string][] = [
    ["agent process closed", "agent-exited"],
    ["agent process closed\nstderr: Error: ENOSPC: no space left on device, write", "disk-full"],
    ["write /var/acpmux/journal: disk quota exceeded", "disk-full"],
    ["peer build-box unreachable: dial tcp build-box.tail0e5a.ts.net:4717: i/o timeout", "tailscale"],
    ["tailscale: not connected to the tailnet", "tailscale"],
    ["failed to spawn agent: spawn claude-code-acp ENOENT", "spawn-failed"],
    ["claude-code-acp: command not found", "spawn-failed"],
    ["agent exited with code 137 (SIGKILL)", "agent-exited"],
    // A tool's start failure in the stderr of an agent that ran is not the agent failing to start.
    ["agent process closed\nstderr: sh: pnpm: command not found", "agent-exited"],
    ["agent process exited with code 1\nstderr: failed to start the dev server", "agent-exited"],
    // What the agent's stderr names says more than that it quit.
    ["agent process closed\nstderr: API Error: 529 overloaded_error", "rate-limited"],
    ["agent process closed\nstderr: connect ECONNREFUSED 127.0.0.1:443", "unreachable"],
    ["agent process closed\nstderr: Invalid API key · Please run /login", "subscription-login"],
    ["agent process closed\nstderr: invalid x-api-key", "invalid-key"],
    // A tailnet host that answered is that answer, not Tailscale.
    ["HTTP 401 Unauthorized from https://proxy.tail123.ts.net/v1/messages", "proxy-auth"],
    [
      "HTTP 401 Unauthorized from https://proxy.tail123.ts.net/v1/messages: user is logged out; please sign in again",
      "proxy-auth",
    ],
    ['Post "https://proxy.tail123.ts.net/oauth/token": dial tcp 100.101.102.103:443: i/o timeout', "tailscale"],
    [
      'OAuth token refresh failed: Post "https://proxy.tail123.ts.net/oauth/token": dial tcp 100.101.102.103:443: i/o timeout',
      "tailscale",
    ],
    ["authentication failed: dial tcp proxy.tail123.ts.net:443: connect: connection refused", "tailscale"],
    ['{"url":"https://proxy.tail123.ts.net/v1/messages","status":401,"message":"logged out"}', "proxy-auth"],
    ["HTTP 401 Unauthorized from https://proxy.tail123.ts.net/v1/messages?error=ETIMEDOUT", "proxy-auth"],
    ["API Error: 529 overloaded_error from https://proxy.tail123.ts.net/v1/messages", "rate-limited"],
    ["dial tcp proxy.tail123.ts.net:443: connect: connection refused", "tailscale"],
  ];
  for (const [message, kind] of cases) expect([message, failureKind(message, claude)]).toEqual([message, kind]);
});

test("acpmux's typed reason wins over the words", () => {
  expect(failureKind("could not write the session journal", claude, "disk.full")).toBe("disk-full");
  expect(failureKind("agent process closed", claude, "tailscale.down")).toBe("tailscale");
  expect(failureKind("agent process closed", claude, "peer.unreachable")).toBe("unreachable");
  expect(failureKind("agent process closed", claude, "spawn.failed")).toBe("spawn-failed");
  // A code with no words it knows leaves the text to say.
  expect(failureKind("API Error: 529 overloaded_error", claude, "E1234")).toBe("rate-limited");
});

test("every failure reads human, never as the agent's raw words", () => {
  const raw = "RpcError(-32603): internal error: unexpected end of frame";
  expect(failureCopy(t, raw, claude)).toBe("Claude Code ran into a problem and stopped.");
  expect(failureCopy(t, "agent process closed", claude)).toBe("Claude Code quit before it finished this turn.");
  expect(failureCopy(t, "ENOSPC: no space left on device", claude)).toContain("The disk is full");
  expect(failureCopy(t, "dial tcp mini.tail1.ts.net:4717: i/o timeout", claude)).toContain("Tailscale");
  expect(failureCopy(t, undefined, claude)).toBe("The turn failed");
  expect(failureCopy(t, undefined, claude, "disk.full")).toContain("The disk is full");
});

test("the way out: Retry for what may pass, Switch model for capacity and keys, none for sign-in", () => {
  expect(failureRecovery("disk-full")).toBe("retry");
  expect(failureRecovery("tailscale")).toBe("retry");
  expect(failureRecovery("agent-exited")).toBe("retry");
  expect(failureRecovery("other")).toBe("retry");
  expect(failureRecovery("rate-limited")).toBe("switch-model");
  expect(failureRecovery("invalid-key")).toBe("switch-model");
  expect(failureRecovery("subscription-login")).toBeUndefined();
  expect(failureRecovery("trust-pending")).toBeUndefined();
});

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
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");

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

const failed = (error: string, errorCode?: string) => ({
  id: "summary-2",
  version: 1,
  at: Date.now(),
  kind: "turnSummary",
  seq: 2,
  status: "failed",
  durationMs: 662_000,
  error,
  ...(errorCode ? { errorCode } : {}),
  prompt: "Run the sidebar tests and fix what fails",
  retryRowId: "user-1",
});
const card = () => host.querySelector(".cv-turn-error")!;
const button = (label: string) =>
  [...card().querySelectorAll("button")].find((element) => element.textContent === label);

test('"agent process closed" draws a card: the cause, Retry first, the raw words under Details with Copy', async () => {
  const retried: string[] = [];
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: (rowId, prompt) => retried.push(`${rowId}:${prompt}`) }}>
        <TurnFooter row={failed("agent process closed")} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(card().getAttribute("data-failure-kind")).toBe("agent-exited");
  // No route in the context: the agent is named as such.
  expect(card().querySelector(".cv-turn-error__cause")!.textContent).toBe(
    "The agent quit before it finished this turn.",
  );
  const first = card().querySelector(".cv-turn-error__actions button")!;
  expect(first.textContent).toBe("Retry");
  expect(first.classList.contains("cv-turn-error__primary")).toBe(true);
  await act(async () => button("Retry")!.click());
  expect(retried).toEqual(["user-1:Run the sidebar tests and fix what fails"]);
  const details = card().querySelector("details")!;
  expect(details.querySelector("summary")!.textContent).toBe("Details");
  expect(details.textContent).toContain("agent process closed");
  expect([...details.querySelectorAll("button")].map((element) => element.textContent)).toEqual(["Copy error"]);
});

test("capacity puts Switch model first, Retry after it", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined, switchModel: () => undefined }}>
        <TurnFooter row={failed("API Error: 529 overloaded_error")} />
      </TurnActionsContext.Provider>,
    ),
  );
  const labels = [...card().querySelectorAll(".cv-turn-error__actions > button")].map((element) => element.textContent);
  expect(labels).toEqual(["Switch model", "Retry"]);
  expect(button("Switch model")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Retry")!.classList.contains("cv-turn-error__primary")).toBe(false);
});

test("the typed reason reaches the card", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{}}>
        <TurnFooter row={failed("could not write the session journal", "disk.full")} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(card().getAttribute("data-failure-kind")).toBe("disk-full");
  expect(card().textContent).toContain("The disk is full");
  // No retry wired: no Retry button, Details still there.
  expect(button("Retry")).toBeUndefined();
  expect(card().querySelector("details summary")!.textContent).toBe("Details");
});

// A long chat that outgrew the model's context window read as "ran into a problem and stopped" with
// Retry, which sends the same prompt into the same history and fails the same way: a dead end. It
// names the cause and offers Compact (the agent's own /compact) first, Retry after it.
test("a chat that outgrew its context window reads as such, from the text or the typed reason", () => {
  const cases = [
    'API Error: 400 {"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 212043 tokens > 200000 maximum"}}',
    "Prompt is too long",
    "This model's maximum context length is 128000 tokens. However, your messages resulted in 131072 tokens.",
    "context_length_exceeded",
    "Your input exceeds the context window of this model. Please adjust your input and try again.",
  ];
  for (const message of cases) expect([message, failureKind(message, claude)]).toEqual([message, "context-full"]);
  expect(failureKind("stream ended", claude, "context_window_exceeded")).toBe("context-full");
  // A per-minute token limit is capacity, not a full context.
  expect(failureKind("429 rate_limit_error: too many tokens per minute", claude)).toBe("rate-limited");
  expect(failureRecovery("context-full")).toBe("compact");
  expect(failureCopy(t, "Prompt is too long", claude)).toBe(
    "This chat is too long for Claude Code’s context window. Compact it, then retry.",
  );
});

test("a context-full card puts Compact first, sends it once, and keeps Retry after it", async () => {
  let compacts = 0;
  let settle: () => void = () => undefined;
  const compact = () => {
    compacts += 1;
    return new Promise<void>((resolve) => (settle = resolve));
  };
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined, switchModel: () => undefined, compact }}>
        <TurnFooter row={failed("Prompt is too long")} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(card().getAttribute("data-failure-kind")).toBe("context-full");
  const labels = [...card().querySelectorAll(".cv-turn-error__actions > button")].map((element) => element.textContent);
  expect(labels).toEqual(["Compact", "Retry"]);
  expect(button("Compact")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Retry")!.classList.contains("cv-turn-error__primary")).toBe(false);
  await act(async () => button("Compact")!.click());
  await act(async () => button("Compact")!.click());
  expect(compacts).toBe(1);
  expect(button("Compact")!.hasAttribute("disabled")).toBe(true);
  await act(async () => settle());
  expect(button("Compact")!.hasAttribute("disabled")).toBe(false);
});

test("a harness without /compact keeps Retry as the context-full card's way out", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined }}>
        <TurnFooter row={failed("Prompt is too long")} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(button("Compact")).toBeUndefined();
  expect(button("Retry")!.classList.contains("cv-turn-error__primary")).toBe(true);
});

test("Compact is offered only where the agent lists /compact", async () => {
  const { offersCompact } = await import("../src/agent-session/acpmux/conversation/turnActions");
  expect(offersCompact([{ name: "compact", description: "Clear history but keep a summary" }])).toBe(true);
  expect(offersCompact([{ name: "compact", description: "", source: "skill" }])).toBe(false);
  expect(offersCompact([{ name: "review", description: "" }])).toBe(false);
  expect(offersCompact(undefined)).toBe(false);
});

// Lawrence 2026-10-23, on a "Deepseek has no valid API key" card with Switch model and Copy error:
// "good opportunity for upsell here". A key, sign-in or capacity failure offers cmux's own route,
// CodeRouter, beside Switch model; the action always does something.
test("CodeRouter is offered on key, sign-in and capacity failures, never to a chat already on it", () => {
  for (const kind of ["invalid-key", "subscription-login", "auth", "rate-limited"] as const)
    expect([kind, offersOwnRoute(kind, claude)]).toEqual([kind, true]);
  // CodeRouter itself refused a team machine's missing account; other kinds have their own way out.
  for (const kind of ["no-team-account", "proxy-auth", "unreachable", "disk-full", "agent-exited", "other"] as const)
    expect([kind, offersOwnRoute(kind, claude)]).toEqual([kind, false]);
  expect(offersOwnRoute("invalid-key", { name: "Claude (CodeRouter)", harness: "claude-cr" })).toBe(false);
});

test("the chat's routes say what CodeRouter offers: a route, on it already, or nothing", () => {
  const cr = { id: "cmux", name: "cmux model router", kind: "cmux-router" };
  const local = { id: "my-cr", name: "CodeRouter", kind: "local-coderouter" };
  const key = { id: "anthropic-key", name: "Anthropic key", kind: "api-key" };
  expect(codeRouterOffer({ accounts: [key, cr] })).toEqual(cr);
  expect(codeRouterOffer({ accounts: [key, local] })).toEqual(local);
  expect(codeRouterOffer({ accounts: [key, cr], active: "cmux" })).toBe("on");
  expect(codeRouterOffer({ accounts: [key, cr], active: "anthropic-key" })).toEqual(cr);
  expect(codeRouterOffer({ accounts: [key] })).toBeUndefined();
  expect(codeRouterOffer({ accounts: [] })).toBeUndefined();
});

const cr = { id: "cmux", name: "cmux model router", kind: "cmux-router" };
const renderOffer = async (
  error: string,
  found: Awaited<
    ReturnType<
      NonNullable<import("../src/agent-session/acpmux/conversation/turnActions").TurnActions["ownRoute"]>["find"]
    >
  >,
  extra: { use?: (routeId: string) => Promise<void>; retry?: () => void; switchModel?: boolean } = {},
) =>
  act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          ...(extra.retry ? { retry: extra.retry } : {}),
          ...(extra.switchModel === false ? {} : { switchModel: () => undefined }),
          route: { name: "Claude Code", harness: "claude" },
          ownRoute: { find: async () => found, use: extra.use ?? (async () => undefined) },
        }}
      >
        <TurnFooter row={failed(error)} />
      </TurnActionsContext.Provider>,
    ),
  );
const actionLabels = () =>
  [...card().querySelectorAll(".cv-turn-error__actions > button, .cv-turn-error__actions > a")].map(
    (element) => element.textContent,
  );

test("an API key failure with a CodeRouter route: Use cmux CodeRouter after Switch model moves the chat, then retries", async () => {
  const moved: string[] = [];
  const retried: string[] = [];
  await renderOffer("invalid x-api-key", cr, {
    use: async (routeId) => void moved.push(routeId),
    retry: () => retried.push("retry"),
  });
  expect(card().getAttribute("data-failure-kind")).toBe("invalid-key");
  expect(actionLabels()).toEqual(["Switch model", "Retry", "Use cmux CodeRouter"]);
  // The card keeps one filled button, the way out.
  expect(card().querySelectorAll(".cv-turn-error__primary").length).toBe(1);
  expect(button("Switch model")!.classList.contains("cv-turn-error__primary")).toBe(true);
  await act(async () => button("Use cmux CodeRouter")!.click());
  expect(moved).toEqual(["cmux"]);
  expect(retried).toEqual(["retry"]);
});

test("no CodeRouter route serves the chat: the action opens the CodeRouter docs", async () => {
  await renderOffer("invalid x-api-key", undefined);
  const link = card().querySelector<HTMLAnchorElement>(".cv-turn-error__actions > a")!;
  expect(link.textContent).toBe("Set up cmux CodeRouter");
  expect(link.getAttribute("href")).toBe("https://cmux.com/docs/coderouter");
  expect(link.getAttribute("target")).toBe("_blank");
});

test("a chat on CodeRouter already, or one whose routes the pane cannot read, shows no CodeRouter action", async () => {
  await renderOffer("invalid x-api-key", "on", { retry: () => undefined });
  expect(actionLabels()).toEqual(["Switch model", "Retry"]);
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ switchModel: () => undefined, retry: () => undefined }}>
        <TurnFooter row={failed("invalid x-api-key")} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(actionLabels()).toEqual(["Switch model", "Retry"]);
});

test("a failure CodeRouter does not fix offers no CodeRouter action", async () => {
  await renderOffer("agent process closed", cr, { retry: () => undefined });
  expect(actionLabels()).not.toContain("Use cmux CodeRouter");
});

test("CodeRouter alone takes the filled button; a refused move says so", async () => {
  // A sign-in failure offers no Retry, so with no Switch model CodeRouter is the one way out.
  await renderOffer("Invalid API key · Please run /login", cr, {
    switchModel: false,
    retry: () => undefined,
    use: async () => Promise.reject(new Error("no")),
  });
  expect(actionLabels()).toEqual(["Use cmux CodeRouter"]);
  expect(button("Use cmux CodeRouter")!.classList.contains("cv-turn-error__primary")).toBe(true);
  await act(async () => button("Use cmux CodeRouter")!.click());
  expect(actionLabels()).toEqual(["CodeRouter couldn't take this chat"]);
});

test("a turn that cannot be sent again offers no move onto CodeRouter, which would change nothing on the card", async () => {
  await renderOffer("invalid x-api-key", cr);
  expect(actionLabels()).toEqual(["Switch model"]);
  // The docs link does not depend on sending the turn again.
  await renderOffer("invalid x-api-key", undefined);
  expect(actionLabels()).toEqual(["Switch model", "Set up cmux CodeRouter"]);
});

test("routes the pane could not read offer nothing, not CodeRouter's setup", async () => {
  expect(readChatAccounts({ routes: [] }).unread).toBeUndefined();
  expect(readChatAccounts({ error: "nope" }).unread).toBe(true);
  expect(readChatAccounts(undefined).unread).toBe(true);
  const accountsOf = (reply: unknown) => ({
    list: async () => readChatAccounts(reply),
    set: async () => undefined,
  });
  expect(await ownRouteOf(accountsOf({ routes: [] }), "s1").find()).toBeUndefined();
  expect(await ownRouteOf(accountsOf({ routes: [cr] }), "s1").find()).toEqual(cr);
  await expect(ownRouteOf(accountsOf({ error: "nope" }), "s1").find()).rejects.toThrow("acpmux.routesUnread");
});

test("a failed turn with no prompt row to send again offers no Retry", async () => {
  const { retryRowId: _, ...row } = failed("agent process closed");
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined }}>
        <TurnFooter row={row as never} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(card().getAttribute("data-failure-kind")).toBe("agent-exited");
  expect(button("Retry")).toBeUndefined();
});
