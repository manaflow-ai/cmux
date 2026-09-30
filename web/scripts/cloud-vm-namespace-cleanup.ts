/**
 * Delete the Freestyle tunnels and networks one Cloud network namespace owns.
 *
 *   bun scripts/cloud-vm-namespace-cleanup.ts [--namespace <ns>] [--apply]
 *
 * A dev-backend stack (and any other deployment with CMUX_VM_NETWORK_NAMESPACE)
 * creates its provider resources under `cmux-<ns>-net-`, `cmux-<ns>-team-net-`
 * and `cmux-<ns>-wg-` slugs. Run this before removing the stack's database,
 * which is the only record of them. The namespace defaults to the
 * environment's, so running it inside the stack needs no argument.
 *
 * Without --apply it only lists. It never touches production (no namespace),
 * and it deletes no machine: a network that still holds one is reported and
 * kept, so destroy the stack's machines first (`cmux vm rm`).
 */
import { Freestyle, type TunnelData, type VpcData } from "freestyle";
import { vmNetworkNamespace, vmNetworkSlugPrefix } from "../services/vms/config";

type Plan = { readonly tunnels: TunnelData[]; readonly networks: VpcData[] };

function parseArgs(argv: readonly string[]): { namespace: string; apply: boolean } {
  let namespaceArg: string | undefined;
  let apply = false;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--apply") apply = true;
    else if (arg === "--namespace") namespaceArg = argv[++index];
    else throw new Error(`unknown argument ${arg}`);
  }
  const namespace = vmNetworkNamespace({ CMUX_VM_NETWORK_NAMESPACE: namespaceArg ?? process.env.CMUX_VM_NETWORK_NAMESPACE });
  if (!namespace) throw new Error("refusing to run without a namespace: production resources have no namespace prefix");
  return { namespace, apply };
}

async function plan(fs: Freestyle, namespace: string): Promise<Plan> {
  const tunnelPrefix = `${vmNetworkSlugPrefix("wg", namespace)}-`;
  const networkPrefixes = [`${vmNetworkSlugPrefix("net", namespace)}-`, `${vmNetworkSlugPrefix("team-net", namespace)}-`];
  const [{ tunnels }, { vpcs }] = await Promise.all([fs.tunnels.list(), fs.vpc.list()]);
  return {
    tunnels: tunnels.filter((tunnel) => tunnel.slug?.startsWith(tunnelPrefix)),
    networks: vpcs.filter((vpc) => networkPrefixes.some((prefix) => vpc.slug?.startsWith(prefix))),
  };
}

async function main() {
  const { namespace, apply } = parseArgs(process.argv.slice(2));
  const apiKey = process.env.FREESTYLE_API_KEY?.trim();
  if (!apiKey) throw new Error("FREESTYLE_API_KEY is required");
  const fs = new Freestyle({ apiKey, baseUrl: process.env.FREESTYLE_API_URL?.trim() || undefined });
  const found = await plan(fs, namespace);
  const failures: string[] = [];
  if (apply) {
    // Tunnels first: a network with attached tunnels cannot be deleted.
    for (const tunnel of found.tunnels) {
      await fs.tunnels.delete(tunnel.tunnelId ?? tunnel.id).catch((error: unknown) => {
        failures.push(`tunnel ${tunnel.slug}: ${error instanceof Error ? error.message : String(error)}`);
      });
    }
    for (const network of found.networks) {
      await fs.vpc.delete(network.id).catch((error: unknown) => {
        failures.push(`network ${network.slug}: ${error instanceof Error ? error.message : String(error)}`);
      });
    }
  }
  console.log(JSON.stringify({
    namespace,
    applied: apply,
    tunnels: found.tunnels.map((tunnel) => tunnel.slug),
    networks: found.networks.map((network) => ({ slug: network.slug, cidr: network.cidr ?? null })),
    failures,
  }, null, 2));
  if (failures.length > 0) process.exitCode = 1;
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
