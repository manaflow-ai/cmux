CREATE TABLE "admin_members" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "email" text NOT NULL,
  "invited_by_user_id" text NOT NULL,
  "invited_by_email" text,
  "invited_at" timestamp with time zone DEFAULT now() NOT NULL,
  "accepted_at" timestamp with time zone,
  "revoked_at" timestamp with time zone,
  "last_seen_at" timestamp with time zone
);
--> statement-breakpoint
CREATE UNIQUE INDEX "admin_members_email_unique" ON "admin_members" ("email");
