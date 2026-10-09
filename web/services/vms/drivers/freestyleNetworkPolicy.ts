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
 * Freestyle's 409 when the account already holds its maximum number of TLS
 * rules. The cap is account-wide, shared by every machine and every other
 * workload on the account, and shares the generic CONFLICT code, so only the
 * message identifies it.
 */
export function isFreestyleTlsRuleLimit(err: unknown): boolean {
  if (err instanceof FreestyleTlsRuleLimitRestoreError) return true;
  return err instanceof FreestyleApiError && err.status === 409 && err.code === "CONFLICT" && /TLS rule limit/i.test(err.message);
}

/**
 * The account cap refused a domain swap, and the VM's steering rules were
 * reconciled back to their state before the swap, best-effort. `restored`
 * counts original domains that were missing and recreated, `unrestored`
 * names those still missing; `cause` is Freestyle's refusal.
 */
export class FreestyleTlsRuleLimitRestoreError extends Error {
  constructor(
    readonly restored: number,
    readonly unrestored: readonly string[],
    readonly cause: unknown,
  ) {
    super(`TLS rule limit reached; ${restored} retired rule(s) restored, ${unrestored.length} not restored`);
    this.name = "FreestyleTlsRuleLimitRestoreError";
  }
}

/**
 * Converge a running VM's egress rules on `plan`. Grants are created before
 * surplus rules are deleted, so a change never leaves a window where the
 * machine is more closed than either the old or the new policy intends.
 *
 * The one exception is the account-wide TLS rule cap: when a grant is refused
 * because the account is full and this change retires at least as many
 * steering rules as it adds, those retirements go first and the reconcile runs
 * again. The machine is briefly limited to the domains both policies allow,
 * which never exceeds the user's intent, and a swap at the cap converges. A
 * change that grows the rule count cannot fit, so it deletes nothing.
 *
 * Once a retirement has run, every failure (a partial deletion, a refused or
 * failed retry) rolls the TLS rules back best-effort: rules the swap created
 * are removed first, so their slots are free to recreate the retired ones.
 */
export async function reconcileFreestyleEgress(
  fs: Freestyle,
  vmId: string,
  plan: NetworkRulePlan,
  env: NodeJS.ProcessEnv = process.env,
): Promise<NetworkReconcileResult> {
  try {
    return await reconcileOnce(fs, vmId, plan, env, { freeTlsAtLimit: true });
  } catch (err) {
    if (!(err instanceof TlsSwapStarted)) throw err;
    if (err.failure !== undefined) throw await rollBackTlsSwap(fs, vmId, err.swap, err.failure);
    try {
      const retried = await reconcileOnce(fs, vmId, plan, env, { freeTlsAtLimit: false });
      return { ...retried, tlsDeleted: retried.tlsDeleted + err.swap.retiring };
    } catch (retryErr) {
      throw await rollBackTlsSwap(fs, vmId, err.swap, retryErr);
    }
  }
}

/**
 * A swap at the cap: the VM's managed steering domains before it touched
 * anything (the state rollback restores), and how many rules it set out to retire.
 */
type TlsSwap = { readonly before: ReadonlySet<string>; readonly retiring: number };

/**
 * Internal signal: the cap refused a grant and this reconcile retired rules to
 * make room. `failure` is set when a retirement itself failed.
 */
class TlsSwapStarted extends Error {
  constructor(readonly swap: TlsSwap, readonly failure?: unknown) {
    super("TLS rule limit reached; retired rules to make room");
  }
}

/**
 * Reconcile the VM's steering rules back to their state before the swap,
 * best-effort, then describe the failure: a capacity refusal becomes
 * {@link FreestyleTlsRuleLimitRestoreError}, any other failure is returned
 * as it was after the rollback ran.
 *
 * No bookkeeping of individual deletions is trusted (a delete can remove the
 * rule and still reject). The current rules are listed; rules the swap added
 * are removed first to free their slots, then every original domain that is
 * not present is recreated. When the list fails, every original domain is
 * recreated, relying on an existing rule answering create with a non-limit
 * 409, and the added-rule cleanup is reported as incomplete.
 */
