CREATE TABLE "account_mutation_fences" (
	"lock_key" text PRIMARY KEY NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
