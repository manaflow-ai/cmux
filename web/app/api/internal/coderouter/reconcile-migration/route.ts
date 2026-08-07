import { sql } from "drizzle-orm";

import { cloudDb } from "../../../../../db/client";
import { captureCoderouterError } from "../../../../../services/errors";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

/**
 * One-shot production migration fallback for environments where local AWS
 * credentials cannot assume the Vercel RDS role. Delete this route immediately
 * after the idempotent migration succeeds.
 */
export async function POST(request: Request): Promise<Response> {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret || request.headers.get("authorization") !== `Bearer ${secret}`) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }
  try {
    const db = cloudDb();
    await db.execute(sql`
      alter table "stripe_subscriptions"
      add column if not exists "last_reconciled_at" timestamp with time zone
    `);
    await db.execute(sql`
      create index if not exists "stripe_subscriptions_reconcile_cursor_idx"
      on "stripe_subscriptions"
      ("last_reconciled_at" asc nulls first, "id" asc)
    `);
    return Response.json({ ok: true });
  } catch (error) {
    captureCoderouterError(error, {
      operation: "stripe_reconcile_cursor_migration",
      recoverable: true,
    });
    return Response.json({
      error: "migration_failed",
      message: "Migration failed; inspect internal telemetry and retry.",
      retryable: true,
    }, { status: 503, headers: { "Retry-After": "60" } });
  }
}
