CREATE TABLE IF NOT EXISTS "cloud_vm_credit_reservations" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"vm_id" uuid NOT NULL,
	"billing_customer_type" text NOT NULL,
	"billing_customer_id" text NOT NULL,
	"item_id" text NOT NULL,
	"amount" integer NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_credit_reservations_vm_unique" ON "cloud_vm_credit_reservations" ("vm_id");
CREATE INDEX IF NOT EXISTS "cloud_vm_credit_reservations_status_updated_idx" ON "cloud_vm_credit_reservations" ("status","updated_at");
