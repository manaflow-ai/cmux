import { drizzle, type DrizzleSqliteDODatabase } from "drizzle-orm/durable-sqlite";
import { accountDrizzleSchema } from "./accountDrizzleSchema";

export type AccountDrizzleDatabase = DrizzleSqliteDODatabase<typeof accountDrizzleSchema>;

/** Construct the typed database once per object. Drizzle uses the Durable
 * Object's native synchronous transaction API, never SQL BEGIN/COMMIT. */
export function accountDrizzleDatabase(storage: DurableObjectStorage): AccountDrizzleDatabase {
  return drizzle(storage, { schema: accountDrizzleSchema, logger: false });
}
