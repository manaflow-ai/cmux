-- Run against an isolated development database after the Go migration.
BEGIN;
DO $$
DECLARE
  u text := 'go-meter-test-' || gen_random_uuid();
  first_id uuid;
  second_id uuid;
  rejected boolean;
  constraint_seen text;
BEGIN
  INSERT INTO stripe_subscriptions(id, customer_id, stack_user_id, status, plan, scope, current_period_end, raw)
    VALUES (u, u, u, 'active', 'go', 'user', now() + interval '27 days',
      jsonb_build_object('items', jsonb_build_object('data', jsonb_build_array(jsonb_build_object('current_period_start',extract(epoch from now() - interval '3 days'))))));
  INSERT INTO cloud_vms(user_id,billing_team_id,billing_plan_id,provider,image_id,status)
    VALUES (u,u,'go','freestyle','test','running') RETURNING id INTO first_id;
  UPDATE cloud_vms SET status='running' WHERE id=first_id;
  IF (SELECT count(*) FROM cloud_vm_runtime_intervals WHERE vm_id=first_id AND ended_at IS NULL) <> 1 THEN
    RAISE EXCEPTION 'repeated running update duplicated billing';
  END IF;
  rejected := false;
  BEGIN
    INSERT INTO cloud_vms(user_id,billing_team_id,billing_plan_id,provider,image_id,status)
      VALUES (u,u || '-other-team','go','freestyle','test','running');
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS constraint_seen=CONSTRAINT_NAME;
    rejected := constraint_seen='cmux_go_active_limit';
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'cross-team active cap failed'; END IF;
  UPDATE cloud_vms SET status='paused' WHERE id=first_id;
  IF EXISTS (SELECT 1 FROM cloud_vm_runtime_intervals WHERE vm_id=first_id AND ended_at IS NULL) THEN
    RAISE EXCEPTION 'pause did not close runtime';
  END IF;
  INSERT INTO cloud_vms(user_id,billing_team_id,billing_plan_id,provider,image_id,status)
    VALUES (u,u,'go','freestyle','test','paused') RETURNING id INTO second_id;
  rejected := false;
  BEGIN
    INSERT INTO cloud_vms(user_id,billing_team_id,billing_plan_id,provider,image_id,status)
      VALUES (u,u,'go','freestyle','test','paused');
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS constraint_seen=CONSTRAINT_NAME;
    rejected := constraint_seen='cmux_go_saved_limit';
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'saved cap failed'; END IF;
  UPDATE cloud_vm_runtime_intervals SET started_at=now()-interval '41 hours', ended_at=now() WHERE vm_id=first_id;
  UPDATE cloud_vms SET status='destroyed', destroyed_at=now() WHERE id=first_id;
  rejected := false;
  BEGIN
    UPDATE cloud_vms SET status='running' WHERE id=second_id;
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS constraint_seen=CONSTRAINT_NAME;
    rejected := constraint_seen='cmux_go_hours_limit';
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'deleting a VM bypassed the runtime cap'; END IF;
  UPDATE stripe_subscriptions SET current_period_end=now()+interval '1 month', raw=jsonb_build_object('current_period_start',extract(epoch from now())) WHERE id=u;
  UPDATE cloud_vms SET status='running' WHERE id=second_id;
  IF (SELECT status FROM cloud_vms WHERE id=second_id) <> 'running' THEN RAISE EXCEPTION 'renewal did not restore access'; END IF;
  RAISE NOTICE 'PASS: runtime transitions, cross-team cap, saved cap, deleted VM accounting, renewal';
END;
$$;
ROLLBACK;
