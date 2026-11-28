import { index, integer, primaryKey, sqliteTable, text } from "drizzle-orm/sqlite-core";

export const socketReservations = sqliteTable("socket_reservations", {
  scopeKey: text("scope_key").notNull(), userId: text("user_id").notNull(), teamId: text("team_id").notNull(),
  sessionId: text("session_id").notNull(), deviceKey: text("device_key").notNull(),
  outputBytes: integer("output_bytes").notNull().default(0), outputMessages: integer("output_messages").notNull().default(0),
  outputRevision: integer("output_revision").notNull().default(0),
}, table => ({
  pk: primaryKey({ columns: [table.scopeKey, table.userId, table.sessionId] }),
  userIndex: index("socket_reservations_user_idx").on(table.scopeKey, table.userId),
}));

export const SOCKET_MIGRATION_STATEMENTS = [
  `CREATE TABLE "socket_reservations" ("scope_key" TEXT NOT NULL, "user_id" TEXT NOT NULL, "team_id" TEXT NOT NULL, "session_id" TEXT NOT NULL, "device_key" TEXT NOT NULL, "output_bytes" INTEGER NOT NULL DEFAULT 0 CHECK ("output_bytes" BETWEEN 0 AND 2097152), "output_messages" INTEGER NOT NULL DEFAULT 0 CHECK ("output_messages" BETWEEN 0 AND 1024), "output_revision" INTEGER NOT NULL DEFAULT 0 CHECK ("output_revision" >= 0), PRIMARY KEY ("scope_key", "user_id", "session_id"), CHECK (length(CAST("scope_key" AS BLOB)) <= 2048), CHECK (length(CAST("user_id" AS BLOB)) BETWEEN 1 AND 512), CHECK (length(CAST("team_id" AS BLOB)) BETWEEN 1 AND 512), CHECK (length(CAST("session_id" AS BLOB)) BETWEEN 1 AND 128), CHECK (length(CAST("device_key" AS BLOB)) = 64))`,
  `CREATE INDEX "socket_reservations_user_idx" ON "socket_reservations" ("scope_key", "user_id")`,
  `CREATE TRIGGER "socket_reservations_insert_guard" BEFORE INSERT ON "socket_reservations" WHEN NOT EXISTS (SELECT 1 FROM "socket_reservations" WHERE "scope_key" = NEW."scope_key" AND "user_id" = NEW."user_id" AND "session_id" = NEW."session_id") AND ((SELECT count(*) FROM "socket_reservations" WHERE "scope_key" = NEW."scope_key" AND "user_id" = NEW."user_id") >= 501 OR ((SELECT count(*) FROM "socket_reservations" WHERE "scope_key" = NEW."scope_key" AND "user_id" = NEW."user_id") >= 500 AND NOT EXISTS (SELECT 1 FROM "socket_reservations" WHERE "scope_key" = NEW."scope_key" AND "user_id" = NEW."user_id" AND "device_key" = NEW."device_key"))) BEGIN SELECT RAISE(ABORT, 'socket_capacity'); END`,
  `CREATE TRIGGER "socket_reservations_output_guard" BEFORE UPDATE OF "output_bytes", "output_messages" ON "socket_reservations" WHEN (SELECT coalesce(sum("output_bytes"), 0) FROM "socket_reservations" WHERE "scope_key" = NEW."scope_key" AND "user_id" = NEW."user_id") - OLD."output_bytes" + NEW."output_bytes" > 8388608 OR (SELECT coalesce(sum("output_messages"), 0) FROM "socket_reservations" WHERE "scope_key" = NEW."scope_key" AND "user_id" = NEW."user_id") - OLD."output_messages" + NEW."output_messages" > 4096 BEGIN SELECT RAISE(ABORT, 'socket_output_capacity'); END`,
  `UPDATE "team_meta" SET "schema_version" = 4 WHERE "id" = 1`,
];
