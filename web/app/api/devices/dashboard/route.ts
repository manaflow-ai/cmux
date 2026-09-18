// Account device dashboard data — the device list as cmux.com renders it:
// registry facts (name, platform, tag, last seen) joined with the control
// plane's listv2 facts (status, revoked, version/track, ack watermarks,
// connected state, head revision).
//
// Auth: cookie session (the signed-in cmux.com dashboard), unlike the sibling
// registry routes which take native header auth. The control-plane fetch
// reuses the session's own access token.

import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { loadDeviceDashboard } from "../../../../services/devices/dashboard";

export async function GET(): Promise<Response> {
  if (!isStackConfigured()) {
    return jsonResponse({ error: "auth_unconfigured" }, 503);
  }
  const app = getStackServerApp();
  const user = await app.getUser({ or: "return-null" });
  if (!user || user.isAnonymous) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  const authJson = await app.getAuthJson();
  const data = await loadDeviceDashboard(user.id, authJson?.accessToken ?? null);
  return new Response(JSON.stringify(data), {
    status: 200,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
    },
  });
}
