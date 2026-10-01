import { z } from "zod";
import * as accessGrantsRoute from "@/app/api/vm/access-grants/route";
import * as accessGrantRoute from "@/app/api/vm/access-grants/[id]/route";
import { dashboardOS, requireDashboardOrigin } from "./base";
import { callRoute } from "./route-call";
import { cloudDevicesSchema } from "./schemas/cloud";

/**
 * The VM access-grant routes own authentication, request telemetry, and the
 * Stack session revocation after a revoke, and the macOS app calls them, so
 * these procedures run them in process behind the browser origin check.
 */
const cloudOS = dashboardOS.use(requireDashboardOrigin);

const grantInput = z.object({ id: z.string().trim().min(1).max(200) });

const devices = cloudOS
  .output(cloudDevicesSchema)
  .handler(async ({ context }) =>
    cloudDevicesSchema.parse(await callRoute(context, accessGrantsRoute.GET, { method: "GET", path: "/api/vm/access-grants" }))
  );

const renameDevice = cloudOS
  .input(grantInput.extend({ displayName: z.string().trim().max(63) }))
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, accessGrantRoute.PATCH, {
      method: "PATCH",
      path: `/api/vm/access-grants/${encodeURIComponent(input.id)}`,
      params: { id: input.id },
      body: { displayName: input.displayName },
    });
    return null;
  });

const revokeDevice = cloudOS
  .input(grantInput)
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, accessGrantRoute.DELETE, {
      method: "DELETE",
      path: `/api/vm/access-grants/${encodeURIComponent(input.id)}`,
      params: { id: input.id },
    });
    return null;
  });

export const cloudRouter = { devices, renameDevice, revokeDevice };
