-- Contract after the principal-aware application is live. Unscoped tokens are
-- intentionally not transferable to a guessed user.
DELETE FROM "coderouter_route_tokens"
WHERE "stack_user_id" IS NULL;

ALTER TABLE "coderouter_route_tokens"
  ADD CONSTRAINT "coderouter_route_tokens_stack_user_id_not_null"
  CHECK ("stack_user_id" IS NOT NULL) NOT VALID;

ALTER TABLE "coderouter_route_tokens"
  VALIDATE CONSTRAINT "coderouter_route_tokens_stack_user_id_not_null";

ALTER TABLE "coderouter_route_tokens"
  ALTER COLUMN "stack_user_id" SET NOT NULL;

ALTER TABLE "coderouter_route_tokens"
  DROP CONSTRAINT "coderouter_route_tokens_stack_user_id_not_null";
