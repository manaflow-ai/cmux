import { describe, expect, test } from "bun:test";
import { MockPasswordsProvider, sampleData, shippingData } from "./mockProvider";
import { PasswordsStore } from "./store";
import { PasswordOps } from "./types";

async function started(provider = new MockPasswordsProvider()) {
  let n = 0;
  const store = new PasswordsStore(provider, { newKey: () => `k${++n}` });
  await store.start();
  return { store, provider };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("passwords store", () => {
  test("loads every available section of the first profile", async () => {
    const { store } = await started();
    const snap = store.getSnapshot();
    expect(snap.connection).toBe("connected");
    expect(snap.loading).toBe(false);
    expect(snap.profile).toBe("default");
    expect(snap.passwords.length).toBe(4);
    expect(snap.passkeys.length).toBe(1);
    expect(snap.exceptions.length).toBe(1);
  });

  test("a build without the fork password API asks only for passkeys", async () => {
    const { store, provider } = await started(new MockPasswordsProvider(shippingData()));
    const snap = store.getSnapshot();
    expect(snap.sections).toEqual({ passwords: false, passkeys: true, exceptions: false, export: false });
    expect(snap.passwords).toEqual([]);
    expect(snap.passkeys.length).toBe(1);
    const ops = provider.calls.map((c) => c.op);
    expect(ops).not.toContain(PasswordOps.list);
    expect(ops).not.toContain(PasswordOps.exceptionsList);
  });

  test("an unavailable refusal marks the section unavailable instead of failing", async () => {
    const provider = new MockPasswordsProvider();
    // The state claims passkeys, but the list refuses (the fork went away).
    const answer = provider.call.bind(provider);
    provider.call = async <R>(op: string, params: unknown) => {
      if (op === PasswordOps.passkeysList) {
        provider.data.sections.passkeys = false;
        const result = await answer<R>(op, params).catch((error: unknown) => {
          provider.data.sections.passkeys = true;
          throw error;
        });
        return result;
      }
      return answer<R>(op, params);
    };
    const { store } = await started(provider);
    expect(store.getSnapshot().sections.passkeys).toBe(false);
    expect(store.getSnapshot().notice).toBeUndefined();
    expect(store.getSnapshot().passwords.length).toBe(4);
  });

  test("writes send the profile and a fresh idempotency key, then re-read", async () => {
    const { store, provider } = await started();
    const row = store.getSnapshot().passwords.find((r) => r.id === "p3")!;
    await store.removePassword(row);
    const call = provider.calls.find((c) => c.op === PasswordOps.remove)!;
    expect(call.params).toEqual({ profile: "default", ids: ["p3"], idempotency_key: "k1" });
    expect(store.getSnapshot().passwords.map((r) => r.id)).not.toContain("p3");
  });

  test("a declined native sheet changes nothing and shows no failure", async () => {
    const provider = new MockPasswordsProvider();
    provider.confirm = false;
    const { store } = await started(provider);
    await store.removePasskey(store.getSnapshot().passkeys[0]!);
    expect(store.getSnapshot().passkeys.length).toBe(1);
    expect(store.getSnapshot().notice).toBeUndefined();
  });

  test("reveal and copy never bring a password into the page", async () => {
    const { store, provider } = await started();
    const row = store.getSnapshot().passwords[0]!;
    await store.reveal(row);
    await store.copy(row);
    expect(provider.revealed).toBe(1);
    expect(provider.copied).toBe(1);
    expect(store.getSnapshot().notice).toEqual({ kind: "copied" });
    expect(JSON.stringify(store.getSnapshot())).not.toContain("sample-pass");
    // No idempotency key: each reveal asks the person again.
    expect(provider.calls.find((c) => c.op === PasswordOps.reveal)!.params).toEqual({ profile: "default", id: row.id });
  });

  test("a failed device owner authentication shows its reason", async () => {
    const provider = new MockPasswordsProvider();
    provider.authenticate = false;
    const { store } = await started(provider);
    await store.copy(store.getSnapshot().passwords[0]!);
    expect(store.getSnapshot().notice).toEqual({ kind: "failed", message: "cmux could not confirm that it is you." });
  });

  test("username edits commit only a changed value", async () => {
    const { store, provider } = await started();
    const row = store.getSnapshot().passwords.find((r) => r.id === "p4")!;
    store.editUsername(row);
    expect(store.getSnapshot().editing).toBe("p4");
    await store.commitUsername(row, "  ");
    expect(provider.calls.some((c) => c.op === PasswordOps.usernameSet)).toBe(false);
    await store.commitUsername(row, " reader ");
    expect(store.getSnapshot().passwords.find((r) => r.id === "p4")!.username).toBe("reader");
    expect(store.getSnapshot().editing).toBeUndefined();
  });

  test("switching profiles loads that profile; other profiles' changes do not reload", async () => {
    const { store, provider } = await started();
    store.setProfile("work");
    await flush();
    await flush();
    expect(store.getSnapshot().passwords.map((r) => r.id)).toEqual(["w1"]);
    const before = provider.calls.length;
    provider.emitChanged("default");
    await flush();
    expect(provider.calls.length).toBe(before);
    provider.emitChanged("work");
    await flush();
    expect(provider.calls.length).toBeGreaterThan(before);
  });

  test("export runs once and reports it", async () => {
    const { store, provider } = await started(new MockPasswordsProvider(sampleData()));
    await store.exportAll();
    expect(provider.exported).toBe(1);
    expect(store.getSnapshot().notice).toEqual({ kind: "exported" });
  });

  test("a lost link shows the disconnected state and reloads on reconnect", async () => {
    const { store, provider } = await started();
    provider.streams.setConnected(false);
    expect(store.getSnapshot().connection).toBe("disconnected");
    provider.streams.setConnected(true);
    await flush();
    await flush();
    expect(store.getSnapshot().connection).toBe("connected");
  });

  test("without a client the page is disconnected and makes no calls", async () => {
    const store = new PasswordsStore(null);
    await store.start();
    expect(store.getSnapshot().connection).toBe("disconnected");
    await store.removePassword(sampleData().passwords.default![0]!);
  });
});
