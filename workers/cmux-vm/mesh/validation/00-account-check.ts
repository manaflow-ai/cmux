// Q0: is the dev key on the same Freestyle account as production?
// Read-only. The API has no whoami; list_identities -> describe_identity returns
// accountId. Fallback: compare snapshot id sets (list_snapshots is per account).
// Prints only account ids or "same"/"different". Never a key.
import { api, keyFrom, KEY_FILE, result } from "./lib";

const PROD_FILE = process.env.MESH_PROD_KEY_FILE ?? `${process.env.HOME}/.secrets/freestyle-beta.env`;

async function accountOf(k: string) {
  const ids = await api("GET", "/v5/identities?limit=5", undefined, { key: k });
  const first = (ids.json.identities ?? [])[0];
  let accountId: string | undefined;
  if (first) {
    const d = await api("GET", `/v5/identities/${first.id}`, undefined, { key: k });
    accountId = d.json.accountId;
  }
  const snaps = await api("GET", "/v5/snapshots?limit=200", undefined, { key: k });
  const snapIds = new Set<string>((snaps.json.snapshots ?? snaps.json.items ?? []).map((s: any) => s.id ?? s.snapshotId));
  const vpcs = await api("GET", "/v5/vpcs?limit=1", undefined, { key: k });
  return { accountId, identities: ids.json.total, snapIds, vpcTotal: vpcs.json.total };
}

const dev = await accountOf(keyFrom(KEY_FILE));
const prod = await accountOf(keyFrom(PROD_FILE));
const overlap = [...dev.snapIds].filter((s) => prod.snapIds.has(s)).length;
const byAccount = dev.accountId && prod.accountId ? (dev.accountId === prod.accountId ? "same" : "different") : "unknown";
const bySnapshots = dev.snapIds.size + prod.snapIds.size === 0 ? "unknown" : overlap > 0 ? "same" : "different";
result("Q0", {
  devAccountId: dev.accountId ?? null,
  prodAccountId: prod.accountId ?? null,
  byAccountId: byAccount,
  bySnapshotOverlap: bySnapshots,
  devSnapshots: dev.snapIds.size,
  prodSnapshots: prod.snapIds.size,
  sharedSnapshots: overlap,
  devVpcTotal: dev.vpcTotal,
  prodVpcTotal: prod.vpcTotal,
  verdict: byAccount !== "unknown" ? byAccount : bySnapshots,
});
