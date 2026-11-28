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

/** One Cloud machine the dashboard can set a network policy on. */
const cloudMachineSchema = z.object({
  id: z.string(),
  name: z.string(),
  status: z.enum(["provisioning", "running", "failed", "paused", "destroyed"]),
  /** The team that owns the machine; null for a personal machine. */
  teamId: nullableString,
});

export const cloudMachinesSchema = z.object({ machines: z.array(cloudMachineSchema) });

const networkPolicyRangeSchema = z.object({
  cidr: z.string(),
  port: z.number().int().optional(),
  protocol: z.enum(["tcp", "udp"]).optional(),
  note: z.string().optional(),
});

const networkPolicySchema = z.object({
  version: z.literal(1),
  mode: z.enum(["full", "allowlist", "none"]),
  ranges: z.array(networkPolicyRangeSchema),
  domains: z.array(z.string()),
  presets: z.array(z.string()),
  allowDns: z.boolean(),
});

/** `GET`/`PUT /api/vm/{id}/network`, as the dashboard editor reads it. */
export const cloudNetworkStateSchema = z.object({
  policy: networkPolicySchema,
  presets: z.array(z.object({ id: z.string(), label: z.string(), domains: z.array(z.string()) })),
  requiredDomains: z.array(z.string()),
  applied: z.object({
    state: z.enum(["applied", "pending", "failed"]),
    error: z.string().optional(),
    appliedAt: z.union([z.string(), z.number()]).optional(),
  }),
});
