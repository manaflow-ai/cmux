CREATE TABLE IF NOT EXISTS "team_billing_owners" (
  "stack_team_id" text PRIMARY KEY,
  "billing_owner_user_id" text NOT NULL,
  "owner_source" text NOT NULL DEFAULT 'creator',
  "member_order" jsonb NOT NULL DEFAULT '[]'::jsonb,
  "seat_reservations" jsonb NOT NULL DEFAULT '{}'::jsonb,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE "team_billing_owners"
  ADD COLUMN IF NOT EXISTS "owner_source" text NOT NULL DEFAULT 'creator',
  ADD COLUMN IF NOT EXISTS "member_order" jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS "seat_reservations" jsonb NOT NULL DEFAULT '{}'::jsonb;
