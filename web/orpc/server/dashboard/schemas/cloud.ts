import { z } from "zod";

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

export const cloudDevicesSchema = z.object({ devices: z.array(cloudDeviceSchema) });
