-- Shared team VPC bookkeeping. Team members share a team VPC, while the
-- tables remain additive so already-deployed code keeps using personal VPCs.
CREATE TABLE IF NOT EXISTS "cloud_vm_team_networks" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "team_id" text NOT NULL,
  "provider" "vm_provider" NOT NULL,
  "provider_network_id" text NOT NULL,
  "slug" text,
  "cidr" text,
  "cidr_v6" text,
  "created_by_user_id" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_team_networks_team_provider_unique"
  ON "cloud_vm_team_networks" ("team_id", "provider");
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_team_networks_provider_network_id_unique"
  ON "cloud_vm_team_networks" ("provider", "provider_network_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "cloud_vm_tunnel_team_networks" (
  "tunnel_id" uuid NOT NULL,
  "team_network_id" uuid NOT NULL,
  "address_v4" text,
  "address_v6" text,
  "attached_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "cloud_vm_tunnel_team_networks_tunnel_id_cloud_vm_tunnels_id_fk"
    FOREIGN KEY ("tunnel_id") REFERENCES "cloud_vm_tunnels"("id") ON DELETE cascade,
  CONSTRAINT "cloud_vm_tunnel_team_networks_team_network_id_cloud_vm_team_networks_id_fk"
    FOREIGN KEY ("team_network_id") REFERENCES "cloud_vm_team_networks"("id") ON DELETE cascade,
  CONSTRAINT "cloud_vm_tunnel_team_networks_pkey" PRIMARY KEY ("tunnel_id", "team_network_id")
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_tunnel_team_networks_team_network_idx"
  ON "cloud_vm_tunnel_team_networks" ("team_network_id");
