CREATE TABLE IF NOT EXISTS "hexclave_webhook_inbox" (
	"svix_id" text PRIMARY KEY NOT NULL,
	"event_type" text NOT NULL,
	"entity_kind" text NOT NULL,
	"entity_id" text NOT NULL,
	"revoke_candidate_team_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"payload" jsonb NOT NULL,
	"received_at" timestamp with time zone DEFAULT now() NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"next_attempt_at" timestamp with time zone DEFAULT now() NOT NULL,
	"claimed_until" timestamp with time zone,
	"last_error" text,
	CONSTRAINT "hexclave_webhook_inbox_entity_kind_check" CHECK ("entity_kind" in ('user', 'team'))
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "hexclave_webhook_inbox_due_idx" ON "hexclave_webhook_inbox" ("next_attempt_at");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "hexclave_webhook_inbox_entity_idx" ON "hexclave_webhook_inbox" ("entity_kind", "entity_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "hexclave_webhook_inbox_drain_slots" (
	"slot" integer PRIMARY KEY NOT NULL,
	"leased_until" timestamp with time zone NOT NULL
);
