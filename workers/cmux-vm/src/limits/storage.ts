import { Schema } from "effect";

/** Untyped durable values are decoded by their owning journal before use. */
export interface LedgerStorage {
  transaction<A>(run: (storage: LedgerStorage) => Promise<A>): Promise<A>;
  get(key: string): Promise<unknown>;
  put(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<boolean>;
  list(options: { readonly prefix: string; readonly startAfter?: string; readonly limit?: number }): Promise<Map<string, unknown>>;
  /** Many keys in one storage call (Durable Object `get(keys)`, at most {@link BATCH_KEYS}); absent keys are left out. Optional: fakes fall back to one `get` per key. */
  getMany?(keys: ReadonlyArray<string>): Promise<Map<string, unknown>>;
  /** Deletes many keys in one storage call (Durable Object `delete(keys)`, at most {@link BATCH_KEYS}); answers how many existed. */
  deleteMany?(keys: ReadonlyArray<string>): Promise<number>;
}

/** The most keys one Durable Object `get`/`delete` call takes. */
export const BATCH_KEYS = 128;

const chunks = (keys: ReadonlyArray<string>): ReadonlyArray<ReadonlyArray<string>> => {
  const out: string[][] = [];
  for (let i = 0; i < keys.length; i += BATCH_KEYS) out.push(keys.slice(i, i + BATCH_KEYS));
  return out;
};

/** Reads `keys` in batches of {@link BATCH_KEYS}: one storage call per batch instead of one per key. */
export const getMany = async (storage: LedgerStorage, keys: ReadonlyArray<string>): Promise<Map<string, unknown>> => {
  const found = new Map<string, unknown>();
  for (const batch of chunks(keys)) {
    if (storage.getMany !== undefined) for (const [key, value] of await storage.getMany(batch)) found.set(key, value);
    else for (const key of batch) { const value = await storage.get(key); if (value !== undefined) found.set(key, value); }
  }
  return found;
};

/** Deletes `keys` in batches of {@link BATCH_KEYS}. */
export const deleteMany = async (storage: LedgerStorage, keys: ReadonlyArray<string>): Promise<void> => {
  for (const batch of chunks(keys)) {
    if (storage.deleteMany !== undefined) await storage.deleteMany(batch);
    else for (const key of batch) await storage.delete(key);
  }
};

export const Reservation = Schema.Struct({ kind: Schema.String, expiresMs: Schema.Number, retained: Schema.optional(Schema.Boolean) });
