-- iOS Pro free trial (services/billing/apple/trial.ts).
--
-- 1. apple_subscriptions records the current transaction's offer. A free
--    trial of the trial product is stored with plan_id 'go' (the limited
--    trial entitlement) when the owner has a verified trial claim, else
--    'trial_unverified', which grants nothing. A verified claim moves to
--    'trial_pending' (grants nothing) until the server has checked and set
--    the device's DeviceCheck bit; then 'go'. Existing rows default to
--    free_trial = false, so their plan is unchanged.
-- 2. Challenges, App Attest keys and per-account trial claims.
-- 3. The Go capacity guard gives a trial one saved VM and 20 VM-hours.
ALTER TABLE "apple_subscriptions" ADD COLUMN IF NOT EXISTS "offer_type" integer;
--> statement-breakpoint
ALTER TABLE "apple_subscriptions" ADD COLUMN IF NOT EXISTS "offer_discount_type" text;
--> statement-breakpoint
ALTER TABLE "apple_subscriptions" ADD COLUMN IF NOT EXISTS "free_trial" boolean DEFAULT false NOT NULL;
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "apple_trial_challenges" (
	"challenge" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_trial_challenges_user_idx" ON "apple_trial_challenges" ("user_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "apple_app_attest_keys" (
	"key_id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"public_key_spki" text NOT NULL,
	"sign_count" bigint DEFAULT 0 NOT NULL,
	"environment" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_app_attest_keys_user_idx" ON "apple_app_attest_keys" ("user_id");
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "apple_trial_claims" (
	"user_id" text PRIMARY KEY NOT NULL,
	"key_id" text NOT NULL,
	"device_check_token" text,
	"status" text NOT NULL,
	"verified_at" timestamp with time zone DEFAULT now() NOT NULL,
	"started_at" timestamp with time zone,
	"original_transaction_id" text,
	"device_mark_attempted_at" timestamp with time zone,
	"device_marked_at" timestamp with time zone,
	"granted_at" timestamp with time zone,
	CONSTRAINT "apple_trial_claims_status_check" CHECK ("status" in ('verified', 'started', 'device_reused'))
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "apple_trial_claims_key_idx" ON "apple_trial_claims" ("key_id");
--> statement-breakpoint
CREATE OR REPLACE FUNCTION cmux_guard_go_vm_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  live_count integer;
  active_count integer;
  period_start timestamptz;
  period_end timestamptz;
  used_seconds double precision;
  is_trial boolean;
  saved_limit integer;
  included_seconds double precision;
BEGIN
  IF NEW.billing_plan_id IS DISTINCT FROM 'go' OR NEW.status NOT IN ('provisioning', 'running', 'paused') THEN
    RETURN NEW;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('cmux-go:' || NEW.user_id, 0));
  -- The iOS Pro free trial runs on Go limits with one saved VM and 20
  -- VM-hours (72000 s), unless a web Go subscription also covers the user.
  is_trial := EXISTS (
      SELECT 1 FROM apple_subscriptions
      WHERE user_id = NEW.user_id AND plan_id = 'go' AND free_trial
        AND status IN ('active','grace_period','billing_retry')
        AND greatest(expires_at, coalesce(grace_period_expires_at, expires_at)) > clock_timestamp())
    AND NOT EXISTS (
      SELECT 1 FROM stripe_subscriptions
      WHERE stack_user_id = NEW.user_id AND scope = 'user' AND plan = 'go'
        AND status IN ('active','trialing') AND current_period_end > clock_timestamp());
  saved_limit := CASE WHEN is_trial THEN 1 ELSE 2 END;
  included_seconds := CASE WHEN is_trial THEN 72000 ELSE 144000 END;
  SELECT count(*), count(*) FILTER (WHERE status IN ('provisioning','running'))
    INTO live_count, active_count FROM cloud_vms
    WHERE user_id = NEW.user_id AND id <> NEW.id AND status IN ('provisioning','running','paused');
  IF live_count >= saved_limit THEN
    RAISE EXCEPTION 'Go supports two saved VMs in total' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_saved_limit';
  END IF;
  IF NEW.status IN ('provisioning','running') AND active_count >= 1 THEN
    RAISE EXCEPTION 'Go supports one active VM' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_active_limit';
  END IF;
  IF NEW.status IN ('provisioning','running') AND (TG_OP = 'INSERT' OR OLD.status <> NEW.status) THEN
    SELECT to_timestamp(coalesce(
      (raw->'items'->'data'->0->>'current_period_start')::double precision,
      (raw->>'current_period_start')::double precision)), current_period_end
      INTO period_start, period_end FROM stripe_subscriptions
      WHERE stack_user_id = NEW.user_id AND scope = 'user' AND plan = 'go'
        AND status IN ('active','trialing') ORDER BY updated_at DESC LIMIT 1;
    IF period_start IS NULL OR period_end IS NULL OR period_end <= clock_timestamp() THEN
      SELECT coalesce(purchase_date, expires_at - interval '31 days'),
          greatest(expires_at, coalesce(grace_period_expires_at, expires_at))
        INTO period_start, period_end FROM apple_subscriptions
        WHERE user_id = NEW.user_id AND plan_id = 'go'
          AND status IN ('active','grace_period','billing_retry')
          AND greatest(expires_at, coalesce(grace_period_expires_at, expires_at)) > clock_timestamp()
        ORDER BY expires_at DESC NULLS LAST LIMIT 1;
    END IF;
    IF period_start IS NULL OR period_end IS NULL OR period_start >= period_end OR period_end <= clock_timestamp() THEN
      RAISE EXCEPTION 'Go billing period is unavailable' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_period_unavailable';
    END IF;
    SELECT coalesce(sum(greatest(0, extract(epoch FROM
      least(coalesce(ended_at, clock_timestamp()), period_end) - greatest(started_at, period_start)))),0)
      INTO used_seconds FROM cloud_vm_runtime_intervals
      WHERE user_id = NEW.user_id AND started_at < period_end AND (ended_at IS NULL OR ended_at > period_start);
    IF used_seconds >= included_seconds THEN
      RAISE EXCEPTION 'Go runtime limit reached' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_hours_limit';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
