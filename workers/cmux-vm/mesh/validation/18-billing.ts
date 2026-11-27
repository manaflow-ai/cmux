// Q18: what did the validation runs cost, and can the API key read usage?
// 1) Read-only probes for a usage or billing route on the API (the pinned and
//    live OpenAPI documents list none; the CLI's billing commands use the
//    dashboard API with a Stack session, not the API key).
// 2) Cost from our own ledgers: every VM's allocated seconds (create -> delete,
//    paused time counted as running, so this is an upper bound) times the public
//    per-hour rates, plus an upper bound for transfer from the bytes the scripts
//    moved. Rates: freestyle.sh/docs/vms/pricing-and-limits, read 2026-10-07.
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { api, OUT_DIR, result } from "./lib";

const RATE = { vcpuHour: 0.04032, gibMemHour: 0.0129, gibDiskHour: 0.000086, gbTransfer: 0.02 };
// freestyle/ubuntu-sm, the base every validation VM booted from, when the ledger has no size.
const DEFAULT_SIZE = { vcpus: 2, memGiB: 4, diskGiB: 16 };

const probes: Record<string, number> = {};
for (const path of ["/v5/usage", "/v5/billing", "/v5/account", "/v5/accounts/me", "/v5/limits"]) {
  const r = await api("GET", path, undefined, { allow: [400, 401, 403, 404, 405] });
  probes[path] = r.status;
}

const rows = readdirSync(OUT_DIR)
  .filter((f) => f.startsWith("ledger-"))
  .flatMap((f) => readFileSync(join(OUT_DIR, f), "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)));
const created = new Map<string, any>();
const deleted = new Map<string, any>();
for (const r of rows) (r.op === "create" ? created : deleted).set(r.id, r);
let vmSeconds = 0, vcpuH = 0, memH = 0, diskH = 0, vms = 0;
for (const [id, c] of created) {
  if (c.kind !== "vm") continue;
  vms++;
  const end = deleted.get(id)?.t ?? new Date().toISOString();
  const secs = (Date.parse(end) - Date.parse(c.t)) / 1000;
  let size = DEFAULT_SIZE;
  const m = String(c.note ?? "").match(/\{.*\}/);
  if (m) {
    const res = JSON.parse(m[0]);
    size = { vcpus: res.vcpus ?? res.cpu ?? DEFAULT_SIZE.vcpus, memGiB: (res.memoryMib ?? res.memoryMiB ?? DEFAULT_SIZE.memGiB * 1024) / 1024, diskGiB: (res.storageMib ?? res.diskMib ?? DEFAULT_SIZE.diskGiB * 1024) / 1024 };
  }
  vmSeconds += secs;
  vcpuH += (secs / 3600) * size.vcpus;
  memH += (secs / 3600) * size.memGiB;
  diskH += (secs / 3600) * size.diskGiB;
}
// Transfer upper bound: bytes the scripts moved through the gateway plus the
// VMs' own speed tests and downloads.
let bytes = 0;
for (const f of readdirSync(OUT_DIR).filter((f) => f.startsWith("results-"))) {
  for (const line of readFileSync(join(OUT_DIR, f), "utf8").trim().split("\n").filter(Boolean)) {
    const r = JSON.parse(line);
    if (r.q === "Q10") {
      const g = r.gatewayRawMbit ?? { down: [], up: [], seconds: 10 };
      bytes += 3 * (25e6 + 50e6); // the VM's speed tests
      bytes += [...g.down, ...g.up].reduce((a: number, m: number) => a + (m * 1e6 * g.seconds) / 8, 0);
    }
    if (r.q === "Q12") bytes += Number(r.trafficBytes ?? 0);
    if (r.q === "Q15") bytes += 2 * 15e6;
  }
}
const gb = bytes / 1e9;
const cost = {
  vcpu: vcpuH * RATE.vcpuHour,
  memory: memH * RATE.gibMemHour,
  disk: diskH * RATE.gibDiskHour,
  transferUpperBound: gb * RATE.gbTransfer,
};
const total = Object.values(cost).reduce((a, b) => a + b, 0);
result("Q18", {
  usageRoutesOnApiKey: probes,
  vms,
  vmHours: +(vmSeconds / 3600).toFixed(2),
  vcpuHours: +vcpuH.toFixed(2),
  gibMemHours: +memH.toFixed(2),
  transferGbUpperBound: +gb.toFixed(2),
  costUsd: Object.fromEntries(Object.entries(cost).map(([k, v]) => [k, +v.toFixed(4)])),
  totalUsdUpperBound: +total.toFixed(3),
  note: "list prices before the plan's included usage; VPCs, tunnels and firewall rules have no listed price",
});
