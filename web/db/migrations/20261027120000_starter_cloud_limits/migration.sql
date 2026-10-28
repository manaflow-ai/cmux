-- Starter uses the historical go plan ID. Keep its account-wide saved cap,
-- allow both machines to run, and double the shared monthly runtime to 80h.
-- Existing subscriptions keep their Stripe prices and gain the new allowance.
CREATE OR REPLACE FUNCTION cmux_guard_go_vm_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  live_count integer;
  active_count integer;
  period_start timestamptz;
  period_end timestamptz;
  used_seconds double precision;
BEGIN
  IF NEW.billing_plan_id IS DISTINCT FROM 'go' OR NEW.status NOT IN ('provisioning', 'running', 'paused') THEN
    RETURN NEW;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('cmux-go:' || NEW.user_id, 0));
  SELECT count(*), count(*) FILTER (WHERE status IN ('provisioning','running'))
    INTO live_count, active_count FROM cloud_vms
    WHERE user_id = NEW.user_id AND id <> NEW.id AND status IN ('provisioning','running','paused');
  IF live_count >= 2 THEN
    RAISE EXCEPTION 'Starter supports two saved VMs in total' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_saved_limit';
  END IF;
  IF NEW.status IN ('provisioning','running') AND active_count >= 2 THEN
    RAISE EXCEPTION 'Starter supports two active VMs' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_active_limit';
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
      RAISE EXCEPTION 'Starter billing period is unavailable' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_period_unavailable';
    END IF;
    SELECT coalesce(sum(greatest(0, extract(epoch FROM
      least(coalesce(ended_at, clock_timestamp()), period_end) - greatest(started_at, period_start)))),0)
      INTO used_seconds FROM cloud_vm_runtime_intervals
      WHERE user_id = NEW.user_id AND started_at < period_end AND (ended_at IS NULL OR ended_at > period_start);
    IF used_seconds >= 288000 THEN
      RAISE EXCEPTION 'Starter runtime limit reached' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_hours_limit';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
