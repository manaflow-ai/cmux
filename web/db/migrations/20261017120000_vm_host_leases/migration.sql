CREATE TABLE "cloud_vm_host_leases" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "provider" text NOT NULL,
  "host_id" text NOT NULL,
  "lease_id" text NOT NULL,
  "owner_id" text NOT NULL,
  "generation" integer NOT NULL,
  "state" text DEFAULT 'active' NOT NULL,
  "provider_lease_id" text,
  "expires_at" timestamp with time zone NOT NULL,
  "metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_host_leases_provider_check" CHECK ("provider" ~ '^[a-z][a-z0-9-]{1,63}$'),
  CONSTRAINT "cloud_vm_host_leases_state_check" CHECK ("state" in ('active', 'released')),
  CONSTRAINT "cloud_vm_host_leases_generation_check" CHECK ("generation" > 0)
);
--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vm_host_leases_host_lease_unique" ON "cloud_vm_host_leases" ("host_id", "lease_id");
--> statement-breakpoint
CREATE INDEX "cloud_vm_host_leases_expiry_idx" ON "cloud_vm_host_leases" ("expires_at");
--> statement-breakpoint
CREATE TABLE "cloud_vm_host_lease_operations" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "provider" text NOT NULL,
  "host_id" text NOT NULL,
  "lease_id" text NOT NULL,
  "owner_id" text NOT NULL,
  "effect_key" text NOT NULL,
  "operation" text NOT NULL,
  "generation" integer NOT NULL,
  "status" text DEFAULT 'pending' NOT NULL,
  "receipt" jsonb,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_host_lease_operations_provider_check" CHECK ("provider" ~ '^[a-z][a-z0-9-]{1,63}$'),
  CONSTRAINT "cloud_vm_host_lease_operations_operation_check" CHECK ("operation" in ('acquire', 'renew', 'release')),
  CONSTRAINT "cloud_vm_host_lease_operations_status_check" CHECK ("status" in ('pending', 'complete')),
  CONSTRAINT "cloud_vm_host_lease_operations_generation_check" CHECK ("generation" > 0)
);
--> statement-breakpoint
CREATE UNIQUE INDEX "cloud_vm_host_lease_operations_effect_unique" ON "cloud_vm_host_lease_operations" ("host_id", "lease_id", "effect_key");
--> statement-breakpoint
CREATE INDEX "cloud_vm_host_lease_operations_pending_idx" ON "cloud_vm_host_lease_operations" ("status", "updated_at");
