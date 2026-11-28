-- Per-user private networks and the WireGuard tunnels that reach into them.
--
-- A Cloud VM used to be reachable only at its public IPv6 with the cmux-tui
-- daemon port open to the Internet. It now joins the one private network that
-- belongs to its owner, and the owner's Mac joins the same network over a
-- WireGuard tunnel, so the daemon port needs no public exposure at all.
--
-- Both tables are control-plane bookkeeping over provider-side resources: the
-- network and tunnel themselves live at the provider, keyed by the ids stored
-- here. No secret is stored — the tunnel's private key is generated on, and
-- never leaves, the user's Mac.

CREATE TABLE IF NOT EXISTS "cloud_vm_networks" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "provider" "vm_provider" NOT NULL,
  "provider_network_id" text NOT NULL,
  "slug" text,
  "cidr" text,
  "cidr_v6" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

-- One network per owner per provider: create races resolve by reading back the
-- winner's row rather than provisioning a second network nobody is on.
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_networks_user_provider_unique"
  ON "cloud_vm_networks" ("user_id", "provider");
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_networks_provider_network_id_unique"
  ON "cloud_vm_networks" ("provider", "provider_network_id");

CREATE TABLE IF NOT EXISTS "cloud_vm_tunnels" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "network_id" uuid NOT NULL,
  "provider" "vm_provider" NOT NULL,
  "provider_tunnel_id" text NOT NULL,
  "device_fingerprint" text NOT NULL,
  "device_name" text,
  "client_public_key" text NOT NULL,
  "address_v4" text,
  "address_v6" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "last_config_issued_at" timestamp with time zone,
  "revoked_at" timestamp with time zone,
  CONSTRAINT "cloud_vm_tunnels_network_id_cloud_vm_networks_id_fk"
    FOREIGN KEY ("network_id") REFERENCES "cloud_vm_networks"("id") ON DELETE cascade
);

-- A device holds at most one live tunnel; revoked rows stay for audit, so the
-- uniqueness is partial rather than absolute.
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_tunnels_user_device_unique"
  ON "cloud_vm_tunnels" ("user_id", "device_fingerprint")
  WHERE "revoked_at" IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_tunnels_provider_tunnel_id_unique"
  ON "cloud_vm_tunnels" ("provider", "provider_tunnel_id");
CREATE INDEX IF NOT EXISTS "cloud_vm_tunnels_network_idx"
  ON "cloud_vm_tunnels" ("network_id");
