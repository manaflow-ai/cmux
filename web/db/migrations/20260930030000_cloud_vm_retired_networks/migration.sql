-- An owner's earlier private networks. When a network has no free address
-- left, the owner moves to a successor network; the old one is kept here so
-- tunnels stay attached to it and account deletion can remove it. Additive:
-- existing code never reads this table.
CREATE TABLE IF NOT EXISTS "cloud_vm_retired_networks" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "provider" "vm_provider" NOT NULL,
  "provider_network_id" text NOT NULL,
  "slug" text,
  "cidr" text,
  "cidr_v6" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "retired_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_retired_networks_provider_network_id_unique"
  ON "cloud_vm_retired_networks" ("provider", "provider_network_id");
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "cloud_vm_retired_networks_user_provider_idx"
  ON "cloud_vm_retired_networks" ("user_id", "provider");
