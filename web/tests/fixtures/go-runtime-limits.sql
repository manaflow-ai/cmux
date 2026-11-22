-- Run against an isolated database after the Plus limits migration.
BEGIN;
DO $$
DECLARE
  u text := 'starter-test-' || gen_random_uuid();
  machine uuid;
  rejected boolean;
  constraint_seen text;
BEGIN
  INSERT INTO stripe_subscriptions(id, customer_id, stack_user_id, status, plan, scope, current_period_end, raw)
    VALUES (u,u,u,'active','go','user',now()+interval '27 days',jsonb_build_object('current_period_start',extract(epoch from now()-interval '3 days')));
  INSERT INTO cloud_vms(user_id,billing_team_id,billing_plan_id,provider,image_id,status)
    VALUES (u,u,'go','freestyle','test','running') RETURNING id INTO machine;
  UPDATE cloud_vms SET status='running' WHERE id=machine;
  IF (SELECT count(*) FROM cloud_vm_runtime_intervals WHERE vm_id=machine AND ended_at IS NULL) <> 1 THEN
    RAISE EXCEPTION 'repeated running update duplicated metering';
  END IF;
  rejected := false;
  BEGIN
    INSERT INTO cloud_vms(user_id,billing_team_id,billing_plan_id,provider,image_id,status)
      VALUES (u,u || '-other-team','go','freestyle','test','running');
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS constraint_seen=CONSTRAINT_NAME;
    rejected := constraint_seen='cmux_go_saved_limit';
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'second running VM bypassed account cap'; END IF;
  UPDATE cloud_vms SET status='paused' WHERE id=machine;
  IF EXISTS (SELECT 1 FROM cloud_vm_runtime_intervals WHERE vm_id=machine AND ended_at IS NULL) THEN
    RAISE EXCEPTION 'pause did not close runtime';
  END IF;
  rejected := false;
  BEGIN
    INSERT INTO cloud_vms(user_id,billing_team_id,billing_plan_id,provider,image_id,status)
      VALUES (u,u || '-other-team','go','freestyle','test','paused');
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS constraint_seen=CONSTRAINT_NAME;
    rejected := constraint_seen='cmux_go_saved_limit';
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'paused VM bypassed saved cap'; END IF;
  UPDATE cloud_vm_runtime_intervals SET started_at=now()-interval '1000 hours', ended_at=now() WHERE vm_id=machine;
  UPDATE cloud_vms SET status='running' WHERE id=machine;
  IF (SELECT status FROM cloud_vms WHERE id=machine) <> 'running' THEN RAISE EXCEPTION 'Plus still enforces an hour cap'; END IF;
  UPDATE cloud_vms SET status='destroyed',destroyed_at=now() WHERE id=machine;
  INSERT INTO cloud_vms(user_id,billing_team_id,billing_plan_id,provider,image_id,status)
    VALUES (u,u,'go','freestyle','test','running');
  RAISE NOTICE 'PASS: one saved/active VM across teams, paused cap, no hour cap, replacement after deletion';
END;
$$;
-- Seed an account that already retained two VMs under the old Go offer.
-- Disable only the capacity guard during fixture creation; runtime metering stays on.
ALTER TABLE cloud_vms DISABLE TRIGGER cmux_go_vm_capacity;
INSERT INTO cloud_vms(id,user_id,billing_team_id,billing_plan_id,provider,image_id,status)
  VALUES ('00000000-0000-4000-8000-000000015001','starter-legacy-fixture','starter-legacy-fixture','go','freestyle','test','running'),
         ('00000000-0000-4000-8000-000000015002','starter-legacy-fixture','starter-legacy-other-team','go','freestyle','test','paused');
ALTER TABLE cloud_vms ENABLE TRIGGER cmux_go_vm_capacity;
DO $$
DECLARE
  rejected boolean := false;
  constraint_seen text;
BEGIN
  UPDATE cloud_vms SET status='paused' WHERE id='00000000-0000-4000-8000-000000015001';
  IF EXISTS (SELECT 1 FROM cloud_vm_runtime_intervals WHERE vm_id='00000000-0000-4000-8000-000000015001' AND ended_at IS NULL) THEN
    RAISE EXCEPTION 'legacy pause did not close runtime';
  END IF;
  UPDATE cloud_vms SET status='running' WHERE id='00000000-0000-4000-8000-000000015002';
  UPDATE cloud_vms SET status='running' WHERE id='00000000-0000-4000-8000-000000015002';
  BEGIN
    UPDATE cloud_vms SET status='running' WHERE id='00000000-0000-4000-8000-000000015001';
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS constraint_seen=CONSTRAINT_NAME;
    rejected := constraint_seen='cmux_go_active_limit';
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'legacy account started a second active VM'; END IF;
  rejected := false;
  BEGIN
    INSERT INTO cloud_vms(user_id,billing_team_id,billing_plan_id,provider,image_id,status)
      VALUES ('starter-legacy-fixture','starter-legacy-fixture','go','freestyle','test','paused');
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS constraint_seen=CONSTRAINT_NAME;
    rejected := constraint_seen='cmux_go_saved_limit';
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'legacy account added another retained VM'; END IF;
  RAISE NOTICE 'PASS: legacy VMs can pause and switch, without adding another saved or active VM';
END;
$$;
ROLLBACK;
