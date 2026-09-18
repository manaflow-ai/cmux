// Dashboard device revocation: mark a device DISALLOWED (revoked=true) or
// restore it. The device STAYS on the list, flagged; revoking bans it from
// dialing any device in the account.
//
// Two halves, one write path: the control-plane DO flips the revoked flag
// (instant broadcast, socket close, mint denial), and on revoke the registry
// binding is mirrored-revoked so OLD clients' discovery drops the device too.
// Un-revoke touches only the DO — the device's next registration recreates
// its registry row on the old stack.

import { getStackServerApp, isStackConfigured } from "../../../../lib/stack";
import {
  enforceBrowserMutationProtection,
  jsonResponse,
} from "../../../../../services/vms/routeHelpers";
import { readBoundedJsonRecord } from "../../../../../services/subrouter/boundedJson";
import {
  isValidEndpointIdInput,
  mirrorRevocationToRegistry,
  revokeDeviceOnControlPlane,
} from "../../../../../services/devices/dashboard";

const MAX_REQUEST_BYTES = 1_024;

export async function POST(request: Request): Promise<Response> {
  // Cookie-authed browser mutation: enforce same-origin before anything else.
  const forbidden = enforceBrowserMutationProtection(request);
  if (forbidden) return forbidden;
  if (!isStackConfigured()) {
    return jsonResponse({ error: "auth_unconfigured" }, 503);
  }
  const app = getStackServerApp();
  const user = await app.getUser({ or: "return-null" });
  if (!user || user.isAnonymous) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  const body = await readBoundedJsonRecord(request, MAX_REQUEST_BYTES);
  if (!body.ok) return jsonResponse({ error: "invalid_request" }, body.status);
  const { endpointId, revoked } = body.value;
  if (!isValidEndpointIdInput(endpointId) || typeof revoked !== "boolean") {
    return jsonResponse({ error: "invalid_request" }, 400);
  }
  const authJson = await app.getAuthJson();
  const accessToken = authJson?.accessToken ?? null;
  if (!accessToken) return jsonResponse({ error: "unauthorized" }, 401);

  const result = await revokeDeviceOnControlPlane(accessToken, endpointId, revoked);
  if (!result.ok) {
    return jsonResponse({ error: result.error }, result.status);
  }

  let registryMirrored = false;
  if (revoked) {
    try {
      registryMirrored = await mirrorRevocationToRegistry(user.id, endpointId, accessToken) !== null;
    } catch (error) {
      // The DO half committed (the device is banned on the new stack); the
      // caller must know the old stack still lists it. Retrying is safe —
      // both halves are idempotent.
      console.error("dashboard revoke: registry mirror failed", error);
      return jsonResponse({
        error: "registry_mirror_failed",
        controlPlaneRevoked: true,
        rev: result.rev,
      }, 502);
    }
  }

  return jsonResponse({
    ok: true,
    revoked,
    rev: result.rev,
    changed: result.changed,
    registryMirrored,
  }, 200);
}
