-- Serialize provider-side WireGuard enrollment per account and device.
--
-- Freestyle creates and rotates tunnels outside Postgres. The deterministic
-- slug prevents duplicate provider objects, while this lease prevents two
-- Vercel instances from changing one object's key and then writing conflicting
-- control-plane rows. Expiry is the crash-recovery boundary.

CREATE TABLE IF NOT EXISTS "cloud_vm_tunnel_enrollment_locks" (
  "user_id" text NOT NULL,
  "device_fingerprint" text NOT NULL,
  "owner_token" text NOT NULL,
  "expires_at" timestamp with time zone NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_tunnel_enrollment_locks_pkey"
    PRIMARY KEY ("user_id", "device_fingerprint")
);

CREATE INDEX IF NOT EXISTS "cloud_vm_tunnel_enrollment_locks_expiry_idx"
  ON "cloud_vm_tunnel_enrollment_locks" ("expires_at");
