import { afterEach, expect, jest, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { MockCloudProvider } from "./mockProvider";
import { CloudOps } from "./ops";
import { CLOUD_RESTART_MAX_MS, CLOUD_RESTART_MIN_MS, CloudStore } from "./store";

// Leo, 2026-10-29: "STOP SHOWING FUCKING BULLSHIT ON LOAD". On a launch the daemon (or its Cloud
// relay) is not up when the page first reads auth: the store reads again on its own, so the page
// comes up once the link does instead of staying "disconnected" until someone presses Retry.
afterEach(() => jest.useRealTimers());

/** The mock provider whose first `refusals` auth reads the link refuses. */
class StartingProvider extends MockCloudProvider {
  authReads = 0;
  constructor(public refusals: number) {
    super();
  }
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === CloudOps.authStatus) this.authReads += 1;
    if (op === CloudOps.authStatus && this.refusals > 0) {
      this.refusals -= 1;
      throw pageError("cmux.protocol.transport", "the local cmux daemon is restarting", true);
    }
    return super.call<R>(op, params);
  }
}

class TerminalAfterTransportProvider extends StartingProvider {
  terminal = false;

  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === CloudOps.authStatus && this.authReads > 0 && !this.terminal) {
      this.terminal = true;
      throw pageError("cmux.cloud.upstream_error", "the Cloud service did not answer", true);
    }
    return super.call<R>(op, params);
  }
}

const settle = async () => {
  for (let i = 0; i < 10; i++) await Promise.resolve();
};

test("a first auth read the link refuses is read again on its own until the link is up", async () => {
  jest.useFakeTimers();
  const provider = new StartingProvider(2);
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  expect(store.getSnapshot().connection).toBe("disconnected");
  jest.advanceTimersByTime(CLOUD_RESTART_MIN_MS);
  await settle();
  // Still refused: the store stays disconnected (no "connecting" flash) and waits twice as long.
  expect(store.getSnapshot().connection).toBe("disconnected");
  jest.advanceTimersByTime(CLOUD_RESTART_MIN_MS * 2 - 1);
  await settle();
  expect(provider.refusals).toBe(0);
  expect(store.getSnapshot().connection).toBe("disconnected");
  jest.advanceTimersByTime(1);
  await settle();
  expect(store.getSnapshot().connection).toBe("connected");
  expect(store.getSnapshot().auth?.signedIn).toBe(true);
  // The refused read's error does not outlive the recovery (no stale banner).
  expect(store.getSnapshot().error).toBeUndefined();
  expect(store.getSnapshot().errorCode).toBeUndefined();
  unsubscribe();
});

test("a signed-out page that recovers keeps no error and stops loading", async () => {
  jest.useFakeTimers();
  const provider = new StartingProvider(1);
  provider.signedIn = false;
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  expect(store.getSnapshot().error).toBe("the local cmux daemon is restarting");
  jest.advanceTimersByTime(CLOUD_RESTART_MIN_MS);
  await settle();
  expect(store.getSnapshot()).toMatchObject({ connection: "connected", loading: false });
  expect(store.getSnapshot().auth?.signedIn).toBe(false);
  expect(store.getSnapshot().error).toBeUndefined();
  unsubscribe();
});

test("a terminal retry error keeps an explicit failed state", async () => {
  jest.useFakeTimers();
  const provider = new TerminalAfterTransportProvider(1);
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  expect(store.getSnapshot().connection).toBe("disconnected");
  jest.advanceTimersByTime(CLOUD_RESTART_MIN_MS);
  await settle();
  expect(store.getSnapshot()).toMatchObject({ connection: "failed", loading: false });
  expect(store.getSnapshot().error).toBe("the Cloud service did not answer");
  unsubscribe();
});

test("the re-reads back off to the cap and end when the page stops listening", async () => {
  jest.useFakeTimers();
  const provider = new StartingProvider(1_000);
  const store = new CloudStore(provider);
  const unsubscribe = store.subscribe(() => undefined);
  await settle();
  // Past the doubling (1, 2, 4, 8 s) the wait is the cap.
  for (let i = 0; i < 6; i++) {
    jest.advanceTimersByTime(CLOUD_RESTART_MAX_MS);
    await settle();
  }
  // At the cap: exactly one read per cap window, never more (still doubling) or none (past it).
  for (let i = 0; i < 3; i++) {
    const before = provider.authReads;
    jest.advanceTimersByTime(CLOUD_RESTART_MAX_MS);
    await settle();
    expect(provider.authReads).toBe(before + 1);
  }
  expect(store.getSnapshot().connection).toBe("disconnected");
  unsubscribe();
  const stopped = provider.authReads;
  jest.advanceTimersByTime(CLOUD_RESTART_MAX_MS * 4);
  await settle();
  expect(provider.authReads).toBe(stopped);
});
