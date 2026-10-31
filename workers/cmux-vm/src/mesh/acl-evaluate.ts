/**
 * "Would this connection be allowed?" against a mesh ACL (evaluate_firewall
 * parity, cx-0op). Pure: no store, no provider, no clock. The answer comes
 * from the ACL compiler itself (src/mesh/acl.ts), so it can never disagree
 * with what an apply creates: a device-to-VM path is allowed when the
 * compiled provider rules (tunnel rules, not address rules) cover it, a
 * device-to-device path when the compiled overlay rules do.
 */
import { compileAcl, type AclRuleInput, type CompileInput, type DesiredOverlayRule, type DesiredRule, type MeshProtocol } from "./acl.ts";

export interface EvaluateQuery {
  /** A dev_ id: the side that opens the connection. */
  readonly src: string;
  /** A vm_ or dev_ id. */
  readonly dst: string;
  readonly protocol: MeshProtocol;
  /** The destination port for tcp and udp; null for icmp. */
  readonly port: number | null;
}

const covers = (rule: { readonly protocol: MeshProtocol | null; readonly port: number | null }, query: EvaluateQuery): boolean =>
  rule.protocol === null || (rule.protocol === query.protocol && (rule.port === null || rule.port === query.port));

/** True when the compiled rules allow `query`. */
export const allowedBy = (rules: ReadonlyArray<DesiredRule>, overlayRules: ReadonlyArray<DesiredOverlayRule>, query: EvaluateQuery): boolean =>
  query.dst.startsWith("vm_")
    ? rules.some((rule) => rule.cidr === null && rule.deviceId === query.src && rule.vmId === query.dst && covers(rule, query))
    : overlayRules.some((rule) => rule.sourceDeviceId === query.src && rule.destinationDeviceId === query.dst && covers(rule, query));

/** The rule as the lenient apply sees it: names that left the mesh are dropped; null when nothing is left of a side. */
export const lenientRule = (rule: AclRuleInput, known: ReadonlySet<string>): AclRuleInput | null => {
  const src = rule.src.filter((entry) => entry.endsWith(":*") || known.has(entry));
  const dst = rule.dst.filter((entry) => entry.endsWith(":*") || known.has(entry));
  return src.length === 0 || dst.length === 0 ? null : { src, dst, allow: rule.allow };
};

/**
 * The index (in the stored document) of the first rule that on its own allows
 * `query`, or null. `input` is the compile input of the mesh with the whole
 * document; each rule is compiled alone under the same members.
 */
export const firstAllowingRule = (input: CompileInput, rules: ReadonlyArray<AclRuleInput>, query: EvaluateQuery): number | null => {
  const known = new Set([...input.deviceIds, ...input.vmIds]);
  for (const [index, rule] of rules.entries()) {
    const effective = lenientRule(rule, known);
    if (effective === null) continue;
    const result = compileAcl({ ...input, document: { rules: [effective] }, deviceIpv6: new Map<string, string>(), existingAddressKeys: new Set<string>() });
    if (result.ok && allowedBy(result.rules, result.overlayRules, query)) return index;
  }
  return null;
};
