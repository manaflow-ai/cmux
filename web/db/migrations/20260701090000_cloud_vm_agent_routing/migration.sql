CREATE TABLE IF NOT EXISTS "cloud_vm_agent_routing" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
  "user_id" text NOT NULL,
  "subrouter_url" text,
  "subrouter_tenant_key" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);--> statement-breakpoint

CREATE UNIQUE INDEX IF NOT EXISTS "cloud_vm_agent_routing_user_unique"
  ON "cloud_vm_agent_routing" ("user_id");
