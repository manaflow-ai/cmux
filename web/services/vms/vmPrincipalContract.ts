// The machine principal's contract: which rows may speak for themselves, what a
// principal is, and how a refusal is worded. Pure (no database, no framework), so
// services/vms/reflection.ts and the tests can import it without drizzle.
import type { RouteTokenAuthFailure } from "../coderouter/routeTokenAuth";

/** Statuses in which a machine may speak for itself (a destroyed row is nobody). */
export const VM_PRINCIPAL_LIVE_STATUSES = ["provisioning", "running", "paused"] as const;
export type VmPrincipalLiveStatus = (typeof VM_PRINCIPAL_LIVE_STATUSES)[number];

/** The `cloud_vms` columns the principal and the reflection payloads need. */
export type VmPrincipalRow = {
  readonly id: string;
  readonly userId: string;
  readonly billingTeamId: string | null;
  readonly billingPlanId: string | null;
  readonly provider: string;
  readonly providerVmId: string | null;
  readonly displayName: string | null;
  readonly slug: string | null;
  readonly imageId: string;
  readonly imageVersion: string | null;
  readonly status: string;
  readonly createdAt: Date;
  readonly providerMetadata: Readonly<Record<string, unknown>>;
};

export type VmPrincipal = {
  readonly vm: VmPrincipalRow;
  /** The Stack user the token was issued for: the machine's owner. */
  readonly userId: string;
  /** The billing team the token was issued for. */
  readonly teamId: string;
};

export type VmPrincipalFailure =
  | RouteTokenAuthFailure
  | "vm_bound_token_required"
  | "vm_not_found"
  | "vm_not_live"
  | "vm_owner_mismatch";

export type VmPrincipalResult =
  | { readonly ok: true; readonly principal: VmPrincipal }
  | { readonly ok: false; readonly reason: VmPrincipalFailure };


/** 401 = not a machine we recognize; 403 = a machine, but not this one; 404/409 = the row. */
export function vmPrincipalFailureStatus(reason: VmPrincipalFailure): number {
  switch (reason) {
    case "missing_route_token":
    case "invalid_route_token":
    case "vm_mismatch":
      return 401;
    case "vm_bound_token_required":
    case "vm_owner_mismatch":
      return 403;
    case "vm_not_found":
      return 404;
    case "vm_not_live":
      return 409;
  }
}

const FAILURE_MESSAGES: Record<VmPrincipalFailure, { message: string; action: string }> = {
  missing_route_token: {
    message: "Reflection answers only a cmux Cloud machine: this request carried no machine credential.",
    action: "Call it from inside the machine through its alias origin (CMUX_CODEROUTER_URL); the platform edge adds the credential.",
  },
  invalid_route_token: {
    message: "This machine's credential expired or was revoked.",
    action: "Reconnect the machine from the Mac (cmux vm tree <machine> --refresh) so its edge rule is re-provisioned, then retry.",
  },
  vm_mismatch: {
    message: "This machine's credential does not match the machine it was issued to.",
    action: "The edge rule was provisioned for another machine; recreate the machine or contact support.",
  },
  vm_bound_token_required: {
    message: "Reflection is only available from inside a cmux Cloud machine.",
    action: "Run `cmux whoami` inside the machine; from the Mac use `cmux vm status <machine>`.",
  },
  vm_not_found: {
    message: "The machine this credential names no longer exists.",
    action: "The machine was destroyed; nothing to do from inside it.",
  },
  vm_not_live: {
    message: "The machine this credential names is not live.",
    action: "A destroyed or failed machine cannot speak for itself; open it again from the Mac.",
  },
  vm_owner_mismatch: {
    message: "This credential's owner does not own the machine it names.",
    action: "The machine changed hands or teams; recreate it or contact support.",
  },
};

const JSON_HEADERS = { "cache-control": "no-store", "content-type": "application/json" } as const;

export function vmPrincipalFailureResponse(reason: VmPrincipalFailure): Response {
  const { message, action } = FAILURE_MESSAGES[reason];
  return new Response(
    JSON.stringify({ error: reason, message, action, retryable: false }),
    { status: vmPrincipalFailureStatus(reason), headers: JSON_HEADERS },
  );
}
