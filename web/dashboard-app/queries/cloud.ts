import type { z } from "zod";
import type { cloudDevicesSchema, cloudMachinesSchema, cloudNetworkStateSchema } from "@/orpc/server/dashboard/schemas/cloud";
import { rpc } from "../lib/rpc";

/** One Mac with Cloud VM network access. */
export type CloudDevice = z.output<typeof cloudDevicesSchema>["devices"][number];

/** One Cloud machine, personal or the selected team's. */
export type CloudMachine = z.output<typeof cloudMachinesSchema>["machines"][number];

/** A machine's outbound network policy, the preset catalog, and its apply state. */
export type CloudNetworkState = z.output<typeof cloudNetworkStateSchema>;

export const cloudDevicesQuery = rpc.cloud.devices.queryOptions({
  select: (data) => data.devices,
  retry: false,
});

export const cloudMachinesQuery = rpc.cloud.machines.queryOptions({
  select: (data) => data.machines,
  retry: false,
});
