// A failed turn showed acpmux's bare "agent process closed" with an outlined Copy error, and a full
// disk or a tailnet that no longer reached the chat's machine read the same way (Leo 2026-10-22:
// "we need to have prettier errors" and "we also wanna make sure we have good
// recoverable/informative disk errors tailscale erros for acpmux"). The card says the cause in one
// human line, offers the way out first, and keeps the agent's own words under Details with Copy.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { openClaudeCloudSettings } from "../src/agent-session/acpmux/claudeConnect";

import { teardownDom } from "./support/domTeardown";
import { importWithDom } from "./support/importWithDom";

const { failureCopy, failureKind, failureRecovery } = await importWithDom(
  () => import("../src/agent-session/acpmux/failureCopy"),
);
const { readChatAccounts } = await importWithDom(() => import("../src/agent-session/acpmux/chatAccounts"));
const { translatorFor } = await importWithDom(() => import("../src/agent-session/acpmux/i18n"));

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

test("cloud auth failures explain safe causes without leaking provider output or machine names", () => {
  const cloud = { name: "Claude Code", harness: "claude", hostKind: "cloud" as const, host: "secret-host.internal" };
  expect(failureCopy(t, "Claude failed to authenticate: credential is missing", cloud)).toBe(
    "This Cloud machine has no provider credential for Claude Code. Set it up to continue.",
  );
  expect(failureCopy(t, "OAuth token expired (HTTP 401): raw-secret-value", cloud, "claude_cloud_token_rejected")).toBe(
    "Claude refused the Cloud sign-in. Set it up again.",
  );
  expect(failureCopy(t, "credential was revoked: raw-secret-value", cloud)).toBe(
    "Claude Code’s provider credential has expired or been revoked on this Cloud machine. Set it up again to continue.",
  );
  expect(failureCopy(t, "HTTP 403 Forbidden: raw-secret-value", cloud)).toBe(
    "The provider rejected Claude Code’s credentials on this Cloud machine (HTTP 403). Set them up again to continue.",
  );
  expect(failureKind("HTTP 401 Unauthorized from https://proxy.tail123.ts.net/v1/messages", cloud)).toBe("proxy-auth");
  expect(failureKind("needs a team account on this machine; run cr add claude", cloud)).toBe("no-team-account");
});

test("the way out: Retry for what may pass (capacity too), Switch model for keys, Sign in again for sign-in", () => {
  expect(failureRecovery("disk-full")).toBe("retry");
  expect(failureRecovery("tailscale")).toBe("retry");
  expect(failureRecovery("agent-exited")).toBe("retry");
  expect(failureRecovery("other")).toBe("retry");
  // Capacity passes (Lawrence 2026-10-29): Continue or Retry leads, Switch model beside it.
  expect(failureRecovery("rate-limited")).toBe("retry");
  expect(failureRecovery("invalid-key")).toBe("switch-model");
  expect(failureRecovery("subscription-login")).toBe("sign-in");
  expect(failureRecovery("auth")).toBe("sign-in");
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

afterAll(async () => {
  act(() => root.unmount());
  await teardownDom(saved, { window: dom.window, scope });
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
const { FailedSendsContext } = await import("../src/agent-session/acpmux/conversation/promptDeliveryModel");
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

test("a turn the folder's trust held offers Trust folder from its card, where the pane answers for the folder", async () => {
  for (const error of [
    "trust.pending: answer the trust question for the folder first",
    "trust.untrusted: the folder is not trusted",
  ]) {
    let trusted = 0;
    await act(async () =>
      root.render(
        <TurnActionsContext.Provider value={{ retry: () => undefined }}>
          <FailedSendsContext.Provider value={{ runs: new Map(), trustFolder: () => void trusted++ }}>
            <TurnFooter row={failed(error)} />
          </FailedSendsContext.Provider>
        </TurnActionsContext.Provider>,
      ),
    );
    const trust = button("Trust folder");
    expect(trust, error).toBeDefined();
    expect(trust!.classList.contains("cv-turn-error__primary")).toBe(true);
    await act(async () => trust!.click());
    expect(trusted).toBe(1);
    // A folder already trusted, or one this pane may not answer for, offers no Trust folder.
    await act(async () =>
      root.render(
        <TurnActionsContext.Provider value={{ retry: () => undefined }}>
          <FailedSendsContext.Provider value={{ runs: new Map() }}>
            <TurnFooter row={failed(error)} />
          </FailedSendsContext.Provider>
        </TurnActionsContext.Provider>,
      ),
    );
    expect(button("Trust folder")).toBeUndefined();
  }
});

test("a Cloud 401 names the rejected credentials, never the machine's host", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          route: { name: "Claude Code", harness: "claude", hostKind: "cloud", host: "private.internal" },
          retry: () => undefined,
        }}
      >
        <TurnFooter row={failed("HTTP 401 Unauthorized")} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(card().querySelector(".cv-turn-error__cause")!.textContent).toBe(
    "The provider rejected Claude Code’s credentials on this Cloud machine (HTTP 401). Set them up again to continue.",
  );
  expect(card().textContent).not.toContain("private.internal");
});

test("a Claude Cloud setup token rejection opens Models for the affected machine on the user's click", async () => {
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  let transferred = 0;
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          route: { name: "Claude", harness: "claude", hostKind: "cloud" },
          openClaudeCloudSettings: openClaudeCloudSettings(async (method, params) => {
            calls.push({ method, params });
          }, "vm_b"),
          transferCloudCredentials: async () => {
            transferred++;
          },
          switchModel: () => undefined,
        }}
      >
        <TurnFooter row={{ ...failed("HTTP 401 Unauthorized", "claude_cloud_token_rejected"), retryable: true }} />
      </TurnActionsContext.Provider>,
    ),
  );
  const renewal = button("Set up Claude for Cloud again");
  expect(renewal?.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(calls).toEqual([]);
  await act(async () => renewal!.click());
  expect(calls).toEqual([{ method: "cloud.connect", params: { family: "claude", machine: "vm_b" } }]);
  expect(transferred).toBe(0);
});

