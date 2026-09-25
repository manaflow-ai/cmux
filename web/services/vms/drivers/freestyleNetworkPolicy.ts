import { FreestyleApiError, type Freestyle } from "freestyle";
import { canonicalCidr, type NetworkRulePlan } from "../networkPolicy";

/**
 * Freestyle mapping for a Cloud machine's outbound network policy
 * (services/vms/networkPolicy.ts).
 *
 * Measured against the live platform (2026-09-24 spike):
 * - A VM with no egress rule reaches nothing, DNS included: the guest's
 *   resolvers are public addresses.
 * - Firewall and TLS rule changes apply to a running VM within ~0.1 s.
 * - A TLS rule with a `public` destination steers its exact name through the
 *   guest's /etc/hosts to the edge and needs no firewall grant.
 * - A TLS rule with a `host` destination (the CodeRouter and reflection
 *   aliases) does NOT carry that grant: the guest needs a firewall path to the
 *   edge address on 443. {@link freestyleEdgeAddresses} supplies it.
 */

/** Firewall rules this module owns carry this description, so reconcile never touches anyone else's. */
export const EGRESS_RULE_DESCRIPTION = "cmux:egress";

/** The guest's resolvers from the base image's resolv.conf; overridable for other regions. */
const DEFAULT_GUEST_DNS_RESOLVERS = ["8.8.8.8", "8.8.4.4", "2606:4700:4700::1111", "2001:4860:4860::8888"];

/**
 * The Freestyle TLS edge as seen from a guest. Observed in the spike; Freestyle
 * does not document it, so it is configuration, not a constant, and the grant
 * is 443/tcp only.
 */
const DEFAULT_EDGE_ADDRESSES = ["2602:f470:1::28", "10.32.0.28"];

function addressList(envValue: string | undefined, fallback: readonly string[]): string[] {
  const values = envValue?.split(",").map((value) => value.trim()).filter(Boolean);
  return (values && values.length > 0 ? values : [...fallback]).map((value) => canonicalCidr(value));
}

export function freestyleGuestDnsResolvers(env: NodeJS.ProcessEnv = process.env): string[] {
  return addressList(env.FREESTYLE_GUEST_DNS_RESOLVERS, DEFAULT_GUEST_DNS_RESOLVERS);
}

export function freestyleEdgeAddresses(env: NodeJS.ProcessEnv = process.env): string[] {
  return addressList(env.FREESTYLE_EDGE_ADDRESSES, DEFAULT_EDGE_ADDRESSES);
}

/** An egress destination; the source is always the machine itself. */
export type EgressDestination = {
  readonly public?: true;
  readonly cidr?: string;
  readonly port?: number;
  readonly protocol?: "tcp" | "udp";
};

/** The IP-layer destinations a plan needs. Pure; order is stable. */
export function egressDestinations(plan: NetworkRulePlan, env: NodeJS.ProcessEnv = process.env): EgressDestination[] {
  if (plan.publicEgress) return [{ public: true }];
  const destinations: EgressDestination[] = plan.ranges.map((range) => ({
    cidr: range.cidr,
    ...(range.port !== undefined ? { port: range.port } : {}),
    ...(range.protocol !== undefined ? { protocol: range.protocol } : {}),
  }));
  if (plan.dns) {
    for (const cidr of freestyleGuestDnsResolvers(env)) {
      destinations.push({ cidr, port: 53, protocol: "udp" }, { cidr, port: 53, protocol: "tcp" });
    }
  }
  for (const cidr of freestyleEdgeAddresses(env)) {
    destinations.push({ cidr, port: 443, protocol: "tcp" });
  }
  return dedupeBy(destinations, destinationKey);
}

export function destinationKey(destination: EgressDestination): string {
  return [destination.public ? "public" : destination.cidr ?? "", destination.port ?? "", destination.protocol ?? ""].join("|");
}

/** Inline create-time firewall rules for the new VM (`source: {}` is the VM itself). */
export function inlineEgressFirewallRules(plan: NetworkRulePlan, env: NodeJS.ProcessEnv = process.env) {
  return egressDestinations(plan, env).map((destination) => ({
    action: "allow" as const,
    source: {},
    destination: { ...destination },
    description: EGRESS_RULE_DESCRIPTION,
  }));
}

/** Inline create-time TLS rules steering the plan's exact domains through the edge. */
export function inlineEgressTlsRules(plan: NetworkRulePlan) {
  return plan.domains.map((domain) => ({
    action: "allow" as const,
    domain,
    source: {},
    destination: { public: true as const },
  }));
}

