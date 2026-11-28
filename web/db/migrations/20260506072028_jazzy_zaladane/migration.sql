CREATE TABLE "cloud_vm_billing_grants" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	"billing_customer_type" text NOT NULL,
	"billing_customer_id" text NOT NULL,
	"billing_plan_id" text NOT NULL,
	"item_id" text NOT NULL,
	"amount" integer NOT NULL,
	"reason" text NOT NULL,
	"applied_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "cloud_vm_billing_grants_customer_created_idx" ON "cloud_vm_billing_grants" ("billing_customer_type","billing_customer_id","created_at");--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vm_billing_grants_customer_item_reason_unique" ON "cloud_vm_billing_grants" ("billing_customer_type","billing_customer_id","item_id","reason");