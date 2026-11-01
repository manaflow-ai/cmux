import { expect, jest, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { MockCloudProvider } from "./mockProvider";
import { CloudOps } from "./ops";
import { CLOUD_RESTART_MIN_MS, CloudStore } from "./store";

// Dogfood, 2026-10-31: signed in with ten machines in the right sidebar, a Cloud page opened
// before the sign-in still showed the signed-out hero and Sign In, while a Cloud page opened later
// listed the machines. The page read auth once, when it opened; it now follows the app's account
// (`cmux.cloud.auth.watch`) and reads auth again on each change.

const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

test("a page opened signed out lists the machines once the app signs in elsewhere", async () => {
  const provider = new MockCloudProvider({ signedIn: false });
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  expect(store.getSnapshot().auth?.signedIn).toBe(false);
  expect(store.getSnapshot().rows).toHaveLength(0);

  provider.setSignedIn(true);
  await settle();
  const state = store.getSnapshot();
  expect(state.auth?.signedIn).toBe(true);
  expect(state.loading).toBe(false);
  expect(state.rows.map((row) => row.id)).toEqual(provider.machines.map((machine) => machine.id));
  expect(provider.watchers).toBe(1);
  unsubscribe();
});

test("a sign-out elsewhere clears the machines and closes their watch", async () => {
  const provider = new MockCloudProvider();
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  expect(store.getSnapshot().rows.length).toBeGreaterThan(0);

  provider.setSignedIn(false);
  await settle();
  const state = store.getSnapshot();
  expect(state.auth?.signedIn).toBe(false);
  expect(state.rows).toHaveLength(0);
  expect(state.plan).toBeUndefined();
  expect(provider.watchers).toBe(0);
  unsubscribe();
});

test("an account event for the account the page shows reloads nothing", async () => {
  const provider = new MockCloudProvider();
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  const lists = () => provider.calls.filter((call) => call.op === CloudOps.machineList).length;
  const before = lists();
  // The stream's first event (the current account) and a repeat change nothing.
  provider.emitAccount();
  await settle();
  expect(lists()).toBe(before);
  expect(store.getSnapshot().auth?.signedIn).toBe(true);
  unsubscribe();
});

test("the page's own Sign In and the account event load the machines once", async () => {
  // `unsupported: []`: the mock serves the host's sign-in action (a gap of today's server).
  const provider = new MockCloudProvider({ signedIn: false, unsupported: [] });
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  const signingIn = store.signIn();
  // The host's sign-in also changes the app's account: its event races the page's own reload.
  provider.emitAccount();
  await signingIn;
  await settle();
  expect(store.getSnapshot().auth?.signedIn).toBe(true);
  expect(store.getSnapshot().rows.length).toBe(provider.machines.length);
  expect(provider.watchers).toBe(1);
  expect(provider.calls.filter((call) => call.op === CloudOps.machineList)).toHaveLength(1);
  unsubscribe();
});

test("the account stream ends with the page, and a host without it still loads", async () => {
  const provider = new MockCloudProvider();
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  expect(provider.accountWatchers).toBe(1);
  unsubscribe();
  expect(provider.accountWatchers).toBe(0);

  class OlderHost extends MockCloudProvider {
    override async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
      if (stream === CloudOps.authWatch) throw pageError("cmux.protocol.unknown_op", stream);
      return super.subscribe(stream, onEvent);
    }
  }
  const older = new OlderHost();
  const page = new CloudStore(older);
  const stop = page.subscribe(() => undefined);
  await settle();
  expect(page.getSnapshot().connection).toBe("connected");
  expect(page.getSnapshot().rows.length).toBeGreaterThan(0);
  expect(page.getSnapshot().error).toBeUndefined();
  stop();
});

test("another signed-in account with the same team shape replaces the machines", async () => {
  const provider = new MockCloudProvider();
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  const other = [{ ...provider.machines[0], id: "vm_other", name: "other-box" }];
  provider.switchUser("user_2", other);
  await settle();
  expect(store.getSnapshot().rows.map((row) => row.id)).toEqual(["vm_other"]);
  unsubscribe();
});

test("an account event whose auth read fails drops the machines and reads again once the link is up", async () => {
  jest.useFakeTimers();
  try {
    const provider = new MockCloudProvider();
    const store = new CloudStore(provider);
    const unsubscribe = store.subscribe(() => undefined);
    await settle();
    expect(store.getSnapshot().rows.length).toBeGreaterThan(0);
    provider.offline = true;
    provider.signedIn = false;
    provider.emitAccount();
    await settle();
    // The old account's machines do not stay while the link is down.
    expect(store.getSnapshot()).toMatchObject({ connection: "disconnected", rows: [] });
    provider.offline = false;
    jest.advanceTimersByTime(CLOUD_RESTART_MIN_MS);
    await settle();
    expect(store.getSnapshot()).toMatchObject({ connection: "connected", auth: { signedIn: false }, rows: [] });
    expect(store.getSnapshot().error).toBeUndefined();
    unsubscribe();
  } finally {
    jest.useRealTimers();
  }
});

test("a restart while the account subscribe is in flight still follows the account", async () => {
  class SlowHost extends MockCloudProvider {
    pending: (() => void)[] = [];
    override async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
      if (stream !== CloudOps.authWatch || this.pending.length > 0) return super.subscribe(stream, onEvent);
      // The first account subscribe answers only after the page restarted.
      await new Promise<void>((resolve) => this.pending.push(resolve));
      return super.subscribe(stream, onEvent);
    }
  }
  const provider = new SlowHost({ signedIn: false });
  const store = new CloudStore(provider);
  const first = store.subscribe(() => undefined);
  await settle();
  first();
  const second = store.subscribe(() => undefined);
  await settle();
  for (const resolve of provider.pending) resolve();
  await settle();
  // The stale subscribe closed itself; the page's own one stays.
  expect(provider.accountWatchers).toBe(1);
  provider.setSignedIn(true);
  await settle();
  expect(store.getSnapshot().rows.length).toBe(provider.machines.length);
  second();
});
