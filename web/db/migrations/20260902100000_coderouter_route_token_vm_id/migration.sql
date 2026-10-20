-- Bind a coderouter route token to one Cloud VM. The Freestyle edge injects
-- the token into that VM's sessions together with x-cmux-vm-id; coderouter
-- rejects a bound token whose request names a different VM. Null keeps the
-- existing unbound (cr CLI) semantics.
ALTER TABLE "coderouter_route_tokens" ADD COLUMN "vm_id" text;--> statement-breakpoint
CREATE INDEX "coderouter_route_tokens_vm_idx"
  ON "coderouter_route_tokens" ("vm_id");
