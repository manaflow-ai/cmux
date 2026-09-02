// Dashboard device retire: the user removed an old device. Cleanup, NOT a
// security action — the copy must never read as stolen/revoked. Retired
// entries hide by default on the dashboard and un-retire automatically the
// moment the device hellos again.

import { getStackServerApp, isStackConfigured } from "../../../../lib/stack";
import {
  enforceBrowserMutationProtection,
  jsonResponse,
} from "../../../../../services/vms/routeHelpers";
import { readBoundedJsonRecord } from "../../../../../services/subrouter/boundedJson";
import {
  isValidEndpointIdInput,
  retireDeviceOnControlPlane,
} from "../../../../../services/devices/dashboard";

const MAX_REQUEST_BYTES = 1_024;

export async function POST(request: Request): Promise<Response> {
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
  const { endpointId } = body.value;
  if (!isValidEndpointIdInput(endpointId)) {
    return jsonResponse({ error: "invalid_request" }, 400);
  }
  const authJson = await app.getAuthJson();
  const accessToken = authJson?.accessToken ?? null;
  if (!accessToken) return jsonResponse({ error: "unauthorized" }, 401);

  const result = await retireDeviceOnControlPlane(accessToken, endpointId);
  if (!result.ok) {
    return jsonResponse({ error: result.error }, result.status);
  }
  return jsonResponse({ ok: true, rev: result.rev, changed: result.changed }, 200);
}
