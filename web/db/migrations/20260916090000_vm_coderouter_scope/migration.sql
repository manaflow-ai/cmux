-- This atomic cutover is deliberately limited to small catalogs. Refuse it on
-- larger installations; those need an online index/backfill migration plan.
-- Drizzle owns the transaction, so timeout errors roll back the whole cutover.
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '15s';
DO $$
DECLARE target text; row_count bigint;
BEGIN
  FOREACH target IN ARRAY ARRAY['cloud_vms', 'coderouter_accounts', 'coderouter_claude_accounts'] LOOP
    IF pg_total_relation_size(target::regclass) > 33554432 THEN
      RAISE EXCEPTION 'VM scope migration requires online phases: % exceeds 32 MiB', target;
    END IF;
    EXECUTE format('SELECT count(*) FROM (SELECT 1 FROM %I LIMIT 10001) bounded', target) INTO row_count;
    IF row_count > 10000 THEN
      RAISE EXCEPTION 'VM scope migration requires online phases: % exceeds 10000 rows', target;
    END IF;
    RAISE NOTICE 'VM scope migration: % has % rows', target, row_count;
  END LOOP;
END $$;

CREATE TABLE "coderouter_pools" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "team_id" text NOT NULL,
  "name" text NOT NULL,
  "is_default" boolean NOT NULL DEFAULT false,
  "created_at" timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX "coderouter_pools_team_id_unique" ON "coderouter_pools" ("team_id", "id");
CREATE UNIQUE INDEX "coderouter_pools_default_unique" ON "coderouter_pools" ("team_id") WHERE "is_default";

ALTER TABLE "coderouter_accounts" ADD COLUMN "visibility" text NOT NULL DEFAULT 'team', ADD COLUMN "created_by" text;
ALTER TABLE "coderouter_claude_accounts" ADD COLUMN "visibility" text NOT NULL DEFAULT 'team';
-- Keep the shared default for old servers during a rolling deployment. New
-- account creation explicitly supplies private visibility and its importing user.
ALTER TABLE "coderouter_accounts" ADD CONSTRAINT "coderouter_accounts_visibility_check" CHECK ("visibility" IN ('private', 'team'));
ALTER TABLE "coderouter_claude_accounts" ADD CONSTRAINT "coderouter_claude_accounts_visibility_check" CHECK ("visibility" IN ('private', 'team'));
CREATE UNIQUE INDEX "coderouter_accounts_team_id_unique" ON "coderouter_accounts" ("team_id", "id");
CREATE UNIQUE INDEX "coderouter_claude_accounts_team_id_unique" ON "coderouter_claude_accounts" ("team_id", "id");

CREATE TABLE "coderouter_pool_accounts" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "team_id" text NOT NULL,
  "pool_id" uuid NOT NULL,
  "account_id" uuid,
  "claude_account_id" uuid,
  "granted_by_user_id" text,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "coderouter_pool_accounts_one_account" CHECK (num_nonnulls("account_id", "claude_account_id") = 1),
  CONSTRAINT "coderouter_pool_accounts_pool_team_fk" FOREIGN KEY ("team_id", "pool_id") REFERENCES "coderouter_pools" ("team_id", "id") ON DELETE CASCADE,
  CONSTRAINT "coderouter_pool_accounts_native_team_fk" FOREIGN KEY ("team_id", "account_id") REFERENCES "coderouter_accounts" ("team_id", "id") ON DELETE CASCADE,
  CONSTRAINT "coderouter_pool_accounts_claude_team_fk" FOREIGN KEY ("team_id", "claude_account_id") REFERENCES "coderouter_claude_accounts" ("team_id", "id") ON DELETE CASCADE
);
CREATE UNIQUE INDEX "coderouter_pool_accounts_native_unique" ON "coderouter_pool_accounts" ("pool_id", "account_id");
CREATE UNIQUE INDEX "coderouter_pool_accounts_claude_unique" ON "coderouter_pool_accounts" ("pool_id", "claude_account_id");

