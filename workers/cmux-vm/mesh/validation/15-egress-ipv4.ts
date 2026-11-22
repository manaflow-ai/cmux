// Q15: when is egressIpv4 set, and can a VM reach IPv4-only hosts (github.com)?
// VM A: no firewall rules. VM B: egress {public: true}. Neither is on a VPC.
// Read egressIpv4/egressIpv6/publicIpv6 at create and when running, then from
// inside: observed IPv4/IPv6 egress, a GitHub release asset download, and
// `git ls-remote https://github.com/...` (github.com has no AAAA record).
import { api, createVm, exec, result, waitRunning, withRun } from "./lib";

const CMDS = String.raw`
echo "dns_github: $(getent ahosts github.com | awk '{print $1}' | sort -u | tr '\n' ' ')"
echo "v4: $(curl -4 -s -m 8 https://api.ipify.org || echo fail)"
echo "v6: $(curl -6 -s -m 8 https://api6.ipify.org || echo fail)"
echo "geo: $(curl -s -m 8 https://ipinfo.io/json | tr -d '\n ' | head -c 300)"
echo "asset: $(curl -sSL -m 60 -o /dev/null -w '%{http_code} %{size_download}B %{time_total}s via %{remote_ip}' https://github.com/cli/cli/releases/download/v2.63.0/gh_2.63.0_linux_amd64.tar.gz 2>&1)"
s=$(date +%s%N); out=$(timeout 30 git ls-remote https://github.com/manaflow-ai/cmux HEAD 2>&1 | head -c 120); e=$(date +%s%N)
echo "lsremote: $(( (e-s)/1000000 ))ms $out"
`;

const pick = (vm: any) => ({ egressIpv4: vm.egressIpv4 ?? null, egressIpv6: vm.egressIpv6 ?? null, publicIpv6: vm.publicIpv6 ?? null, state: vm.state });

await withRun("Q15", async () => {
  const a = await createVm("q15-noegress", { firewall: { rules: [] } });
  const b = await createVm("q15-egress", { firewall: { rules: [{ action: "allow", source: {}, destination: { public: true } }] } });
  const aRun = await waitRunning(a.id);
  const bRun = await waitRunning(b.id);
  const ra = await exec(a.id, CMDS, 150_000);
  const rb = await exec(b.id, CMDS, 150_000);
  const lines = (r: any) => String(r.stdout ?? "").trim().split("\n");
  const list = await api("GET", `/v5/vms/${b.id}`);
  result("Q15", {
    noEgressRule: { atCreate: pick(a), running: pick(aRun), inside: lines(ra) },
    egressPublicRule: { atCreate: pick(b), running: pick(bRun), afterExec: pick(list.json), inside: lines(rb) },
  });
});
