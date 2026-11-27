// Cleanup proof: GET every id in every ledger by exact id and expect 404.
// Anything not 404 is deleted by exact id (never listed) and re-checked.
// Usage: bun verify-gone.ts            (all ledgers in out/)
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { api, cleanup, OUT_DIR, type Kind } from "./lib";

const PATH: Record<Kind, (id: string) => string> = {
  rule: (id) => `/v5/firewall/rules/${id}`,
  tunnel: (id) => `/v5/tunnels/${id}`,
  vm: (id) => `/v5/vms/${id}`,
  vpc: (id) => `/v5/vpcs/${id}`,
  identity: (id) => `/v5/identities/${id}`,
};
const ids = new Map<string, Kind>();
for (const f of readdirSync(OUT_DIR).filter((f) => f.startsWith("ledger-"))) {
  for (const l of readFileSync(join(OUT_DIR, f), "utf8").trim().split("\n").filter(Boolean)) {
    const r = JSON.parse(l);
    if (r.op === "create") ids.set(r.id, r.kind);
  }
}
const proof: string[] = [];
const check = async () => {
  proof.length = 0;
  const left = new Map<string, Kind>();
  const counts: Record<string, number> = {};
  const all = [...ids];
  for (let i = 0; i < all.length; i += 16) {
    await Promise.all(
      all.slice(i, i + 16).map(async ([id, kind]) => {
        const r = await api("GET", PATH[kind](id), undefined, { allow: [404] });
        counts[`${kind}:${r.status}`] = (counts[`${kind}:${r.status}`] ?? 0) + 1;
        proof.push(JSON.stringify({ kind, id, status: r.status, at: new Date().toISOString() }));
        if (r.status !== 404) left.set(id, kind);
      }),
    );
  }
  return { left, counts };
};
let { left, counts } = await check();
let repaired: string[] = [];
if (left.size) {
  repaired = await cleanup(left);
  ({ left, counts } = await check());
}
writeFileSync(join(OUT_DIR, "cleanup-proof.jsonl"), proof.sort().join("\n") + "\n");
console.log(JSON.stringify({ q: "cleanup", ledgerIds: ids.size, counts, repaired, leftovers: [...left.keys()] }));
