import { queryOptions } from "@tanstack/react-query";
import { z } from "zod";
import { dashboardFetch } from "../lib/api";

const nullableString = z.string().nullable();

/** One Mac with Cloud VM network access, as `GET /api/vm/access-grants` lists it. */
const cloudDeviceSchema = z.object({
  id: z.string(),
  deviceId: z.string(),
  name: z.string(),
  reportedName: nullableString,
  displayName: nullableString,
  modelIdentifier: nullableString,
  osVersion: nullableString,
  architecture: nullableString,
  cmuxVersion: nullableString,
  cmuxBuild: nullableString,
  cmuxChannel: nullableString,
  createdAt: z.number(),
  lastControlPlaneAt: z.number(),
  tunnelPurposes: z.array(z.enum(["terminal", "browser"])),
});

const cloudDevicesSchema = z.object({ devices: z.array(cloudDeviceSchema) });

export type CloudDevice = z.output<typeof cloudDeviceSchema>;

export const cloudDevicesQuery = queryOptions({
  queryKey: ["dashboard", "cloud", "access-grants"] as const,
  queryFn: ({ signal }) => dashboardFetch("/api/vm/access-grants", cloudDevicesSchema, { signal }),
  select: (data) => data.devices,
  retry: false,
});
