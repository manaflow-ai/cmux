import { authorizeCronRequest } from "../../../../services/cronAuth";
import { reconcileTeamSeats } from "../../../../services/billing/teamSeats";
import { captureCoderouterError } from "../../../../services/errors";

export const maxDuration = 60;

/** Sweeps Team seat facts the inline reconcile missed (a crash, a Stripe outage). */
export async function GET(request: Request): Promise<Response> {
  if (!authorizeCronRequest(request).ok) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  try {
    const result = await reconcileTeamSeats();
    return Response.json({ ok: result.failed === 0, ...result }, { status: result.failed === 0 ? 200 : 503 });
  } catch (error) {
    captureCoderouterError(error, { operation: "team_seat_reconcile_cron", recoverable: true });
    return Response.json(
      { error: "team_seats_reconcile_failed", message: "Team seat reconciliation failed; retry the cron run.", retryable: true },
      { status: 503, headers: { "Retry-After": "60" } },
    );
  }
}
