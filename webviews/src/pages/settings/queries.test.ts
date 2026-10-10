// The query layer over the one transport: a write shows at once (optimistic), goes back when the
// owner refuses it, and the owner's change event re-reads the scope. The store runs on any
// SettingsTransport, so moving the owner (a Rust config service) changes only the transport.
import { expect, test } from "bun:test";
import type { ListRow, SettingsClient } from "./ops";
import { settingsKeys } from "./queries";
import { schema } from "./schema";
import { SettingsStore } from "./store";
import { TransportError, type ChangeEvent, type SettingsTransport } from "./transport";

const KEY = "history.terminalCommands";

/** An owner in memory, standing in for any future one; `hold` delays each write's answer. */
function memoryOwner() {
  const values = new Map<string, unknown>();
  let changed: ((event: ChangeEvent) => void) | null = null;
  const pending: Array<() => void> = [];
  const owner = {
    reads: 0,
    hold: false,
    refuse: null as string | null,
    values,
    emit(keys: string[]) {
      changed?.({ keys, origin: "cli" });
    },
    release() {
      for (const resolve of pending.splice(0)) resolve();
    },
    transport: {
      async get() {
        owner.reads += 1;
        const rows: ListRow[] = schema.rows.map((row) => ({
          key: row.key,
          value: values.has(row.key) ? values.get(row.key) : row.default,
          default: row.default,
          customized: values.has(row.key),
          managed: null,
        }));
        return {
          rows,
          snapshot: { revision: owner.reads, schema_hash: "", effective: {}, managed: {}, diagnostics: [] },
        };
      },
      async set(key: string, value: unknown) {
        if (owner.hold) await new Promise<void>((resolve) => pending.push(resolve));
        if (owner.refuse) throw new TransportError({ code: owner.refuse, message: "refused" });
        values.set(key, value);
      },
      async reset(key: string) {
        if (key === "all") values.clear();
        else values.delete(key);
      },
      async subscribe(listener: { changed(event: ChangeEvent): void }) {
        changed = listener.changed;
        return () => {
          changed = null;
        };
      },
    } satisfies SettingsTransport,
  };
  return owner;
}

/** A page client for the host's own ops (lists, accounts); this test needs none of them. */
const noHost: SettingsClient = {
  call: () => Promise.reject({ code: "cmux.protocol.unknown_op", message: "none" }),
  subscribe: () => Promise.reject(new Error("none")),
};

const value = (store: SettingsStore) => store.getSnapshot().rows.get(KEY)?.value;

test("a write shows at once and stays after the owner confirms it", async () => {
  const owner = memoryOwner();
  const store = new SettingsStore(noHost, { transport: owner.transport });
  await store.start();
  owner.hold = true;
  const write = store.set(KEY, true);
  await Promise.resolve();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(value(store)).toBe(true);
  expect(store.getSnapshot().rows.get(KEY)?.customized).toBe(true);
  owner.release();
  expect(await write).toEqual({ ok: true });
  expect(value(store)).toBe(true);
  store.dispose();
});

test("a refused write rolls back to the last read and marks the row", async () => {
  const owner = memoryOwner();
  const store = new SettingsStore(noHost, { transport: owner.transport });
  await store.start();
  owner.refuse = "cmux.settings.invalid";
  const result = await store.set(KEY, true);
  expect(result.ok).toBe(false);
  expect(value(store)).toBe(false);
  expect(store.getSnapshot().errors.get(KEY)?.code).toBe("invalid");
  store.dispose();
});

test("the owner's change event invalidates the scope; the cache holds the only copy", async () => {
  const owner = memoryOwner();
  const store = new SettingsStore(noHost, { transport: owner.transport });
  await store.start();
  owner.values.set(KEY, true);
  owner.emit([KEY]);
  await new Promise((resolve) => setTimeout(resolve, 0));
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(value(store)).toBe(true);
  const cached = store.queryClient.getQueryData<{ rows: Map<string, ListRow> }>(settingsKeys.scope("user"));
  expect(cached?.rows.get(KEY)?.value).toBe(true);
  store.dispose();
});
