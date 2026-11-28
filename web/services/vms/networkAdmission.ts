import * as Effect from "effect/Effect";
import type { ProviderId } from "./drivers";
import { ProviderNetworkFullError } from "./drivers/types";
import { VmProviderOperationError } from "./errors";
import type { VmRepositoryShape } from "./repository";
import { reportError } from "../observability/report";

/**
 * Address admission for a new machine on a private network.
 *
 * Leo, 2026-11-28 (#general capacity thread): "Add admission checks before
 * starting a run: per-team machine cap, free addresses, and fleet capacity",
 * and "Alert at roughly 80% of team and fleet address/quota usage". The team
 * machine cap is the active limit (repository beginCreate); this module is the
 * free-addresses part. Before it, a full network was learned only from the
 * provider refusing the start, after the row, the credit and the cleanup
 * intent were spent on it.
 *
 * The provider reports no member count for a network, so the count is ours:
 * every machine row in the network's scope that is not destroyed or failed and
 * whose recorded IPv4 sits inside the network's CIDR, plus in-flight creates
 * that have no address yet. Paused machines count: a paused provider VM keeps
 * its network attachment. Mac tunnels hold addresses too; they are read from
 * the provider on every admission, alongside the row count (bounded at 1.5 s),
 * since a tunnel-heavy network can be full while its machines are few.
 */

/** Usable members of an IPv4 CIDR the way the provider counts them (a /24 holds 254). */
export function ipv4CidrCapacity(cidr: string | null | undefined): number | null {
  const match = /^\s*(\d{1,3})(?:\.(\d{1,3})){3}\/(\d{1,2})\s*$/.exec(cidr ?? "");
  if (!match) return null;
  const prefix = Number(match[3]);
  if (prefix < 8 || prefix > 30) return null;
  return 2 ** (32 - prefix) - 2;
}

/** Share of a network's addresses at which operators are alerted. */
export const NETWORK_ADDRESS_ALERT_RATIO = 0.8;
const NETWORK_TUNNEL_COUNT_TIMEOUT_MS = 1_500;
const NETWORK_ALERT_INTERVAL_MS = 60 * 60 * 1000;
const lastAlertAt = new Map<string, number>();

export type NetworkAddressUsage = {
  readonly held: number;
  readonly capacity: number;
  readonly machines: number;
  readonly tunnels: number | null;
};

export type NetworkAdmissionInput = {
  readonly provider: ProviderId;
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly network: {
    readonly providerNetworkId: string;
    readonly cidr: string | null;
    readonly scope: "user" | "team";
  };
  /** The row this create inserted; it is counted as one in-flight holder already. */
  readonly vmId: string;
};

type AdmissionRepo = Pick<VmRepositoryShape, "countNetworkAddressHolders">;
type AdmissionProviders = {
  readonly listNetworkTunnelIds?: (provider: ProviderId, networkId: string) => Effect.Effect<string[], unknown>;
};

/** Decide from a usage count; pure, so tests pin the thresholds. */
export function networkAdmissionVerdict(usage: NetworkAddressUsage): "admit" | "alert" | "full" {
  if (usage.held > usage.capacity) return "full";
  if (usage.held >= Math.ceil(usage.capacity * NETWORK_ADDRESS_ALERT_RATIO)) return "alert";
  return "admit";
}

/**
 * Fails with the provider's own network-full refusal when the network has no
 * address for this machine, so the route answers `vm_network_full` exactly as
 * it does when the provider refuses, but before any provider call. An unknown
 * count (no CIDR, no repository method, a read error) admits: the provider's
 * refusal is still the backstop, and admission must never be the outage.
 */
export function admitNetworkAddress(
  repo: AdmissionRepo,
  providers: AdmissionProviders,
  input: NetworkAdmissionInput,
): Effect.Effect<NetworkAddressUsage | null, VmProviderOperationError> {
  return Effect.gen(function* () {
    const capacity = ipv4CidrCapacity(input.network.cidr);
    const countHolders = repo.countNetworkAddressHolders;
    if (capacity === null || !countHolders || !input.network.cidr) return null;
    const listTunnels = providers.listNetworkTunnelIds;
    const [machines, tunnels] = yield* Effect.all([
      countHolders({
        provider: input.provider,
        userId: input.userId,
        billingTeamId: input.billingTeamId ?? null,
        scope: input.network.scope,
        cidr: input.network.cidr,
      }).pipe(Effect.catchAll(() => Effect.succeed(null))),
      listTunnels
        ? listTunnels(input.provider, input.network.providerNetworkId).pipe(
          Effect.map((ids) => ids.length as number | null),
          Effect.timeoutTo({ duration: NETWORK_TUNNEL_COUNT_TIMEOUT_MS, onSuccess: (n) => n, onTimeout: () => null }),
          Effect.catchAll(() => Effect.succeed(null)),
        )
        : Effect.succeed(null),
    ], { concurrency: 2 });
    if (machines === null) return null;

    const usage: NetworkAddressUsage = { held: machines + (tunnels ?? 0), capacity, machines, tunnels };
    const verdict = networkAdmissionVerdict(usage);
    if (verdict !== "admit") alertNetworkAddressUsage(input, usage, verdict);
    if (verdict === "full") {
      return yield* Effect.fail(new VmProviderOperationError({
        provider: input.provider,
        operation: "create",
        cause: new ProviderNetworkFullError(
          input.provider,
          `create: private network ${input.network.providerNetworkId} (${input.network.cidr}) holds ${usage.held - 1} of ${capacity} addresses; admission refused before the provider start`,
        ),
      }));
    }
    return usage;
  });
}

function alertNetworkAddressUsage(input: NetworkAdmissionInput, usage: NetworkAddressUsage, verdict: "alert" | "full"): void {
  const now = Date.now();
  const key = `${input.provider}:${input.network.providerNetworkId}:${verdict}`;
  const last = lastAlertAt.get(key);
  if (last !== undefined && now - last < NETWORK_ALERT_INTERVAL_MS) return;
  lastAlertAt.set(key, now);
  reportError(new Error(verdict === "full" ? "Cloud VM private network full at admission" : "Cloud VM private network past 80% of its addresses"), {
    subsystem: "cloud_vm_alerts",
    code: verdict === "full" ? "private_network_full" : "private_network_addresses_high",
    provider: input.provider,
    providerNetworkId: input.network.providerNetworkId,
    scope: input.network.scope,
    cidr: input.network.cidr,
    held: usage.held,
    capacity: usage.capacity,
    machines: usage.machines,
    tunnels: usage.tunnels,
  });
}

/** Test seam: forget alert de-duplication. */
export function resetNetworkAddressAlertsForTest(): void {
  lastAlertAt.clear();
}
