ALTER TABLE "vault_cli_auth_requests"
  DROP CONSTRAINT IF EXISTS "vault_cli_auth_requests_client_check";
--> statement-breakpoint
ALTER TABLE "vault_cli_auth_requests"
  ADD CONSTRAINT "vault_cli_auth_requests_client_check"
  CHECK ("client" IN ('cmux-vault', 'subrouter', 'cmux-sprites'));
