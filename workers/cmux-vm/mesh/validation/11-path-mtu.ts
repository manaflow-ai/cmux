// Q11: path MTU through the gateway.
// VM side: `ping -M do` (DF set) to the tunnel attachment address, binary search
// on payload size, plus the guest interface MTU and tracepath.
// Client side: wgprobe with an inner MTU of 1500 (so the client never fragments
// inner packets), binary search on ICMP payload size to the VM.
// Also: the tunnel's clientConfig MTU.
import { createRule, exec, result, withRun } from "./lib";
import { fromTunnel, meshTunnel, meshVm, meshVpc, Probe } from "./fixtures";

await withRun("Q11", async () => {
  const vpc = await meshVpc("q11");
  const vm = await meshVm("q11-vm", vpc.id);
  const t = await meshTunnel("q11-t", vpc);
  await createRule("q11-in", { tunnelId: t.id }, { vmId: vm.id, protocol: "icmp" });
  await createRule("q11-out", { vmId: vm.id }, { tunnelId: t.id, protocol: "icmp" });
  const cfgMtu = String(t.raw.clientConfig).match(/^\s*MTU\s*=\s*(\d+)/m)?.[1] ?? "absent";
  const p = await Probe.start("q11", t, { keepalive: 25, mtu: 1500 });
  for (let i = 0; i < 10 && (await p.ping(vm.ip, 1, 1000)).recv === 0; i++);

  // client -> VM, inner MTU 1500 (no inner fragmentation below 1472 payload)
  const ok = async (size: number) => (await p.ping(vm.ip, 2, 1000, size)).recv > 0;
  let lo = 0, hi = 1472;
  if (await ok(hi)) lo = hi;
  else {
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (await ok(mid)) lo = mid;
      else hi = mid;
    }
  }
  const clientMaxPayload = lo;
  await p.stop();
  // client with the default inner MTU 1280: payloads above 1252 are fragmented by the client
  const p2 = await Probe.start("q11b", fromTunnel(t.raw, t.kp), { keepalive: 25, mtu: 1280 });
  for (let i = 0; i < 10 && (await p2.ping(vm.ip, 1, 1000)).recv === 0; i++);
  const frag = { "1252": (await p2.ping(vm.ip, 3, 1000, 1252)).recv, "1400": (await p2.ping(vm.ip, 3, 1000, 1400)).recv, "3000": (await p2.ping(vm.ip, 3, 1000, 3000)).recv };

  // VM -> attachment, DF set
  const vmSide = await exec(
    vm.id,
    `ip -o link | awk '{print $2, $4, $5}'; lo=0; hi=1472; while [ $((hi-lo)) -gt 1 ]; do mid=$(((lo+hi)/2)); if ping -M do -c 2 -W 1 -s $mid ${t.attach4} >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi; done; if ping -M do -c 2 -W 1 -s 1472 ${t.attach4} >/dev/null 2>&1; then lo=1472; fi; echo maxpayload=$lo; ping -M do -c 1 -W 1 -s $((lo+1)) ${t.attach4} 2>&1 | grep -iE 'mtu|frag|100%' | head -2; (command -v tracepath >/dev/null && tracepath -n ${t.attach4} 2>&1 | tail -3) || echo no-tracepath`,
    180_000,
  );
  await p2.stop();
  const vmOut = String(vmSide.stdout ?? "");
  const vmMax = Number(vmOut.match(/maxpayload=(\d+)/)?.[1] ?? NaN);
  result("Q11", {
    clientConfigMtu: cfgMtu,
    clientToVm_maxIcmpPayload_innerMtu1500: clientMaxPayload,
    clientToVm_maxInnerPacket: clientMaxPayload + 28,
    clientInnerFragmented_recvOf3: frag,
    vmToTunnel_DF_maxIcmpPayload: vmMax,
    vmToTunnel_DF_maxPacket: vmMax + 28,
    vmInterfaces: vmOut.split("\n").filter((l) => /mtu/.test(l)).slice(0, 6),
    vmDetail: vmOut.split("\n").filter((l) => !/mtu \d+/.test(l) || /Frag|frag|pmtu/.test(l)).slice(-6),
  });
});
