import { Schema } from "effect";

/** Untyped durable values are decoded by their owning journal before use. */
export interface LedgerStorage {
  transaction<A>(run: (storage: LedgerStorage) => Promise<A>): Promise<A>;
  get(key: string): Promise<unknown>;
  put(key: string, value: unknown): Promise<void>;
  delete(key: string): Promise<boolean>;
  list(options: { readonly prefix: string; readonly startAfter?: string; readonly limit?: number }): Promise<Map<string, unknown>>;
}

export const Reservation = Schema.Struct({ kind: Schema.String, expiresMs: Schema.Number, retained: Schema.optional(Schema.Boolean) });
