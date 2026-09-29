CREATE TABLE IF NOT EXISTS "team_billing_owners" (
  "stack_team_id" text PRIMARY KEY,
  "billing_owner_user_id" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
