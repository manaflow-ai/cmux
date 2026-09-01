CREATE TABLE "billing_dunning_deliveries" (
  "invoice_id" text PRIMARY KEY NOT NULL,
  "email" text NOT NULL,
  "scope" text NOT NULL,
  "stack_user_id" text,
  "stack_team_id" text,
  "delivery_started_at" timestamp with time zone,
  "attempt_lease_expires_at" timestamp with time zone,
  "sent_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "billing_dunning_deliveries_stack_user_idx"
  ON "billing_dunning_deliveries" ("stack_user_id");
--> statement-breakpoint
CREATE INDEX "billing_dunning_deliveries_stack_team_idx"
  ON "billing_dunning_deliveries" ("stack_team_id");
