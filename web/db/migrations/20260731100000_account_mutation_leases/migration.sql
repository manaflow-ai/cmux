CREATE TABLE "account_mutation_leases" (
  "user_id_hash" text PRIMARY KEY NOT NULL,
  "operation_id" uuid NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "expires_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE INDEX "account_mutation_leases_expiry_idx"
  ON "account_mutation_leases" ("expires_at");
--> statement-breakpoint
CREATE INDEX "account_mutation_leases_operation_idx"
  ON "account_mutation_leases" ("operation_id");
