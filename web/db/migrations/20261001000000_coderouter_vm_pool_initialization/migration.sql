CREATE TABLE "coderouter_pool_initializations" (
  "pool_id" uuid PRIMARY KEY REFERENCES "coderouter_pools" ("id") ON DELETE CASCADE,
  "created_at" timestamptz NOT NULL DEFAULT now()
);

-- Pools created by the VM-scope migration already received their initial
-- account snapshot. Mark them initialized so the first token refresh after
-- this migration cannot recreate grants that an operator deliberately removed.
INSERT INTO "coderouter_pool_initializations" ("pool_id")
SELECT "id" FROM "coderouter_pools"
ON CONFLICT ("pool_id") DO NOTHING;
