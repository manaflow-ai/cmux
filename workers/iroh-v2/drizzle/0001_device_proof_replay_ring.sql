-- Bounded replay protection for authenticated device proofs.
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "device_proof_replays" (
  "identity_key" TEXT NOT NULL,
  "request_id" TEXT NOT NULL,
  "issued_at" INTEGER NOT NULL,
  "expires_at" INTEGER NOT NULL,
  PRIMARY KEY ("identity_key", "request_id")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "device_proof_replays_expiry_idx" ON "device_proof_replays" ("identity_key", "expires_at");