test("capacity puts Retry first, Switch model after it", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined, switchModel: () => undefined }}>
        <TurnFooter row={failed("API Error: 529 overloaded_error")} />
      </TurnActionsContext.Provider>,
    ),
  );
  const labels = [...card().querySelectorAll(".cv-turn-error__actions > button")].map((element) => element.textContent);
  expect(labels).toEqual(["Retry", "Switch model"]);
  expect(button("Retry")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Switch model")!.classList.contains("cv-turn-error__primary")).toBe(false);
});

// Leo 2026-11-03, on a card that led with Switch model when the model's server could not be reached:
// "this ui is pretty awkward looking". Which action leads, per error kind.
const leadLabels = () =>
  [...card().querySelectorAll(".cv-turn-error__actions > button")].map((element) => element.textContent);
const isPrimary = (label: string) => button(label)!.classList.contains("cv-turn-error__primary");

test("a server that cannot be reached leads with Retry, Switch model after it", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined, switchModel: () => undefined }}>
        <TurnFooter row={failed("API Error: Connection error.")} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(card().getAttribute("data-failure-kind")).toBe("unreachable");
  expect(leadLabels()).toEqual(["Retry", "Switch model"]);
  expect(isPrimary("Retry")).toBe(true);
  expect(isPrimary("Switch model")).toBe(false);
});

test("an unreachable card with no Retry keeps Switch model outlined, never the filled lead", async () => {
  // An earlier turn (or one a retry already went on from) has no prompt of its own to send again.
  const earlier = { ...failed("connect ECONNREFUSED 127.0.0.1:443"), prompt: undefined, retryRowId: undefined };
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined, switchModel: () => undefined }}>
        <TurnFooter row={earlier} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(card().getAttribute("data-failure-kind")).toBe("unreachable");
  expect(leadLabels()).toEqual(["Switch model"]);
  expect(isPrimary("Switch model")).toBe(false);
});

test("Retry on an unreachable card goes through acpmux's turn retry and waits while it is in flight", async () => {
  const calls: string[] = [];
  let settle: () => void = () => undefined;
  const retryFailed = (rowId: string | undefined, prompt: string | undefined) => {
    calls.push(`${rowId}:${prompt}`);
    return new Promise<undefined>((resolve) => (settle = () => resolve(undefined)));
  };
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retryFailed, switchModel: () => undefined }}>
        <TurnFooter row={{ ...failed("fetch failed"), retryable: true }} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(leadLabels()).toEqual(["Retry", "Switch model"]);
  expect(isPrimary("Retry")).toBe(true);
  await act(async () => button("Retry")!.click());
  expect(calls).toEqual(["user-1:Run the sidebar tests and fix what fails"]);
  expect(button("Retry")!.hasAttribute("disabled")).toBe(true);
  await act(async () => settle());
  expect(button("Retry")!.hasAttribute("disabled")).toBe(false);
});

test("a failure about the model's route still leads with Switch model, Retry after it", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined, switchModel: () => undefined }}>
        <TurnFooter row={failed("invalid x-api-key")} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(card().getAttribute("data-failure-kind")).toBe("invalid-key");
  expect(leadLabels()).toEqual(["Switch model", "Retry"]);
  expect(isPrimary("Switch model")).toBe(true);
  expect(isPrimary("Retry")).toBe(false);
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

// A turn that failed because the agent's login expired put Sign in again in the footer, which shows
// only on hover, offered no Retry on the card, and nothing sent the prompt again after the login:
// two things to discover and the prompt to retype. The card leads with Sign in again and keeps Retry
// beside it for once the login is done.
const signedOut = "Not logged in · Please run /login";
// The last turn's row as turns.ts draws it: retryable, so the failed turn's own retry serves it.
const signedOutRow = () => ({ ...failed(signedOut), retryable: true });

