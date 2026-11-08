-- The Stack invitation a stored role was sent with. A role applies only to
-- that invitation; rows without one (sent before this column) apply as member.
ALTER TABLE "team_invite_roles" ADD COLUMN IF NOT EXISTS "stack_invitation_id" text;
