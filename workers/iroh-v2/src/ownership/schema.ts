import { bigint, index, pgTable, text, varchar } from "drizzle-orm/pg-core";

/** Endpoint ownership has one authoritative home in the fresh shared database. */
export const endpointOwners = pgTable("iroh_v2_endpoint_owners", {
  endpointId: varchar("endpoint_id", { length: 64 }).primaryKey(),
  identityHash: varchar("identity_hash", { length: 64 }).notNull(),
  environment: varchar("environment", { length: 128 }).notNull(),
  projectId: varchar("project_id", { length: 128 }).notNull(),
  teamId: varchar("team_id", { length: 128 }).notNull(),
  userId: varchar("user_id", { length: 128 }).notNull(),
  identityJson: text("identity_json").notNull(),
  createdAt: bigint("created_at", { mode: "number" }).notNull(),
}, table => [index("iroh_v2_endpoint_owners_user").on(table.environment, table.projectId, table.userId)]);

export const ownerBudgets = pgTable("iroh_v2_owner_budgets", {
  userScopeHash: varchar("user_scope_hash", { length: 64 }).primaryKey(),
  ownerCount: bigint("owner_count", { mode: "number" }).notNull().default(0),
});
