CREATE EXTENSION IF NOT EXISTS pg_trgm;--> statement-breakpoint
CREATE INDEX "vault_sessions_cwd_trgm_idx" ON "vault_sessions" USING gin ("cwd" gin_trgm_ops);--> statement-breakpoint
CREATE INDEX "vault_sessions_rel_path_trgm_idx" ON "vault_sessions" USING gin ("rel_path" gin_trgm_ops);