type FirewallRule = Awaited<ReturnType<Freestyle["firewall"]["rules"]["list"]>>["rules"][number];
type TlsRule = Awaited<ReturnType<Freestyle["tls"]["rules"]["list"]>>["rules"][number];

/**
 * An egress rule this module may replace: ours by description, or the
 * historical untagged `{vm} -> public` rule every machine was created with.
 * Ingress rules (source public/tunnel/vpc) and network rules never match.
 */
function isManagedFirewallRule(rule: FirewallRule, vmId: string): boolean {
  if (rule.source.vmId !== vmId) return false;
  const destination = rule.destination;
  if (destination.vmId || destination.vpcId || destination.tunnelId) return false;
  if (rule.description === EGRESS_RULE_DESCRIPTION) return true;
  return destination.public === true && destination.port === undefined && destination.protocol === undefined && !rule.description;
}

/** A plain domain-steering rule: public origin, no transform. CodeRouter's aliases carry transforms and a host. */
function isManagedTlsRule(rule: TlsRule, vmId: string): boolean {
  return rule.source.vmId === vmId &&
    rule.destination.public === true &&
    rule.destination.host === undefined &&
    (rule.protocol ?? "http") === "http" &&
    (rule.transform?.length ?? 0) === 0 &&
    !rule.forwardAuth &&
    !rule.managed;
}

export type NetworkReconcileResult = {
  readonly firewallCreated: number;
  readonly firewallDeleted: number;
  readonly tlsCreated: number;
  readonly tlsDeleted: number;
};

/**
 * Converge a running VM's egress rules on `plan`. Grants are created before
 * surplus rules are deleted, so a change never leaves a window where the
 * machine is more closed than either the old or the new policy intends.
 */
export async function reconcileFreestyleEgress(
  fs: Freestyle,
  vmId: string,
  plan: NetworkRulePlan,
  env: NodeJS.ProcessEnv = process.env,
): Promise<NetworkReconcileResult> {
  const [firewall, tls] = await Promise.all([
    fs.firewall.rules.list({ vmId, limit: 1000 }),
    fs.tls.rules.list({ vmId, limit: 1000 }),
  ]);
  const managedFirewall = firewall.rules.filter((rule) => isManagedFirewallRule(rule, vmId));
  const managedTls = tls.rules.filter((rule) => isManagedTlsRule(rule, vmId));

  const wantedDestinations = egressDestinations(plan, env);
  const existingByKey = new Map(managedFirewall.map((rule) => [destinationKey(rule.destination as EgressDestination), rule]));
  const wantedKeys = new Set(wantedDestinations.map(destinationKey));
  const firewallToCreate = wantedDestinations.filter((destination) => !existingByKey.has(destinationKey(destination)));
  const firewallToDelete = managedFirewall.filter((rule) => !wantedKeys.has(destinationKey(rule.destination as EgressDestination)));

  const existingDomains = new Map(managedTls.map((rule) => [rule.domain, rule]));
  const wantedDomains = new Set(plan.domains);
  const tlsToCreate = plan.domains.filter((domain) => !existingDomains.has(domain));
  const tlsToDelete = managedTls.filter((rule) => !wantedDomains.has(rule.domain));

  for (const destination of firewallToCreate) {
    await fs.firewall.rules.create({
      action: "allow",
      source: { vmId },
      destination: { ...destination },
      description: EGRESS_RULE_DESCRIPTION,
    });
  }
  for (const domain of tlsToCreate) {
    await fs.tls.rules.create({ action: "allow", domain, source: { vmId }, destination: { public: true } });
  }
  for (const rule of firewallToDelete) await deleteIgnoringMissing(() => fs.firewall.rules.delete(rule.id));
  for (const rule of tlsToDelete) await deleteIgnoringMissing(() => fs.tls.rules.delete(rule.id));

  return {
    firewallCreated: firewallToCreate.length,
    firewallDeleted: firewallToDelete.length,
    tlsCreated: tlsToCreate.length,
    tlsDeleted: tlsToDelete.length,
  };
}

async function deleteIgnoringMissing(remove: () => Promise<void>): Promise<void> {
  try {
    await remove();
  } catch (err) {
    // Deleting a rule that is already gone is the goal, not a failure.
    if (!(err instanceof FreestyleApiError && (err.status === 404 || err.code === "NOT_FOUND"))) throw err;
  }
}

function dedupeBy<T>(values: readonly T[], key: (value: T) => string): T[] {
  const seen = new Set<string>();
  return values.filter((value) => {
    const k = key(value);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
}
