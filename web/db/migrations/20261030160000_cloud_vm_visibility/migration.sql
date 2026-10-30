ALTER TABLE "cloud_vms" ADD COLUMN "visibility" text DEFAULT 'team' NOT NULL;
--> statement-breakpoint
UPDATE "cloud_vms" SET "visibility" = 'private' WHERE "owner_team_id" = '' OR "owner_team_id" = "user_id";
--> statement-breakpoint
ALTER TABLE "cloud_vms" ADD CONSTRAINT "cloud_vms_visibility_check" CHECK ("cloud_vms"."visibility" in ('private', 'team'));
