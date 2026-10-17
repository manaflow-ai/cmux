ALTER TABLE "run_attempts"
  ADD COLUMN "attach_ticket_hash" text,
  ADD COLUMN "attach_ticket_expires_at" timestamp with time zone,
  ADD COLUMN "attach_ticket_consumed_at" timestamp with time zone;

CREATE INDEX "run_attempts_attach_ticket_idx"
  ON "run_attempts" ("attach_ticket_hash", "attach_ticket_expires_at")
  WHERE "attach_ticket_hash" is not null;
