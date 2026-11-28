ALTER TABLE "stripe_customers" ADD COLUMN "stack_team_id" text;--> statement-breakpoint
ALTER TABLE "stripe_subscriptions" ADD COLUMN "stack_team_id" text;--> statement-breakpoint
ALTER TABLE "stripe_subscriptions" ADD COLUMN "seats" integer;--> statement-breakpoint
ALTER TABLE "stripe_subscriptions" ADD COLUMN "scope" text DEFAULT 'user' NOT NULL;--> statement-breakpoint
DROP INDEX "stripe_customers_stack_user_id_unique";--> statement-breakpoint
CREATE UNIQUE INDEX "stripe_customers_stack_user_id_unique" ON "stripe_customers" ("stack_user_id") WHERE "stack_team_id" is null;--> statement-breakpoint
CREATE UNIQUE INDEX "stripe_customers_stack_team_id_unique" ON "stripe_customers" ("stack_team_id") WHERE "stack_team_id" is not null;--> statement-breakpoint
CREATE INDEX "stripe_subscriptions_stack_team_id_idx" ON "stripe_subscriptions" ("stack_team_id");