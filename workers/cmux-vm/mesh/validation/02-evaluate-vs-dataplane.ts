// Q2: does evaluate_firewall agree with the data plane?
// Each case: ask POST /v5/firewall/evaluate, then probe the real path.
// A TCP "refused" means the packet reached the host (allowed); a timeout means a drop.
import { api, createRule, exec, result, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe, warm } from "./fixtures";

await withRun("Q2", async () => {
  const vpc = await meshVpc("q2");
  const vm1 = await meshVm("q2-vm1", vpc.id);
  const vm2 = await meshVm("q2-vm2", vpc.id);
  const ta = await meshTunnel("q2-a", vpc);
  const tb = await meshTunnel("q2-b", vpc);
  await createRule("q2-a-vm1-8080", { tunnelId: ta.id }, { vmId: vm1.id, port: 8080, protocol: "tcp" });
  await createRule("q2-a-b-7000", { tunnelId: ta.id }, { tunnelId: tb.id, port: 7000, protocol: "tcp" });
  await createRule("q2-vm1-vm2-8080", { vmId: vm1.id }, { vmId: vm2.id, port: 8080, protocol: "tcp" });
  const a = await Probe.start("q2a", ta, { keepalive: 25 });
  const b = await Probe.start("q2b", tb, { keepalive: 25 });
  await b.cmd({ op: "listen", port: 7000 }, 5000);
  await a.cmd({ op: "listen", port: 7000 }, 5000);
  await warm(a, `${vm1.ip}:8080`);

  const party = {
    a: (port?: number) => ({ tunnelId: ta.id, address: ta.attach4, vpcIds: [vpc.id], ...(port ? { port } : {}) }),
    b: (port?: number) => ({ tunnelId: tb.id, address: tb.attach4, vpcIds: [vpc.id], ...(port ? { port } : {}) }),
    vm1: (port?: number) => ({ vmId: vm1.id, address: vm1.ip, vpcIds: [vpc.id], ...(port ? { port } : {}) }),
    vm2: (port?: number) => ({ vmId: vm2.id, address: vm2.ip, vpcIds: [vpc.id], ...(port ? { port } : {}) }),
    pub: (addr: string, port: number) => ({ address: addr, public: true, port }),
  };
  const evaluate = async (source: any, destination: any, protocol = "tcp") => {
    const r = await api("POST", "/v5/firewall/evaluate", { source, destination, protocol }, { allow: [400, 422] });
    return r.status === 200 ? r.json.outcome + (r.json.reason ? `:${r.json.reason}` : "") : `HTTP ${r.status} ${r.text.slice(0, 120)}`;
  };
  const vmTcp = async (vmId: string, host: string, port: number) => {
    const r = await exec(vmId, `timeout 5 python3 -c "
import socket,sys
s=socket.socket(socket.AF_INET6 if ':' in '${host}' else socket.AF_INET); s.settimeout(3)
try:
  s.connect(('${host}',${port})); print('connected')
except ConnectionRefusedError: print('refused')
except Exception as e: print('drop:'+type(e).__name__)
"`);
    return String(r.stdout ?? "").trim() || `exec ${r._status}`;
  };
  const probeTcp = async (p: Probe, dst: string) => {
    const r = await p.tcp(dst, 2000);
    return r.ok ? "connected" : String(r.err).includes("refused") ? "refused" : `drop:${r.err}`;
  };

  const cases: any[] = [];
  const add = async (name: string, ev: Promise<string>, dp: Promise<string>) => cases.push({ name, evaluate: await ev, dataPlane: await dp });

  await add("tunnel A -> vm1 tcp 8080 (rule)", evaluate(party.a(), party.vm1(8080)), probeTcp(a, `${vm1.ip}:8080`));
  await add("tunnel A -> vm1 tcp 9 (no rule for port)", evaluate(party.a(), party.vm1(9)), probeTcp(a, `${vm1.ip}:9`));
  await add("tunnel B -> vm1 tcp 8080 (no rule)", evaluate(party.b(), party.vm1(8080)), probeTcp(b, `${vm1.ip}:8080`));
  await add("tunnel A -> tunnel B tcp 7000 (rule)", evaluate(party.a(), party.b(7000)), probeTcp(a, `${tb.attach4}:7000`));
  await add("tunnel B -> tunnel A tcp 7000 (no rule)", evaluate(party.b(), party.a(7000)), probeTcp(b, `${ta.attach4}:7000`));
  await add("vm1 -> tunnel A tcp 7000 (no rule)", evaluate(party.vm1(), party.a(7000)), vmTcp(vm1.id, ta.attach4!, 7000));
  await add("vm1 -> vm2 tcp 8080 (rule)", evaluate(party.vm1(), party.vm2(8080)), vmTcp(vm1.id, vm2.ip, 8080));
  await add("vm2 -> vm1 tcp 8080 (no rule)", evaluate(party.vm2(), party.vm1(8080)), vmTcp(vm2.id, vm1.ip, 8080));
  await add("vm1 -> public 1.1.1.1 tcp 443 (egress rule)", evaluate(party.vm1(), party.pub("1.1.1.1", 443)), vmTcp(vm1.id, "1.1.1.1", 443));
  await add("vm1 -> public 1.1.1.1 tcp 25 (platform block)", evaluate(party.vm1(), party.pub("1.1.1.1", 25)), vmTcp(vm1.id, "1.1.1.1", 25));
  await a.stop();
  await b.stop();
  const agree = (c: any) => (c.evaluate.startsWith("allowed") ? c.dataPlane === "connected" || c.dataPlane === "refused" : c.dataPlane.startsWith("drop"));
  result("Q2", { cases: cases.map((c) => ({ ...c, agree: agree(c) })), disagreements: cases.filter((c) => !agree(c)).length, total: cases.length });
});
