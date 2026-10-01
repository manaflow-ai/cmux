CREATE TABLE "coderouter_pool_initializations" (
  "pool_id" uuid PRIMARY KEY REFERENCES "coderouter_pools" ("id") ON DELETE CASCADE,
  "created_at" timestamptz NOT NULL DEFAULT now()
);
INSERT INTO "coderouter_pool_initializations" ("pool_id") SELECT "id" FROM "coderouter_pools";
