import type { z } from "zod";
import type { cloudDevicesSchema } from "@/orpc/server/dashboard/schemas/cloud";
import { rpc } from "../lib/rpc";

/** One Mac with Cloud VM network access. */
export type CloudDevice = z.output<typeof cloudDevicesSchema>["devices"][number];

export const cloudDevicesQuery = rpc.cloud.devices.queryOptions({
  select: (data) => data.devices,
  retry: false,
});
