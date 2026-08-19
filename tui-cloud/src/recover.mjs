// Wait for the Freestyle beta API to recover from its outage, then rebuild
// the tui-cloud base snapshot. Safe to re-run; exits 0 when a snapshot exists.
import { spawn } from "node:child_process";
import { client, sleep } from "./client.mjs";

const freestyle = client();
const deadline = Date.now() + 6 * 60 * 60 * 1000; // give up after 6h

async function apiHealthy() {
  try {
    const { vmId } = await freestyle.vms.create({ firewall: { rules: [] } });
    await freestyle.vms.delete(vmId).catch(() => {});
    return true;
  } catch {
    return false;
  }
}

// A usable snapshot may already exist (created after recovery by another run).
async function existingSnapshot() {
  try {
    const { snapshots } = await freestyle.vms.snapshots.list({ limit: 100 });
    return snapshots.find((s) => (s.slug ?? "").startsWith("tui-cloud-base-")) ?? null;
  } catch {
    return null;
  }
}

let attempt = 0;
for (;;) {
  attempt++;
  const snap = await existingSnapshot();
  const healthy = await apiHealthy();
  const t = new Date().toISOString();
  if (healthy) {
    if (snap) {
      console.log(`${t} attempt ${attempt}: API healthy, snapshot ${snap.id} present. Nothing to do.`);
      process.exit(0);
    }
    console.log(`${t} attempt ${attempt}: API healthy, no snapshot. Building...`);
    const child = spawn(process.execPath, [new URL("./build-snapshot.mjs", import.meta.url).pathname], { stdio: "inherit" });
    child.on("exit", (code) => process.exit(code ?? 0));
    await new Promise(() => {}); // wait for child
  }
  console.log(`${t} attempt ${attempt}: API still down (create fails). Sleeping 120s.`);
  if (Date.now() > deadline) {
    console.log("gave up after 6h");
    process.exit(1);
  }
  await sleep(120_000);
}
