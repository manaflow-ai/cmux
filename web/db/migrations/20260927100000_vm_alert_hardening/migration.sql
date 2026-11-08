CREATE TABLE "cloud_vm_alert_states" (
  "alert_key" text PRIMARY KEY NOT NULL,
  "active" boolean DEFAULT false NOT NULL,
  "severity" text DEFAULT 'warning' NOT NULL,
  "last_sent_at" timestamp with time zone,
  "delivery_lease_id" text,
  "delivery_lease_until" timestamp with time zone,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_alert_states_severity_check"
    CHECK ("severity" IN ('critical', 'warning'))
);
--> statement-breakpoint
CREATE INDEX "cloud_vm_leases_kind_expiry_idx"
  ON "cloud_vm_leases" ("kind", "expires_at", "id");
