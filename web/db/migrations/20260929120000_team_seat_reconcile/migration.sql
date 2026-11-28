CREATE TABLE IF NOT EXISTS "team_seat_reconciles" (
	"stack_team_id" text PRIMARY KEY NOT NULL,
	"dirty_at" timestamp (3) with time zone,
	"last_reconciled_at" timestamp with time zone,
	"last_member_count" integer,
	"last_stripe_quantity" integer,
	"last_error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "team_seat_reconciles_dirty_idx" ON "team_seat_reconciles" ("dirty_at") WHERE "dirty_at" IS NOT NULL;