CREATE FUNCTION coderouter_default_pool(scope_team text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE pool uuid;
BEGIN
  INSERT INTO coderouter_pools (team_id, name, is_default) VALUES (scope_team, 'Default', true)
    ON CONFLICT (team_id) WHERE is_default DO NOTHING;
  SELECT id INTO STRICT pool FROM coderouter_pools WHERE team_id = scope_team AND is_default;
  RETURN pool;
END $$;

ALTER TABLE "cloud_vms" ADD COLUMN "owner_team_id" text NOT NULL DEFAULT '', ADD COLUMN "coderouter_pool_id" uuid;
UPDATE "cloud_vms" SET "owner_team_id" = coalesce(nullif("billing_team_id", ''), "user_id");
UPDATE "cloud_vms" SET "coderouter_pool_id" = coderouter_default_pool("owner_team_id");
ALTER TABLE "cloud_vms" ADD CONSTRAINT "cloud_vms_coderouter_pool_team_fk" FOREIGN KEY ("owner_team_id", "coderouter_pool_id") REFERENCES "coderouter_pools" ("team_id", "id");
CREATE INDEX "cloud_vms_owner_team_status_idx" ON "cloud_vms" ("owner_team_id", "status");

CREATE FUNCTION cloud_vm_assign_owner() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NEW.owner_team_id IS DISTINCT FROM OLD.owner_team_id THEN
      RAISE EXCEPTION 'Cloud VM owner team is immutable' USING ERRCODE = '23514';
    END IF;
  ELSE
    NEW.owner_team_id := coalesce(nullif(NEW.owner_team_id, ''), nullif(NEW.billing_team_id, ''), NEW.user_id);
    NEW.coderouter_pool_id := coalesce(NEW.coderouter_pool_id, coderouter_default_pool(NEW.owner_team_id));
  END IF;
  IF NEW.owner_team_id = '' OR NEW.coderouter_pool_id IS NULL THEN
    RAISE EXCEPTION 'Cloud VM requires an owner team and model pool' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cloud_vm_assign_owner BEFORE INSERT OR UPDATE ON cloud_vms FOR EACH ROW EXECUTE FUNCTION cloud_vm_assign_owner();

-- Keep the default pool synchronized with intentional team sharing. A private
-- account is available to a VM only in the user's personal scope (team_id=user_id).
CREATE FUNCTION coderouter_sync_default_pool() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pool uuid;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF TG_TABLE_NAME = 'coderouter_accounts' THEN
      DELETE FROM coderouter_pool_accounts WHERE account_id = OLD.id;
    ELSE
      DELETE FROM coderouter_pool_accounts WHERE claude_account_id = OLD.id;
    END IF;
  END IF;
  IF NEW.visibility = 'team' OR NEW.team_id = NEW.created_by THEN
    pool := coderouter_default_pool(NEW.team_id);
    IF TG_TABLE_NAME = 'coderouter_accounts' THEN
      INSERT INTO coderouter_pool_accounts (team_id, pool_id, account_id, granted_by_user_id)
        VALUES (NEW.team_id, pool, NEW.id, NEW.created_by) ON CONFLICT DO NOTHING;
    ELSE
      INSERT INTO coderouter_pool_accounts (team_id, pool_id, claude_account_id, granted_by_user_id)
        VALUES (NEW.team_id, pool, NEW.id, NEW.created_by) ON CONFLICT DO NOTHING;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER coderouter_sync_default_pool AFTER INSERT OR UPDATE OF visibility, team_id, created_by ON coderouter_accounts FOR EACH ROW EXECUTE FUNCTION coderouter_sync_default_pool();
CREATE TRIGGER coderouter_sync_default_pool AFTER INSERT OR UPDATE OF visibility, team_id, created_by ON coderouter_claude_accounts FOR EACH ROW EXECUTE FUNCTION coderouter_sync_default_pool();
INSERT INTO coderouter_pool_accounts (team_id, pool_id, account_id)
  SELECT team_id, coderouter_default_pool(team_id), id FROM coderouter_accounts;
INSERT INTO coderouter_pool_accounts (team_id, pool_id, claude_account_id, granted_by_user_id)
  SELECT team_id, coderouter_default_pool(team_id), id, created_by FROM coderouter_claude_accounts;
