import { env } from "../../app/env";

export type VmChangedPublication = {
  readonly teamId: string;
  readonly vmId: string;
  readonly displayName: string | null;
  readonly slug: string | null;
  readonly status: string;
};

/** Publishes durable VM metadata changes without coupling the DB write to the socket. */
export async function publishVmChanged(change: VmChangedPublication): Promise<void> {
  if (!env.CMUX_IROH_V2_ORIGIN || !env.CMUX_IROH_V2_PUBLISHER_SECRET) return;
  const response = await fetch(new URL("/v2/vm/changed", env.CMUX_IROH_V2_ORIGIN), {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-cmux-workspace-publisher-secret": env.CMUX_IROH_V2_PUBLISHER_SECRET,
    },
    body: JSON.stringify(change),
    signal: AbortSignal.timeout(5_000),
  });
  if (!response.ok) throw new Error(`VM change publication failed (${response.status})`);
}
