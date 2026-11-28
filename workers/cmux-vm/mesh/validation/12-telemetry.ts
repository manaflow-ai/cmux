// Q12: is per-tunnel handshake or byte telemetry available from the API?
// Read every tunnel read path (get, list, list per VPC) before and after a
// handshake plus ~MBs of traffic and diff the field sets and values. Also scan
// the pinned OpenAPI document for any handshake/bytes/lastSeen field on tunnels.
import { api, createRule, result, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe, warm } from "./fixtures";

function flat(o: any, pre = ""): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(o ?? {})) {
    if (k === "clientConfig") continue;
    if (v && typeof v === "object") Object.assign(out, flat(v, `${pre}${k}.`));
    else out[`${pre}${k}`] = String(v);
  }
  return out;
}

await withRun("Q12", async () => {
  const vpc = await meshVpc("q12");
  const vm = await meshVm("q12-vm", vpc.id);
  const t = await meshTunnel("q12-t", vpc);
  await createRule("q12", { tunnelId: t.id }, { vmId: vm.id });
  const read = async () => ({
    get: flat((await api("GET", `/v5/tunnels/${t.id}`)).json),
    vpcList: flat(((await api("GET", `/v5/vpcs/${vpc.id}/tunnels`)).json.tunnels ?? []).find((x: any) => (x.tunnelId ?? x.id) === t.id)),
  });
  const before = await read();
  const p = await Probe.start("q12", t, { keepalive: 25 });
  await warm(p, `${vm.ip}:8080`);
  const tp = await p.cmd({ op: "tput", dst: `${vm.ip}:5201`, dir: "down", seconds: 3 }, 30000);
  const clientStats = await p.stats();
  await Bun.sleep(5000);
  const after = await read();
  await p.stop();
  const diff = (a: Record<string, string>, b: Record<string, string>) =>
    Object.keys({ ...a, ...b }).filter((k) => a[k] !== b[k]).map((k) => `${k}: ${a[k] ?? "-"} -> ${b[k] ?? "-"}`);
  // The live public OpenAPI document (unauthenticated).
  const doc: any = await fetch("https://api.freestyle.sh/openapi.json").then((r) => r.json()).catch(() => null);
  let specHits: string[] = [];
  if (doc) {
    for (const name of ["Tunnel", "TunnelAttachment", "ListTunnelsResponse"]) {
      const props = Object.keys(doc.components.schemas[name]?.properties ?? {});
      specHits.push(`${name}: ${props.filter((p) => /handshake|bytes|rx|tx|seen|online|last/i.test(p)).join(",") || "none"}`);
    }
  }
  result("Q12", {
    tunnelFields: Object.keys(after.get).sort(),
    changedAfterTraffic_get: diff(before.get, after.get),
    changedAfterTraffic_vpcList: diff(before.vpcList, after.vpcList),
    trafficBytes: tp.bytes,
    clientSideStats: { handshakeAgeS: Math.round(Date.now() / 1000 - clientStats.last_handshake_time_sec), rx: clientStats.rx_bytes, tx: clientStats.tx_bytes },
    specTelemetryFields: specHits.length ? specHits : "live spec unavailable",
    specOperations: doc ? Object.values(doc.paths).flatMap((v: any) => Object.values(v).map((o: any) => o.operationId)).length : null,
  });
});
