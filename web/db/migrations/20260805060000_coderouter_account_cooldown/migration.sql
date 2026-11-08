ALTER TABLE "coderouter_accounts" ADD COLUMN "cooldown_until" timestamp with time zone;
CREATE INDEX "coderouter_accounts_cooldown_idx"
  ON "coderouter_accounts" ("cooldown_until");
