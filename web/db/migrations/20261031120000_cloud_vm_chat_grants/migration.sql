-- Chat grants on team Cloud machines (Leo, 2026-10-31: "we can't simply block
-- always"). A row lets one teammate start app chats on one machine: the
-- attach endpoint answers `vmKind: owner` to a granted caller who is still on
-- the machine's team (services/vms/vmKind.ts). Additive: only the new
-- /api/vm/[id]/chat-grants routes write it and only the attach endpoint reads
-- it, so app and web code from before this migration run unchanged, and a
-- failed read answers `team` as before. A grant goes with its machine.
-- Replay-safe: each object is created only when no relation of its name exists.
DO $$
BEGIN
	IF to_regclass('public.cloud_vm_chat_grants') IS NULL THEN
		CREATE TABLE "public"."cloud_vm_chat_grants" (
			"vm_id" uuid NOT NULL,
			"user_id" text NOT NULL,
			"granted_by" text NOT NULL,
			"created_at" timestamp with time zone DEFAULT now() NOT NULL,
			CONSTRAINT "cloud_vm_chat_grants_vm_id_cloud_vms_id_fkey" FOREIGN KEY ("vm_id") REFERENCES "public"."cloud_vms"("id") ON DELETE cascade ON UPDATE no action
		);
	END IF;
END $$;
--> statement-breakpoint
DO $$
BEGIN
	IF to_regclass('public.cloud_vm_chat_grants_vm_user_unique') IS NULL THEN
		CREATE UNIQUE INDEX "cloud_vm_chat_grants_vm_user_unique" ON "public"."cloud_vm_chat_grants" USING btree ("vm_id","user_id");
	END IF;
END $$;
