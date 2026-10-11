// Q3: firewall rule limit, and the create/delete rate.
// SAFETY: the dev key shares the production account (00-account-check.ts), and the
// limit is account-wide, so this never pushes to the 409. It creates at most
// MESH_Q3_MAX rules (default 300, hard cap 300) on ONE throwaway VPC and deletes
// them all by exact id. A 409 before the cap is recorded as the limit.
import { api, createRule, createVpc, del, pct, result, setAllowManyRules, summary, withRun } from "./lib";

const MAX = Math.min(300, Number(process.env.MESH_Q3_MAX ?? 300));
const CONC = 8;

await withRun("Q3", async () => {
  setAllowManyRules(true);
  const vpc = await createVpc("q3");
  const ids: string[] = [];
  const createMs: number[] = [];
  let conflict: any = null;
  const t0 = performance.now();
  for (let i = 0; i < MAX && !conflict; i += CONC) {
    const batch = Array.from({ length: Math.min(CONC, MAX - i) }, (_, k) => i + k);
    const rs = await Promise.all(
      batch.map((n) => createRule(`q3-${n}`, { vpcId: vpc.id }, { vpcId: vpc.id, port: 20000 + n, protocol: "tcp" }, { allow: [409] })),
    );
    for (const r of rs) {
      if (r._status === 409) conflict = r._error;
      else {
        ids.push(r.id);
        createMs.push(r._ms);
      }
    }
  }
  const createWall = (performance.now() - t0) / 1000;
  const listed = await api("GET", `/v5/firewall/rules?vpcId=${vpc.id}&limit=1000`);
  const listedCount = (listed.json.rules ?? []).length;
  const t1 = performance.now();
  const deleteMs: number[] = [];
  for (let i = 0; i < ids.length; i += CONC) {
    const rs = await Promise.all(ids.slice(i, i + CONC).map((id) => del("rule", id)));
    rs.forEach((r) => deleteMs.push(r.ms));
  }
  const deleteWall = (performance.now() - t1) / 1000;
  result("Q3", {
    created: ids.length,
    limit: conflict ? `409 after ${ids.length} rules created by this run` : `>= ${ids.length} (not pushed: shared account)`,
    conflict,
    listedOnVpc: listedCount,
    listLatencyMs: Math.round(listed.ms),
    concurrency: CONC,
    createRatePerSec: +(ids.length / createWall).toFixed(1),
    createLatency: summary(createMs),
    deleteRatePerSec: +(ids.length / deleteWall).toFixed(1),
    deleteLatency: summary(deleteMs),
    createP99: pct(createMs, 99),
  });
});
