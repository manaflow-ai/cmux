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
    /**
     * `rollback_complete`: the original rules are back. `rollback_incomplete`:
     * a recreate failed. `rollback_unverified`: the rule list was unreadable,
     * so only definitely-deleted rules were recreated and the rest are left
     * for the next policy apply, which reconciles to the stored policy.
     */
    readonly code: "rollback_complete" | "rollback_incomplete" | "rollback_unverified" = unrestored.length === 0 ? "rollback_complete" : "rollback_incomplete",
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
      return { ...retried, tlsDeleted: retried.tlsDeleted + err.swap.retired.length };
    } catch (retryErr) {
      throw await rollBackTlsSwap(fs, vmId, err.swap, retryErr);
    }
  }
}

/**
 * A swap at the cap: the VM's managed steering domains before it touched
 * anything (the state rollback restores), and how many rules it set out to retire.
 */
type TlsSwap = {
  readonly before: ReadonlySet<string>;
  /** Every domain the swap tried to retire. */
  readonly retired: readonly string[];
  /** Domains whose delete call fulfilled: definitely gone, safe to recreate without a list. */
  readonly removed: readonly string[];
};

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
 * With a readable rule list (one retry), rules the swap added are removed
 * first to free their slots, then every original domain not present is
 * recreated; a delete that removed its rule and still rejected is covered.
 *
 * Freestyle does not reject a duplicate TLS rule: the production account
 * holds two identical `coderouter.dev` rules for one VM
 * (tls-d06dae1f8be348beaa643ef99aa8bc85 and tls-51387d8819a94d8684956549b78569f8,
 * audited 2026-10-09), and neither the SDK types nor docs name a duplicate
 * error. So without a list nothing is created blind: only domains whose
 * delete call fulfilled are recreated, the rest are reported unrestored with
 * `rollback_unverified`, and the next policy apply repairs them.
 */
async function rollBackTlsSwap(fs: Freestyle, vmId: string, swap: TlsSwap, failure: unknown): Promise<unknown> {
  const current = await listManagedTlsWithRetry(fs, vmId);
  let toRecreate: string[];
  let unverified: string[] = [];
  if (current) {
    const added = current.filter((rule) => !swap.before.has(rule.domain));
    const removals = await Promise.allSettled(added.map((rule) => deleteIgnoringMissing(() => fs.tls.rules.delete(rule.id))));
    if (removals.some((result) => result.status === "rejected")) {
      console.error("[freestyle] TLS swap rollback could not remove a rule it added", vmId);
    }
    const present = new Set(current.map((rule) => rule.domain));
    toRecreate = [...swap.before].filter((domain) => !present.has(domain));
  } else {
    toRecreate = [...swap.removed];
    const removed = new Set(swap.removed);
    unverified = swap.retired.filter((domain) => !removed.has(domain));
  }
  const results = await Promise.allSettled(toRecreate.map((domain) =>
    fs.tls.rules.create({ action: "allow", domain, source: { vmId }, destination: { public: true } })));
  const failed = toRecreate.filter((_, index) => results[index]?.status === "rejected");
  const restored = toRecreate.length - failed.length;
  const unrestored = [...failed, ...unverified];
  if (unrestored.length > 0) {
    console.error("[freestyle] TLS swap rollback incomplete", JSON.stringify({ vmId, unrestored, listed: current !== null }));
  }
  if (!isFreestyleTlsRuleLimit(failure)) return failure;
  const code = !current && unverified.length > 0 ? "rollback_unverified" : failed.length > 0 ? "rollback_incomplete" : "rollback_complete";
  return new FreestyleTlsRuleLimitRestoreError(restored, unrestored, failure, code);
}

/** The VM's managed steering rules, read with one retry; null when the list stays unreadable. */
async function listManagedTlsWithRetry(fs: Freestyle, vmId: string): Promise<TlsRule[] | null> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      return (await fs.tls.rules.list({ vmId, limit: 1000 })).rules.filter((rule) => isManagedTlsRule(rule, vmId));
    } catch (listErr) {
      console.error("[freestyle] TLS swap rollback could not list the VM's rules", vmId, listErr);
    }
  }
  return null;
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
    const deletions = await Promise.allSettled(tlsToDelete.map((rule) => deleteIgnoringMissing(() => fs.tls.rules.delete(rule.id))));
    const swap = {
      before: new Set(managedTls.map((rule) => rule.domain)),
      retired: tlsToDelete.map((rule) => rule.domain),
      removed: tlsToDelete.filter((_, index) => deletions[index]?.status === "fulfilled").map((rule) => rule.domain),
    };
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
