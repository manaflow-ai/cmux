CREATE TABLE "admin_plan_grants" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "email" text NOT NULL,
  "plan" text NOT NULL,
  "granted_by_user_id" text NOT NULL,
  "granted_by_email" text,
  "claimed_at" timestamp with time zone,
  "applied_user_id" text,
  "applied_at" timestamp with time zone,
  "revoked_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "admin_plan_grants_email_idx" ON "admin_plan_grants" ("email");
--> statement-breakpoint
CREATE UNIQUE INDEX "admin_plan_grants_open_email_unique" ON "admin_plan_grants" ("email")
  WHERE "applied_at" IS NULL AND "revoked_at" IS NULL;
