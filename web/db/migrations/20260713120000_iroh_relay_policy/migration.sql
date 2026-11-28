CREATE TABLE "iroh_relay_catalog_state" (
	"id" text PRIMARY KEY NOT NULL,
	"catalog_sequence" bigint NOT NULL,
	"catalog_digest" text NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "iroh_relay_catalog_state_singleton" CHECK ("id" = 'managed'),
	CONSTRAINT "iroh_relay_catalog_sequence_positive" CHECK ("catalog_sequence" > 0)
);
--> statement-breakpoint
CREATE TABLE "iroh_relay_preferences" (
	"account_id" text PRIMARY KEY NOT NULL,
	"mode" text DEFAULT 'automatic' NOT NULL,
	"selected_managed_relay_ids" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"custom_relays" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"revision" bigint DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "iroh_relay_preferences_mode" CHECK ("mode" IN ('automatic', 'managed', 'custom')),
	CONSTRAINT "iroh_relay_preferences_selected_array" CHECK (jsonb_typeof("selected_managed_relay_ids") = 'array'),
	CONSTRAINT "iroh_relay_preferences_custom_array" CHECK (jsonb_typeof("custom_relays") = 'array'),
	CONSTRAINT "iroh_relay_preferences_revision_nonnegative" CHECK ("revision" >= 0)
);
