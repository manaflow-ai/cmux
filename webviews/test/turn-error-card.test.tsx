// A failed turn showed acpmux's bare "agent process closed" with an outlined Copy error, and a full
// disk or a tailnet that no longer reached the chat's machine read the same way (Leo 2026-10-22:
// "we need to have prettier errors" and "we also wanna make sure we have good
// recoverable/informative disk errors tailscale erros for acpmux"). The card says the cause in one
// human line, offers the way out first, and keeps the agent's own words under Details with Copy.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { failureCopy, failureKind, failureRecovery } from "../src/agent-session/acpmux/failureCopy";
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
