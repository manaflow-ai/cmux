CREATE TABLE "billing_email_verification_deliveries" (
  "checkout_session_id" text PRIMARY KEY NOT NULL,
  "stack_user_id" text NOT NULL,
  "email" text NOT NULL,
  "delivery_started_at" timestamp with time zone,
  "attempt_lease_expires_at" timestamp with time zone,
  "sent_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "billing_email_verification_deliveries_stack_user_idx"
  ON "billing_email_verification_deliveries" ("stack_user_id");
