-- The later Plus charge for $1 pass buyers who chose to continue on Plus (RFD 0052): one attempt per
-- pass, claimed under the pass lock before the charge and recorded on the row.
ALTER TABLE "cloud_intro_passes" ADD COLUMN IF NOT EXISTS "renewal_status" text;
--> statement-breakpoint
ALTER TABLE "cloud_intro_passes" ADD COLUMN IF NOT EXISTS "renewal_subscription_id" text;
--> statement-breakpoint
ALTER TABLE "cloud_intro_passes" ADD COLUMN IF NOT EXISTS "renewal_error_code" text;
--> statement-breakpoint
ALTER TABLE "cloud_intro_passes" ADD COLUMN IF NOT EXISTS "renewal_attempted_at" timestamp with time zone;
--> statement-breakpoint
ALTER TABLE "cloud_intro_passes" ADD COLUMN IF NOT EXISTS "renew_turned_off_at" timestamp with time zone;
