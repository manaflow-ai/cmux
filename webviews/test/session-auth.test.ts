import { expect, test } from "bun:test";
import {
  authBlocksSend,
  canSessionLogin,
  useRouteAuthSwitch,
  readSessionAuth,
} from "../src/agent-session/acpmux/sessionAuth";

test("only explicit auth refusals block", () => {
  expect(authBlocksSend(readSessionAuth({ state: "signedOut", source: "authCheck", evidenceAt: 1 }))).toBe(true);
  expect(authBlocksSend(readSessionAuth({ state: "expired", source: "turn", evidenceAt: 2 }))).toBe(true);
  expect(authBlocksSend(readSessionAuth({ state: "routeAuthNeeded", source: "routeProbe", evidenceAt: 3 }))).toBe(true);
  expect(authBlocksSend(readSessionAuth({ state: "unknown", source: "none", evidenceAt: null }))).toBe(false);
  expect(authBlocksSend(readSessionAuth({ state: "routeUnreachable", source: "peerLink", evidenceAt: 4 }))).toBe(false);
  expect(authBlocksSend(readSessionAuth({ state: "peerUnreachable", source: "peerLink", evidenceAt: 5 }))).toBe(false);
});

test("invalid or missing protocol state becomes non-blocking unknown", () => {
  expect(readSessionAuth(undefined).state).toBe("unknown");
  expect(readSessionAuth({ state: "signedOut", source: "none" }).state).toBe("unknown");
  expect(readSessionAuth({ state: "ready", source: "turn", evidenceAt: 10, fromSessionId: "s1" }).fromSessionId).toBe(
    "s1",
  );
});

test("remote login evidence never opens a local terminal", async () => {
  const { sessionLogin } = await import("../src/agent-session/acpmux/sessionAuth");
  const calls: unknown[] = [];
  const auth = readSessionAuth({
    state: "expired",
    source: "turn",
    evidenceAt: 2,
    harness: "claude",
    host: "air-blue",
    login: { kind: "terminal", command: "claude /login", host: "air-blue" },
  });
  const warning = await sessionLogin(auth, async (params) => {
    calls.push(params);
  });
  expect(calls).toHaveLength(0);
  expect(warning).toContain("air-blue");
  expect(warning).toContain("claude /login");
});

test("malformed host evidence cannot turn remote login into a local command", () => {
  for (const auth of [
    {
      state: "expired",
      source: "turn",
      evidenceAt: 1,
      host: 42,
      login: { kind: "terminal", command: "claude /login" },
    },
    {
      state: "expired",
      source: "turn",
      evidenceAt: 1,
      login: { kind: "terminal", command: "claude /login", host: false },
    },
  ])
    expect(readSessionAuth(auth).state).toBe("unknown");
});

test("local login uses only the daemon's exact command and this chat's cwd", async () => {
  const { sessionLogin } = await import("../src/agent-session/acpmux/sessionAuth");
  const calls: unknown[] = [];
  const auth = readSessionAuth({
    state: "signedOut",
    source: "authCheck",
    evidenceAt: 1,
    host: null,
    login: { kind: "terminal", host: null, command: "codex login" },
  });
  expect(
    await sessionLogin(
      auth,
      async (params) => {
        calls.push(params);
      },
      "/Users/you/app",
    ),
  ).toBeUndefined();
  expect(calls).toEqual([{ kind: "terminal", text: "codex login", cwd: "/Users/you/app", run: true }]);
});

test("local recovery requires an explicit local host, never an omitted identity", () => {
  const auth = readSessionAuth({
    state: "expired",
    source: "turn",
    login: { kind: "terminal", command: "claude /login" },
  });
  expect(canSessionLogin(auth)).toBe(false);
  expect(readSessionAuth({ state: "signedOut", source: "turn", host: null }).host).toBe(null);
});

test("route coordinator holds through RPC and auth, ignoring stale account completion", async () => {
  const { act, createElement } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { JSDOM } = await import("jsdom");
  const dom = new JSDOM("<!doctype html>");
  const scope = globalThis as Record<string, unknown>;
  const oldWindow = scope.window;
  const oldDocument = scope.document;
  scope.window = dom.window;
  scope.document = dom.window.document;
  const root = createRoot(dom.window.document.createElement("div"));
  const pending: { resolve: () => void }[] = [];
  let controls: ReturnType<typeof useRouteAuthSwitch> | undefined;
  let epoch = 0;
  function Probe() {
    controls = useRouteAuthSwitch(
      async () => new Promise<void>((resolve) => pending.push({ resolve })),
      () => epoch++,
    );
    return null;
  }
  await act(async () => root.render(createElement(Probe)));
  const start = (id: string) => act(async () => void controls!.switchRoute(id, id));
  await start("A");
  expect([controls!.routeChanging, controls!.routeAuthPending, controls!.routeAuthStarted]).toEqual(["A", true, false]);
  await act(async () => pending[0]!.resolve());
  expect([controls!.routeAuthPending, controls!.routeAuthStarted, epoch]).toEqual([true, true, 1]);
  await act(async () => controls!.settleRoute("A", true));
  expect(controls!.routeAuthPending).toBe(true);
  await act(async () => controls!.settleRoute("A", false));
  expect(controls!.routeAuthPending).toBe(false);
  await start("A");
  await start("B");
  await act(async () => pending[1]!.resolve());
  expect(controls!.routeAuthStarted).toBe(false);
  await act(async () => pending[2]!.resolve());
  expect(epoch).toBe(2);
  await act(async () => controls!.settleRoute("B", false));
  expect(controls!.routeChanging).toBeUndefined();
  await act(async () => root.unmount());
  if (oldWindow === undefined) delete scope.window;
  else scope.window = oldWindow;
  if (oldDocument === undefined) delete scope.document;
  else scope.document = oldDocument;
});
