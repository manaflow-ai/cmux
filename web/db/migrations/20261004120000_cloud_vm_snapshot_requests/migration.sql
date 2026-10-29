-- Idempotency ledger for POST /api/vm/:id/snapshot. Additive: no existing
-- reader or writer uses this table, so old app code runs unchanged.
CREATE TABLE IF NOT EXISTS "cloud_vm_snapshot_requests" (
	"vm_id" uuid NOT NULL,
	"idempotency_key" text NOT NULL,
	"name" text,
	"status" text NOT NULL,
	"provider_snapshot_id" text,
	"snapshot_name" text,
	"snapshot_created_at_ms" bigint,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "cloud_vm_snapshot_requests_vm_id_idempotency_key_pk" PRIMARY KEY ("vm_id", "idempotency_key"),
	CONSTRAINT "cloud_vm_snapshot_requests_vm_id_cloud_vms_id_fk" FOREIGN KEY ("vm_id") REFERENCES "cloud_vms" ("id") ON DELETE CASCADE,
	CONSTRAINT "cloud_vm_snapshot_requests_status" CHECK ("status" in ('pending', 'succeeded')),
	CONSTRAINT "cloud_vm_snapshot_requests_succeeded_has_snapshot" CHECK ("status" <> 'succeeded' or ("provider_snapshot_id" is not null and "snapshot_created_at_ms" is not null)),
	CONSTRAINT "cloud_vm_snapshot_requests_key_length" CHECK (length("idempotency_key") between 1 and 128)
);