test("a sign-in failure's card leads with Sign in again, then Retry, then Switch model", async () => {
  const done: string[] = [];
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          retry: () => done.push("resend"),
          retryFailed: () => {
            done.push("retry");
            return Promise.resolve(undefined);
          },
          switchModel: () => done.push("switch"),
          reauthenticate: () => done.push("sign-in"),
        }}
      >
        <TurnFooter row={signedOutRow()} />
      </TurnActionsContext.Provider>,
    ),
  );
  expect(card().getAttribute("data-failure-kind")).toBe("subscription-login");
  const labels = [...card().querySelectorAll(".cv-turn-error__actions > button")].map((element) => element.textContent);
  expect(labels).toEqual(["Sign in again", "Retry", "Switch model"]);
  expect(card().querySelectorAll(".cv-turn-error__primary").length).toBe(1);
  expect(button("Sign in again")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(button("Retry")!.classList.contains("cv-turn-error__primary")).toBe(false);
  expect(button("Switch model")!.classList.contains("cv-turn-error__primary")).toBe(false);
  await act(async () => button("Sign in again")!.click());
  await act(async () => button("Retry")!.click());
  expect(done).toEqual(["sign-in", "retry"]);
  // One Sign in again: the card's, not a second one in the footer row.
  expect(host.querySelectorAll(".cv-turn-actions .cv-turn-auth-action").length).toBe(0);
});

test("a sign-in failure with a login but no Retry leads with Sign in again, Switch model after it", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ switchModel: () => undefined, reauthenticate: () => undefined }}>
        <TurnFooter row={failed(signedOut)} />
      </TurnActionsContext.Provider>,
    ),
  );
  const labels = [...card().querySelectorAll(".cv-turn-error__actions > button")].map((element) => element.textContent);
  expect(labels).toEqual(["Sign in again", "Switch model"]);
  expect(card().querySelectorAll(".cv-turn-error__primary").length).toBe(1);
  expect(button("Sign in again")!.classList.contains("cv-turn-error__primary")).toBe(true);
});

// A View Only chat, a read-only pane or one whose composer cannot send has no `retryFailed` (App's
// `restartChat`), only the plain resend, which sends to whichever chat the pane shows: its sign-in
// card offered a Retry that could do nothing, or reach the next chat during a switch.
test("a sign-in card in a View Only chat or a read-only pane offers no Retry, only Sign in again", async () => {
  const sent: string[] = [];
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider
        value={{
          retry: (rowId) => sent.push(rowId),
          switchModel: () => undefined,
          reauthenticate: () => undefined,
        }}
      >
        <TurnFooter row={signedOutRow()} />
      </TurnActionsContext.Provider>,
    ),
  );
  const labels = [...card().querySelectorAll(".cv-turn-error__actions > button")].map((element) => element.textContent);
  expect(labels).toEqual(["Sign in again", "Switch model"]);
  expect(card().querySelectorAll(".cv-turn-error__primary").length).toBe(1);
  expect(button("Sign in again")!.classList.contains("cv-turn-error__primary")).toBe(true);
  expect(sent).toEqual([]);
});

// Sign in again leads a sign-in card and is its one filled button: never Switch model beside it,
// with or without a Retry, for the CLI's own login and an unexplained 401 alike.
test("a sign-in card with Sign in again and Switch model fills only Sign in again", async () => {
  for (const error of [signedOut, "HTTP 401 Unauthorized"])
    for (const withRetry of [false, true]) {
      await act(async () =>
        root.render(
          <TurnActionsContext.Provider
            value={{
              switchModel: () => undefined,
              reauthenticate: () => undefined,
              ...(withRetry && { retry: () => undefined, retryFailed: () => Promise.resolve(undefined) }),
            }}
          >
            <TurnFooter row={{ ...failed(error), retryable: true }} />
          </TurnActionsContext.Provider>,
        ),
      );
      const labels = [...card().querySelectorAll(".cv-turn-error__actions > button")].map(
        (element) => element.textContent,
      );
      const filled = [...card().querySelectorAll(".cv-turn-error__primary")].map((element) => element.textContent);
      expect([error, withRetry, labels]).toEqual([
        error,
        withRetry,
        withRetry ? ["Sign in again", "Retry", "Switch model"] : ["Sign in again", "Switch model"],
      ]);
      expect([error, withRetry, filled]).toEqual([error, withRetry, ["Sign in again"]]);
    }
});

test("a sign-in failure with no login to run keeps Switch model alone, with no Retry that would fail again", async () => {
  await act(async () =>
    root.render(
      <TurnActionsContext.Provider value={{ retry: () => undefined, switchModel: () => undefined }}>
        <TurnFooter row={failed(signedOut)} />
      </TurnActionsContext.Provider>,
    ),
  );
  const labels = [...card().querySelectorAll(".cv-turn-error__actions > button")].map((element) => element.textContent);
  expect(labels).toEqual(["Switch model"]);
  expect(button("Switch model")!.classList.contains("cv-turn-error__primary")).toBe(true);
});

test("routes the pane could not read say so", () => {
  expect(readChatAccounts({ routes: [] }).unread).toBeUndefined();
  expect(readChatAccounts({ error: "nope" }).unread).toBe(true);
  expect(readChatAccounts(undefined).unread).toBe(true);
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
