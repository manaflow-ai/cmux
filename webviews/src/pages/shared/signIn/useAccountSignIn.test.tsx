// The in-place sign-in controller's lifetimes (logins done right; Leo, 2026-11-22: "this is simply
// logins, done righr."): Cancel while a start waits on its host ends it (no card comes back, no
// terminal opens, a login the daemon started anyway is cancelled), a second click on the same row
// starts nothing, a click on another row supersedes the first (its login cancelled, its fallback
// never run), leaving the page cancels the daemon's login, and a host that ran the terminal
// sign-in itself (`terminal`) gets no second one from the page.
import { act } from "react";
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "../../settings/testDom";
import type { AccountRunParams, AccountRunResult, SignInStartWire } from "./accountSignIn";
import type { AccountSignInController, AccountSignInTransport } from "./useAccountSignIn";

const restore = installDom();
afterAll(() => restore());
const { createRoot } = await import("react-dom/client");
const { useAccountSignIn } = await import("./useAccountSignIn");

let unmount: (() => void) | null = null;
afterEach(() => {
  unmount?.();
  unmount = null;
  document.body.replaceChildren();
});

/** A host whose answers the test sends when it likes; every call is recorded. */
function host() {
  const calls: AccountRunParams[] = [];
  const pending: Array<(reply: AccountRunResult) => void> = [];
  const transport: AccountSignInTransport = {
    run: (params) => {
      calls.push(params);
      // A finish waits for the person's approval, which never comes here.
      if (params.action === "signInFinish") return new Promise(() => {});
      if (params.action !== "signInStart") return Promise.resolve({ ok: true, value: {} });
      return new Promise((resolve) => pending.push(resolve));
    },
  };
  return { calls, pending, transport };
}

const started = (loginId: string, account = "codex-1"): AccountRunResult => ({
  ok: true,
  value: {
    signIn: {
      account,
      loginId,
      url: "https://auth.openai.com/codex/device",
      userCode: "K7QX-29PF",
      needsCode: false,
      expiresAtMs: Date.now() + 60_000,
      added: false,
    } satisfies SignInStartWire,
  },
});
const older: AccountRunResult = { ok: true, value: {} };

async function mount(transport: AccountSignInTransport) {
  const seen: { now: AccountSignInController | null } = { now: null };
  function Probe() {
    seen.now = useAccountSignIn(transport);
    return null;
  }
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => root.render(<Probe />));
  unmount = () => act(() => root.unmount());
  return seen;
}

const settle = () => act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
const cancels = (calls: AccountRunParams[]) =>
  calls.filter((call) => call.action === "signInCancel").map((call) => call.loginId);

test("Cancel while starting on an older host: no terminal opens and no card comes back", async () => {
  const h = host();
  const seen = await mount(h.transport);
  let terminals = 0;
  await act(async () => seen.now!.start("codex", "codex-1", undefined, () => terminals++));
  expect(seen.now!.running?.view.state).toBe("starting");
  await act(async () => seen.now!.cancel());
  await act(async () => h.pending[0]!(older));
  await settle();
  expect(terminals).toBe(0);
  expect(seen.now!.running).toBeNull();
});

test("Cancel while starting on a new daemon: the late login is cancelled and drawn nowhere", async () => {
  const h = host();
  const seen = await mount(h.transport);
  await act(async () => seen.now!.start("codex", "codex-1"));
  await act(async () => seen.now!.cancel());
  await act(async () => h.pending[0]!(started("login-1")));
  await settle();
  expect(seen.now!.running).toBeNull();
  expect(cancels(h.calls)).toEqual(["login-1"]);
});

test("a second click on the same row starts nothing; another row supersedes the first", async () => {
  const h = host();
  const seen = await mount(h.transport);
  let first = 0;
  let second = 0;
  await act(async () => seen.now!.start("codex", "codex-1", undefined, () => first++));
  await act(async () => seen.now!.start("codex", "codex-1", undefined, () => first++));
  expect(h.calls.filter((call) => call.action === "signInStart")).toHaveLength(1);
  // Waiting on its code, a click on the same row still starts nothing.
  await act(async () => h.pending[0]!(started("login-1")));
  await settle();
  expect(seen.now!.running?.view.state).toBe("waiting");
  await act(async () => seen.now!.start("codex", "codex-1"));
  expect(h.calls.filter((call) => call.action === "signInStart")).toHaveLength(1);
  // Another row: the first login is cancelled, and the second start keeps its own fallback.
  await act(async () => seen.now!.start("claude", null, undefined, () => second++));
  expect(cancels(h.calls)).toEqual(["login-1"]);
  await act(async () => h.pending[1]!(older));
  await settle();
  expect(first).toBe(0);
  expect(second).toBe(1);
});

test("a superseded start's late answer runs no fallback and its login is cancelled", async () => {
  const h = host();
  const seen = await mount(h.transport);
  let first = 0;
  await act(async () => seen.now!.start("codex", "codex-1", undefined, () => first++));
  await act(async () => seen.now!.start("claude", null));
  await act(async () => h.pending[0]!(started("login-1")));
  await act(async () => h.pending[1]!(started("login-2", "claude-2")));
  await settle();
  expect(first).toBe(0);
  expect(cancels(h.calls)).toEqual(["login-1"]);
  expect(seen.now!.running?.account).toBe("claude-2");
});

test("leaving the page mid sign-in cancels the daemon's login", async () => {
  const h = host();
  const seen = await mount(h.transport);
  await act(async () => seen.now!.start("codex", "codex-1"));
  await act(async () => h.pending[0]!(started("login-1")));
  await settle();
  unmount!();
  unmount = null;
  expect(cancels(h.calls)).toEqual(["login-1"]);
});

test("leaving the page while starting cancels the login its host answers later", async () => {
  const h = host();
  const seen = await mount(h.transport);
  let terminals = 0;
  await act(async () => seen.now!.start("codex", "codex-1", undefined, () => terminals++));
  unmount!();
  unmount = null;
  await act(async () => h.pending[0]!(started("login-1")));
  await settle();
  expect(cancels(h.calls)).toEqual(["login-1"]);
  expect(terminals).toBe(0);
});

test("a host that ran the terminal sign-in itself gets no second one from the page", async () => {
  const h = host();
  const fallback: string[] = [];
  const seen = await mount({ ...h.transport, fallback: (family) => fallback.push(family) });
  let terminals = 0;
  await act(async () => seen.now!.start("codex", "codex-1", undefined, () => terminals++));
  await act(async () => h.pending[0]!({ ok: true, value: { terminal: true } }));
  await settle();
  expect(terminals).toBe(0);
  expect(fallback).toEqual([]);
  expect(seen.now!.running).toBeNull();
  // An older host (no `terminal`): the start's own fallback, not the transport's.
  await act(async () => seen.now!.start("codex", "codex-1", undefined, () => terminals++));
  await act(async () => h.pending[1]!(older));
  await settle();
  expect(terminals).toBe(1);
  expect(fallback).toEqual([]);
});