async function rollBackTlsSwap(fs: Freestyle, vmId: string, swap: TlsSwap, failure: unknown): Promise<unknown> {
  const original = [...swap.before];
  let missing = original;
  let addedCleanupComplete = false;
  try {
    const current = (await fs.tls.rules.list({ vmId, limit: 1000 })).rules.filter((rule) => isManagedTlsRule(rule, vmId));
    const added = current.filter((rule) => !swap.before.has(rule.domain));
    const removals = await Promise.allSettled(added.map((rule) => deleteIgnoringMissing(() => fs.tls.rules.delete(rule.id))));
    addedCleanupComplete = removals.every((result) => result.status === "fulfilled");
    const present = new Set(current.map((rule) => rule.domain));
    missing = original.filter((domain) => !present.has(domain));
  } catch (listErr) {
    console.error("[freestyle] TLS swap rollback could not list the VM's rules", vmId, listErr);
  }
  const results = await Promise.allSettled(missing.map((domain) => createIgnoringExisting(() =>
    fs.tls.rules.create({ action: "allow", domain, source: { vmId }, destination: { public: true } }))));
  const unrestored = missing.filter((_, index) => results[index]?.status === "rejected");
  // An already-present rule (possible when the list failed) is not a restore.
  const restored = results.filter((result) => result.status === "fulfilled" && result.value === "created").length;
  if (unrestored.length > 0 || !addedCleanupComplete) {
    console.error("[freestyle] TLS swap rollback incomplete", JSON.stringify({ vmId, unrestored, addedCleanupComplete }));
  }
  return isFreestyleTlsRuleLimit(failure)
    ? new FreestyleTlsRuleLimitRestoreError(restored, unrestored, failure)
    : failure;
}

/** A create that finds the rule already there has reached its goal; a capacity refusal has not. */
async function createIgnoringExisting(create: () => Promise<unknown>): Promise<"created" | "existing"> {
  try {
    await create();
    return "created";
  } catch (err) {
    const exists = err instanceof FreestyleApiError && err.status === 409 && !isFreestyleTlsRuleLimit(err);
    if (!exists) throw err;
    return "existing";
  }
}

async function reconcileOnce(
  fs: Freestyle,
  vmId: string,
  plan: NetworkRulePlan,
  env: NodeJS.ProcessEnv,
  options: { readonly freeTlsAtLimit: boolean },
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

  // Each rule call is a ~0.5 s round trip; serial calls made a policy change
  // take 5-11 s. All grants go out together, then all removals, so the
  // create-before-delete guarantee holds for the batch as a whole.
  try {
    await inBatches([
      ...firewallToCreate.map((destination) => () => fs.firewall.rules.create({
        action: "allow",
        source: { vmId },
        destination: { ...destination },
        description: EGRESS_RULE_DESCRIPTION,
      })),
      ...tlsToCreate.map((domain) => () => fs.tls.rules.create({ action: "allow", domain, source: { vmId }, destination: { public: true } })),
    ]);
  } catch (err) {
    // Free room only when the swap does not grow this VM's rule count; a
    // net-growth change cannot fit, and deleting first would only lose access.
    const swapFits = tlsToDelete.length > 0 && tlsToCreate.length <= tlsToDelete.length;
    if (!options.freeTlsAtLimit || !swapFits || !isFreestyleTlsRuleLimit(err)) throw err;
    const swap = { before: new Set(managedTls.map((rule) => rule.domain)), retiring: tlsToDelete.length };
    const deletions = await Promise.allSettled(tlsToDelete.map((rule) => deleteIgnoringMissing(() => fs.tls.rules.delete(rule.id))));
    const failedDeletion = deletions.find((result) => result.status === "rejected");
    if (failedDeletion) {
      console.error("[freestyle] TLS swap could not retire a rule; rolling back", vmId, failedDeletion.reason);
    }
    // A failed retirement is still the cap's refusal from the user's view.
    throw new TlsSwapStarted(swap, failedDeletion ? err : undefined);
  }
  await inBatches([
    ...firewallToDelete.map((rule) => () => deleteIgnoringMissing(() => fs.firewall.rules.delete(rule.id))),
    ...tlsToDelete.map((rule) => () => deleteIgnoringMissing(() => fs.tls.rules.delete(rule.id))),
  ]);

  return {
    firewallCreated: firewallToCreate.length,
    firewallDeleted: firewallToDelete.length,
    tlsCreated: tlsToCreate.length,
    tlsDeleted: tlsToDelete.length,
  };
}

/** Run calls with bounded concurrency; the first failure rejects after in-flight calls settle. */
async function inBatches(calls: ReadonlyArray<() => Promise<unknown>>, concurrency = 8): Promise<void> {
  for (let start = 0; start < calls.length; start += concurrency) {
    const results = await Promise.allSettled(calls.slice(start, start + concurrency).map((call) => call()));
    const failure = results.find((result) => result.status === "rejected");
    if (failure) throw failure.reason;
  }
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
