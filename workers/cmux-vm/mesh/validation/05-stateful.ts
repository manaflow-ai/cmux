// Q5: is the firewall stateful for replies (TCP and ICMP echo-reply)?
// One VM, one tunnel. A rule only in the tunnel -> VM direction. If replies
// arrive, the firewall is stateful for that flow. Then check that the reverse
// direction (VM opens to the tunnel) is still closed without its own rule.
import { exec, result, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe, ruleTunnelToVm, warm } from "./fixtures";
import { createRule } from "./lib";

await withRun("Q5", async () => {
  const vpc = await meshVpc("q5");
  const vm = await meshVm("q5-vm", vpc.id);
  const t = await meshTunnel("q5-t", vpc);
  const p = await Probe.start("q5", t);
  const dst = `${vm.ip}:8080`;

  const noRuleTcp = await p.tcp(dst, 1500);
  const noRulePing = await p.ping(vm.ip, 3, 1000);

  await ruleTunnelToVm("q5-tcp", t.id, vm.id, 8080);
  const warmMs = await warm(p, dst);
  const echo = await p.echo(dst, "q5");
  const pingBeforeIcmpRule = await p.ping(vm.ip, 3, 1000);
  const vmPingNoIcmpRule = await exec(vm.id, `ping -c 3 -W 1 ${t.attach4} | tail -2`);
  await ruleTunnelToVm("q5-icmp", t.id, vm.id, undefined, "icmp");
  await Bun.sleep(1000);
  const ping = await p.ping(vm.ip, 20, 1000, 0, 50);

  // Reverse: the VM opens a connection to the tunnel client. No rule yet.
  await p.cmd({ op: "listen", port: 7000 }, 5000);
  const vmConnect = (to: string) =>
    exec(vm.id, `timeout 4 python3 -c "import socket;s=socket.create_connection(('${to}',7000),3);s.sendall(b'x\\n');print(s.recv(100).decode().strip())" 2>&1; echo rc=$?`);
  const revNoRule = await vmConnect(t.attach4!);
  const revPingNoRule = await exec(vm.id, `ping -c 3 -W 1 ${t.attach4} | tail -2`);
  await createRule("q5-rev", { vmId: vm.id }, { tunnelId: t.id, port: 7000, protocol: "tcp" });
  await Bun.sleep(1000);
  const revWithRule = await vmConnect(t.attach4!);
  await p.stop();

  result("Q5", {
    tunnelAttach4: t.attach4,
    vmIp: vm.ip,
    noRule: { tcpOk: noRuleTcp.ok, tcpErr: noRuleTcp.err, pingRecv: noRulePing.recv },
    tcpRuleOnly_tunnelToVm: { warmMs, echoOk: echo.ok, reply: echo.reply },
    icmpWithOnlyTcpRule: { recv: pingBeforeIcmpRule.recv, sent: pingBeforeIcmpRule.sent },
    vmPingsTunnel_noIcmpRuleAnyDirection: String(vmPingNoIcmpRule.stdout).trim(),
    icmpRule_tunnelToVm: { sent: ping.sent, recv: ping.recv, rtts: ping.rtts },
    reverseNoRule: { vmToTunnelTcp: String(revNoRule.stdout).trim().split("\n").slice(-2).join(" | "), vmPingTunnel_withOnlyTunnelToVmIcmpRule: String(revPingNoRule.stdout).trim() },
    reverseWithRule: { vmToTunnelTcp: String(revWithRule.stdout).trim(), probeAccepts: p.accepts().map((a) => a.remote) },
  });
});
