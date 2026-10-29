-- next's Run enum values, in a migration of their own: a value added by ALTER TYPE ... ADD VALUE
-- cannot be used in the transaction that added it. main's attempt.cancelled and run.cancelled stay
-- (Postgres cannot drop an enum value without rebuilding the type).
ALTER TYPE "run_status" ADD VALUE IF NOT EXISTS 'cancelling';--> statement-breakpoint
ALTER TYPE "run_attempt_status" ADD VALUE IF NOT EXISTS 'leased';--> statement-breakpoint
ALTER TYPE "run_attempt_status" ADD VALUE IF NOT EXISTS 'expired';--> statement-breakpoint
ALTER TYPE "run_event_kind" ADD VALUE IF NOT EXISTS 'attempt.heartbeat';--> statement-breakpoint
ALTER TYPE "run_event_kind" ADD VALUE IF NOT EXISTS 'attempt.output';--> statement-breakpoint
ALTER TYPE "run_event_kind" ADD VALUE IF NOT EXISTS 'attempt.artifact';--> statement-breakpoint
ALTER TYPE "run_event_kind" ADD VALUE IF NOT EXISTS 'run.cancel_requested';--> statement-breakpoint
ALTER TYPE "run_event_kind" ADD VALUE IF NOT EXISTS 'run.completed';
