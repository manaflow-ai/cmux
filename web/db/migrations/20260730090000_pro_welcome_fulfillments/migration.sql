CREATE TABLE "pro_welcome_fulfillments" (
  "checkout_session_id" text PRIMARY KEY NOT NULL,
  "stack_user_id" text NOT NULL,
  "sent_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "pro_welcome_fulfillments_stack_user_idx"
  ON "pro_welcome_fulfillments" ("stack_user_id");
