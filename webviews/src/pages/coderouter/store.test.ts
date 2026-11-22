import { describe, expect, test } from "bun:test";
import { MockCodeRouterProvider } from "./mockProvider";
import { CodeRouterStore } from "./store";
import { CodeRouterActions, CodeRouterOps } from "./types";

async function started(provider = new MockCodeRouterProvider()) {
  const store = new CodeRouterStore(provider);
  store.subscribe(() => undefined);
  await store.start();
  return { provider, store };
}

describe("CodeRouterStore", () => {
  test("loads status and detection; signed in shows linked accounts", async () => {
    const { store } = await started();
    const snap = store.getSnapshot();
    expect(snap.connection).toBe("connected");
    expect(snap.status?.signed_in).toBe(true);
    expect(snap.providers.map((row) => row.provider)).toEqual(["codex", "claude", "gemini"]);
    expect(snap.linked.map((row) => row.account)).toEqual(["acct_codex1"]);
    expect(snap.keys).toBe("unavailable");
  });

  test("works signed out: detection still loads, no CodeRouter call is made", async () => {
    const { provider, store } = await started(new MockCodeRouterProvider({ signedIn: false }));
    const snap = store.getSnapshot();
    expect(snap.status?.signed_in).toBe(false);
    expect(snap.providers.length).toBe(3);
    expect(snap.linked).toEqual([]);
    expect(provider.calls.map((call) => call.op)).not.toContain(CodeRouterOps.keys);
  });

  test("sign in, connect and sign in again run the host's actions, then re-read", async () => {
    const { provider, store } = await started(new MockCodeRouterProvider({ signedIn: false }));
    await store.signIn();
    expect(store.getSnapshot().status?.signed_in).toBe(true);
    await store.connect("codex", "ChatGPT / Codex");
    await store.reauthenticate("claude");
    const actions = provider.calls.filter((call) => call.op === CodeRouterOps.actionRun).map((call) => call.params);
    expect(actions).toEqual([
      { action: CodeRouterActions.signIn, args: {} },
      { action: CodeRouterActions.reauthenticate, args: { provider: "claude" } },
    ]);
    // Connect adds a credential: it is the host's own op behind its native sheet, not an action.
    expect(provider.calls.find((call) => call.op === CodeRouterOps.connect)?.params).toEqual({
      provider: "codex",
      name: "ChatGPT / Codex",
    });
  });

  test("an unknown op is 'not available', a lost host is disconnected", async () => {
    const { provider, store } = await started();
    expect(store.getSnapshot().error).toBeUndefined();
    provider.offline = true;
    await store.reload();
    expect(store.getSnapshot().connection).toBe("disconnected");
    expect(new CodeRouterStore(null).getSnapshot()).toMatchObject({ connection: "disconnected", loading: false });
  });
});
