/**
 * The mesh ACL compiler (M1 subset of the network policy shape, DESIGN.md
 * section 4.2). Pure: no store, no provider, no clock.
 *
 * A document is a list of allow rules, default deny:
 *   { "src": ["dev_..." | "device:*"], "dst": ["vm_..." | "vm:*"], "allow": ["tcp:8080", "udp:53", "tcp:*", "icmp", "*"] }
 * Each (device, VM, port) becomes one provider rule `{tunnel} -> {vm, protocol, port}`
 * (the provider takes one port per rule). Device-to-device and VM-to-device
 * rules do not exist in M1: the provider does not forward tunnel to tunnel
 * (DESIGN.md 1.4 Q1), and replies to a device's connection are stateful (Q5).
 */

export type MeshProtocol = "tcp" | "udp" | "icmp";

export interface AclRuleInput {
  readonly src: ReadonlyArray<string>;
  readonly dst: ReadonlyArray<string>;
  readonly allow: ReadonlyArray<string>;
}

export interface AclDocument {
  readonly rules: ReadonlyArray<AclRuleInput>;
}

/** One allowed path. `protocol` null means every protocol (then `port` is null too). */
export interface DesiredRule {
  /** Canonical key; equal keys are the same provider rule. */
  readonly key: string;
  readonly deviceId: string;
  readonly vmId: string;
  readonly protocol: MeshProtocol | null;
  readonly port: number | null;
}

export interface CompileInput {
  readonly document: AclDocument;
  /** Live devices of this mesh. */
  readonly deviceIds: ReadonlyArray<string>;
  /** VMs that are members of this mesh. */
  readonly vmIds: ReadonlyArray<string>;
  readonly rulesPerResource: number;
  readonly rulesPerMesh: number;
}

export type CompileResult =
  | { readonly ok: true; readonly rules: ReadonlyArray<DesiredRule> }
  | { readonly ok: false; readonly reason: "invalid"; readonly message: string }
  | { readonly ok: false; readonly reason: "perResource"; readonly message: string; readonly resourceId: string; readonly count: number }
  | { readonly ok: false; readonly reason: "perMesh"; readonly message: string; readonly count: number };

interface PortSpec {
  readonly protocol: MeshProtocol | null;
  readonly port: number | null;
}

/** Parses one `allow` entry; null when malformed. */
export const parseAllow = (entry: string): PortSpec | null => {
  if (entry === "*") return { protocol: null, port: null };
  if (entry === "icmp") return { protocol: "icmp", port: null };
  const match = /^(tcp|udp):(\*|[0-9]{1,5})$/u.exec(entry);
  if (match === null) return null;
  const protocol = match[1] === "tcp" ? "tcp" : "udp";
  if (match[2] === "*") return { protocol, port: null };
  const port = Number(match[2]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  return { protocol, port };
};

export const ruleKey = (deviceId: string, vmId: string, spec: PortSpec): string =>
  `${deviceId}>${vmId}:${spec.protocol ?? "any"}:${spec.port ?? "*"}`;

const expand = (selectors: ReadonlyArray<string>, wildcard: string, prefix: string, members: ReadonlyArray<string>, side: string) => {
  const memberSet = new Set(members);
  const out = new Set<string>();
  for (const selector of selectors) {
    if (selector === wildcard) {
      for (const member of members) out.add(member);
      continue;
    }
    if (!selector.startsWith(prefix)) return { ok: false as const, message: `${side} entry ${JSON.stringify(selector)} must be ${wildcard} or a ${prefix} id` };
    if (!memberSet.has(selector)) return { ok: false as const, message: `${side} ${selector} is not a member of this mesh` };
    out.add(selector);
  }
  return { ok: true as const, ids: [...out] };
};

export const compileAcl = (input: CompileInput): CompileResult => {
  const byKey = new Map<string, DesiredRule>();
  for (const [index, rule] of input.document.rules.entries()) {
    const sources = expand(rule.src, "device:*", "dev_", input.deviceIds, `rules[${index}].src`);
    if (!sources.ok) return { ok: false, reason: "invalid", message: sources.message };
    const destinations = expand(rule.dst, "vm:*", "vm_", input.vmIds, `rules[${index}].dst`);
    if (!destinations.ok) return { ok: false, reason: "invalid", message: destinations.message };
    const specs: PortSpec[] = [];
    for (const entry of rule.allow) {
      const spec = parseAllow(entry);
      if (spec === null) return { ok: false, reason: "invalid", message: `rules[${index}].allow entry ${JSON.stringify(entry)} is not tcp:<port>, udp:<port>, tcp:*, udp:*, icmp or *` };
      specs.push(spec);
    }
    for (const deviceId of sources.ids) {
      for (const vmId of destinations.ids) {
        for (const spec of specs) {
          const key = ruleKey(deviceId, vmId, spec);
          byKey.set(key, { key, deviceId, vmId, protocol: spec.protocol, port: spec.port });
        }
      }
    }
  }
  const rules = [...byKey.values()].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));
  const perResource = new Map<string, number>();
  for (const rule of rules) {
    perResource.set(rule.deviceId, (perResource.get(rule.deviceId) ?? 0) + 1);
    perResource.set(rule.vmId, (perResource.get(rule.vmId) ?? 0) + 1);
  }
  for (const [resourceId, count] of perResource) {
    if (count > input.rulesPerResource) {
      return {
        ok: false,
        reason: "perResource",
        resourceId,
        count,
        message: `This policy puts ${count} firewall rules on ${resourceId}; the limit is ${input.rulesPerResource}`,
      };
    }
  }
  if (rules.length > input.rulesPerMesh) {
    return {
      ok: false,
      reason: "perMesh",
      count: rules.length,
      message: `This policy compiles to ${rules.length} firewall rules; the mesh limit is ${input.rulesPerMesh}`,
    };
  }
  return { ok: true, rules };
};

/** Splits current rules (by key) against desired ones: create these, then delete those. */
export const planApply = <T extends { readonly key: string }>(
  current: ReadonlyArray<T>,
  desired: ReadonlyArray<DesiredRule>,
): { readonly create: ReadonlyArray<DesiredRule>; readonly remove: ReadonlyArray<T> } => {
  const desiredKeys = new Set(desired.map((rule) => rule.key));
  const currentKeys = new Set(current.map((rule) => rule.key));
  return {
    create: desired.filter((rule) => !currentKeys.has(rule.key)),
    remove: current.filter((rule) => !desiredKeys.has(rule.key)),
  };
};

/** What one device may reach, grouped by VM. */
export const peersOf = (deviceId: string, rules: ReadonlyArray<DesiredRule>): ReadonlyMap<string, ReadonlyArray<DesiredRule>> => {
  const out = new Map<string, DesiredRule[]>();
  for (const rule of rules) {
    if (rule.deviceId !== deviceId) continue;
    const list = out.get(rule.vmId) ?? [];
    list.push(rule);
    out.set(rule.vmId, list);
  }
  return out;
};
