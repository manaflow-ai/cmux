CREATE TABLE cloud_vm_runtime_intervals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vm_id uuid NOT NULL REFERENCES cloud_vms(id) ON DELETE CASCADE,
  user_id text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX cloud_vm_runtime_user_started_idx ON cloud_vm_runtime_intervals(user_id, started_at);
CREATE UNIQUE INDEX cloud_vm_runtime_open_vm_unique ON cloud_vm_runtime_intervals(vm_id) WHERE ended_at IS NULL;

-- Start/stop records commit with the VM state. A lost analytics event cannot
-- reset a paid meter. Existing running machines start metering at rollout.
CREATE FUNCTION cmux_record_vm_runtime() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IN ('provisioning', 'running') THEN
    INSERT INTO cloud_vm_runtime_intervals(vm_id, user_id, started_at)
      VALUES (NEW.id, NEW.user_id, clock_timestamp())
      ON CONFLICT (vm_id) WHERE ended_at IS NULL DO NOTHING;
  ELSE
    UPDATE cloud_vm_runtime_intervals SET ended_at = greatest(started_at, clock_timestamp())
      WHERE vm_id = NEW.id AND ended_at IS NULL;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER cmux_vm_runtime AFTER INSERT OR UPDATE OF status ON cloud_vms
  FOR EACH ROW EXECUTE FUNCTION cmux_record_vm_runtime();
INSERT INTO cloud_vm_runtime_intervals(vm_id, user_id)
  SELECT id, user_id FROM cloud_vms WHERE status IN ('provisioning', 'running');

-- Account-wide limits also cover Base, fork, restore, and concurrent creates
-- in different teams. Paused machines retain disk and count as saved VMs.
CREATE FUNCTION cmux_guard_go_vm_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
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
      RAISE EXCEPTION 'Go billing period is unavailable' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_period_unavailable';
    END IF;
    SELECT coalesce(sum(greatest(0, extract(epoch FROM
      least(coalesce(ended_at, clock_timestamp()), period_end) - greatest(started_at, period_start)))),0)
      INTO used_seconds FROM cloud_vm_runtime_intervals
      WHERE user_id = NEW.user_id AND started_at < period_end AND (ended_at IS NULL OR ended_at > period_start);
    IF used_seconds >= 144000 THEN
      RAISE EXCEPTION 'Go runtime limit reached' USING ERRCODE = '23514', CONSTRAINT = 'cmux_go_hours_limit';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER cmux_go_vm_capacity BEFORE INSERT OR UPDATE OF status, billing_plan_id ON cloud_vms
  FOR EACH ROW EXECUTE FUNCTION cmux_guard_go_vm_capacity();
