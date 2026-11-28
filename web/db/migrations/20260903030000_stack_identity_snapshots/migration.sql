CREATE TABLE "stack_identity_snapshots" (
  "user_id" text PRIMARY KEY NOT NULL,
  "display_name" text,
  "primary_email" text,
  "selected_team_id" text,
  "billing_customer_type" text NOT NULL,
  "billing_team_id" text NOT NULL,
  "user_billing_plan_id" text,
  "billing_plan_id" text,
  "billing_seats" integer,
  "teams" jsonb DEFAULT '[]'::jsonb NOT NULL,
  "refreshed_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "stack_identity_snapshots_refreshed_idx" ON "stack_identity_snapshots" ("refreshed_at");
