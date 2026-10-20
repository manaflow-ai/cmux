CREATE TABLE "subrouter_tenants" (
	"team_id" text PRIMARY KEY,
	"tenant_id" text NOT NULL,
	"tenant_name" text NOT NULL,
	"encrypted_tenant_key" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "subrouter_tenants_tenant_id_unique" ON "subrouter_tenants" ("tenant_id");