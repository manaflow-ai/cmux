// When the page has reason to think the account is signed in (a kept list, or a signed-in account
// before a reconnect), it asks for the machine watch and list together with the account read, not after
// it (Leo, 2026-11-14: "load faster/percievably load faster / whatever it takes"): the owner's list is
// on screen one round trip sooner. A signed-out answer drops what was asked early.
import { expect, test } from "bun:test";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { CloudOps } from "./ops";
import { CloudStore } from "./store";

const settle = async () => {
  for (let i = 0; i < 40; i++) await Promise.resolve();
};

class MemoryStorage {
  readonly items = new Map<string, string>();
  getItem(key: string): string | null {
    return this.items.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.items.set(key, value);
  }
  removeItem(key: string): void {
    this.items.delete(key);
  }
}

function kept(team = "team_personal"): MemoryStorage {
  const storage = new MemoryStorage();
  storage.setItem("cmux.cloud.machines.v1", JSON.stringify({ team, machines: sampleMachines(), revision: 1 }));
  return storage;
}

/** The account read answers only when the test lets it. */
class HeldAuthProvider extends MockCloudProvider {
  private release?: () => void;
  private authHeld = new Promise<void>((resolve) => (this.release = resolve));
  answer(): void {
    this.release?.();
  }
  hold(): void {
    this.authHeld = new Promise<void>((resolve) => (this.release = resolve));
  }
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === CloudOps.authStatus) await this.authHeld;
    return super.call<R>(op, params);
  }
  asked(op: string): number {
    return this.calls.filter((call) => call.op === op).length;
  }
}

test("with a kept list, the watch and the list are asked before the account read answers", async () => {
  const provider = new HeldAuthProvider();
  const store = new CloudStore(provider, { cache: kept() });
  const stop = store.subscribe(() => undefined);
  try {
    await settle();
    expect(provider.asked(`subscribe ${CloudOps.machineWatch}`)).toBe(1);
    expect(provider.asked(CloudOps.machineList)).toBe(1);
    provider.answer();
    await settle();
    expect(store.getSnapshot()).toMatchObject({ connection: "connected", loading: false });
    expect(store.getSnapshot().machines.map((machine) => machine.id)).toEqual(sampleMachines().map((m) => m.id));
    // The early read is the read: nothing is asked twice, and one watch stays.
    expect(provider.asked(CloudOps.machineList)).toBe(1);
    expect(provider.watchers).toBe(1);
  } finally {
    stop();
  }
});

test("a signed-out answer drops the early watch and shows no machines", async () => {
  const provider = new HeldAuthProvider({ signedIn: false });
  const store = new CloudStore(provider, { cache: kept() });
  const stop = store.subscribe(() => undefined);
  try {
    await settle();
    provider.answer();
    await settle();
    expect(store.getSnapshot().auth?.signedIn).toBe(false);
    expect(store.getSnapshot().machines).toEqual([]);
    expect(store.getSnapshot().error).toBeUndefined();
    expect(provider.watchers).toBe(0);
  } finally {
    stop();
  }
});

test("with no kept list and no account known, the account read still goes first", async () => {
  const provider = new HeldAuthProvider();
  const store = new CloudStore(provider);
  const stop = store.subscribe(() => undefined);
  try {
    await settle();
    expect(provider.asked(CloudOps.machineList)).toBe(0);
    provider.answer();
    await settle();
    expect(store.getSnapshot().machines).toHaveLength(sampleMachines().length);
  } finally {
    stop();
  }
});

test("a reconnect of a signed-in page asks for the list with the account read too", async () => {
  const provider = new HeldAuthProvider();
  provider.answer();
  const store = new CloudStore(provider);
  const stop = store.subscribe(() => undefined);
  try {
    await settle();
    expect(store.getSnapshot().auth?.signedIn).toBe(true);
    provider.hold();
    const before = provider.asked(CloudOps.machineList);
    // A reconnect is a fresh session that keeps what the page shows (`readAgainLater`: stop, then start).
    store.stop();
    void store.start();
    await settle();
    expect(provider.asked(CloudOps.machineList)).toBe(before + 1);
    provider.answer();
    await settle();
    expect(store.getSnapshot()).toMatchObject({ connection: "connected", loading: false });
    expect(provider.asked(CloudOps.machineList)).toBe(before + 1);
    expect(provider.watchers).toBe(1);
  } finally {
    stop();
  }
});
