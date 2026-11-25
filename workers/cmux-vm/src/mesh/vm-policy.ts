import { peersOf, type DesiredRule, type MeshProtocol } from "./acl.ts";

/** Service grants only: public address rules permit the outer transport, not VM services. */
export const projectVmPeers = (
  deviceId: string,
  members: ReadonlyArray<{ readonly vmId: string; readonly ipv4: string | null }>,
  rules: ReadonlyArray<DesiredRule>,
) => {
  const addresses = new Map(members.map((member) => [member.vmId, member.ipv4]));
  return [...peersOf(deviceId, rules)]
    .filter(([vmId]) => addresses.has(vmId))
    .sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
    .map(([vmId, allowed]) => ({
      kind: "vm" as const,
      id: vmId,
      address: addresses.get(vmId) ?? null,
      allow: allowed.map((rule): { readonly protocol: MeshProtocol | "any"; readonly port?: number } =>
        rule.protocol === null ? { protocol: "any" } : rule.port === null ? { protocol: rule.protocol } : { protocol: rule.protocol, port: rule.port },
      ),
    }));
};
