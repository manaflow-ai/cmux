import { z } from "zod";

import { listVmAccessGrants, runVmWorkflow } from "../../../services/vms/workflows";
import { os, requireAuth } from "../base";

const cloudDeviceSchema = z.object({
  id: z.string(),
  deviceId: z.string(),
  name: z.string(),
  reportedName: z.string().nullable(),
  displayName: z.string().nullable(),
  modelIdentifier: z.string().nullable(),
  osVersion: z.string().nullable(),
  architecture: z.string().nullable(),
  cmuxVersion: z.string().nullable(),
  cmuxBuild: z.string().nullable(),
  cmuxChannel: z.string().nullable(),
  createdAt: z.number(),
  lastControlPlaneAt: z.number(),
  tunnelPurposes: z.array(z.enum(["terminal", "browser"])),
});

export const cloudDevicesProcedure = os
  .route({
    method: "GET",
    path: "/dashboard/cloud/devices",
    operationId: "dashboard.cloud.devices",
    summary: "List the authenticated user's Cloud Macs",
    tags: ["Dashboard"],
    successStatus: 200,
  })
  .output(z.array(cloudDeviceSchema))
  .use(requireAuth)
  .handler(({ context }) => runVmWorkflow(listVmAccessGrants({ userId: context.user.id })));

