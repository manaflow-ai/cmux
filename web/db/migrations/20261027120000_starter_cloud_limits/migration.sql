-- Plus keeps the historical go plan ID and allows one saved machine,
-- whether running or paused. Runtime remains metered, with no hour cap.
-- Existing subscriptions retain their Stripe prices.
CREATE OR REPLACE FUNCTION cmux_guard_go_vm_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  live_count integer;
  active_count integer;
BEGIN
  IF NEW.billing_plan_id IS DISTINCT FROM 'go' OR NEW.status NOT IN ('provisioning', 'running', 'paused') THEN
    RETURN NEW;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('cmux-go:' || NEW.user_id, 0));
  SELECT count(*), count(*) FILTER (WHERE status IN ('provisioning','running'))
    INTO live_count, active_count FROM cloud_vms
    WHERE user_id = NEW.user_id AND id <> NEW.id AND status IN ('provisioning','running','paused');
  -- Existing accounts may already retain more than one machine. Allow their
  -- lifecycle updates while refusing any new saved or active allocation.
  IF live_count >= 1 AND (
    TG_OP = 'INSERT'
    OR OLD.billing_plan_id IS DISTINCT FROM 'go'
    OR OLD.user_id IS DISTINCT FROM NEW.user_id
    OR OLD.status NOT IN ('provisioning','running','paused')
  ) THEN
    RAISE EXCEPTION 'Plus supports one saved VM in total' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_saved_limit';
  END IF;
  IF NEW.status IN ('provisioning','running') AND active_count >= 1 AND (
    TG_OP = 'INSERT'
    OR OLD.billing_plan_id IS DISTINCT FROM 'go'
    OR OLD.user_id IS DISTINCT FROM NEW.user_id
    OR OLD.status NOT IN ('provisioning','running')
  ) THEN
    RAISE EXCEPTION 'Plus supports one active VM' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_active_limit';
  END IF;
  RETURN NEW;
END;
$$;
