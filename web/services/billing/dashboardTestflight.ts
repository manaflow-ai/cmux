import { isAscConfigured } from "../asc/client";
import { testerGroupStatus } from "../asc/testflight";
import { captureAscError } from "../errors";
import { isTestflightEligible } from "./pro";

export type DashboardTestflightStatus = {
  readonly enrolled: boolean;
  readonly state?: string;
  readonly unavailable?: boolean;
};

/** Wire shape of `GET /api/testflight`. */
export type DashboardTestflightResponse = {
  readonly eligible: boolean;
  /** The normalized primary email, or null when the account has none. */
  readonly email: string | null;
  readonly status: DashboardTestflightStatus;
};

/**
 * Entitlement and enrollment for the TestFlight screen, read fresh on every
 * request so a lapsed subscription or a leave action shows at once.
 */
export async function loadDashboardTestflight(user: {
  readonly id: string;
  readonly primaryEmail?: string | null;
}): Promise<DashboardTestflightResponse> {
  const eligible = await isTestflightEligible(user);
  const email = normalizedEmail(user.primaryEmail);
  const status = eligible && email
    ? await loadTestflightStatus(email, user.id)
    : { enrolled: false };
  return { eligible, email, status };
}

async function loadTestflightStatus(
  email: string,
  stackUserId: string,
): Promise<DashboardTestflightStatus> {
  if (!isAscConfigured()) return { enrolled: false, unavailable: true };
  try {
    const status = await testerGroupStatus(email);
    return status.state === undefined
      ? { enrolled: status.enrolled }
      : { enrolled: status.enrolled, state: status.state };
  } catch (error) {
    captureAscError(error, {
      page: "/dashboard/testflight",
      stackUserId,
      email,
    });
    return { enrolled: false, unavailable: true };
  }
}

function normalizedEmail(email: string | null | undefined): string | null {
  const normalized = email?.trim().toLowerCase();
  return normalized ? normalized : null;
}
