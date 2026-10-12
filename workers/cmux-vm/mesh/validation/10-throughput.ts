// Q10: single-stream TCP throughput through the gateway, and the direct path.
// Through the gateway: wgprobe (userspace WireGuard on this host) <-> VM sink,
// 10 s per run, 3 runs each direction. Direct: there is no direct path between
// this host and the VM (this host has no IPv6 and sits behind NAT; the VM has
// no inbound IPv4), so each end's own direct single-stream capacity to the
// same public endpoint (speed.cloudflare.com) is the baseline.
import { createRule, exec, result, summary, withRun } from "./lib";
import { meshTunnel, meshVm, meshVpc, Probe, warm } from "./fixtures";

const RUNS = Number(process.env.MESH_Q10_RUNS ?? 3);
const SECS = 10;

async function localCurl(args: string[]) {
  const p = Bun.spawn(["curl", "-s", "-o", "/dev/null", ...args], { stdout: "pipe", stderr: "pipe" });
  return (await new Response(p.stdout).text()).trim();
}

await withRun("Q10", async () => {
  const vpc = await meshVpc("q10");
  const vm = await meshVm("q10-vm", vpc.id);
  const t = await meshTunnel("q10-t", vpc);
  await createRule("q10", { tunnelId: t.id }, { vmId: vm.id });
  const p = await Probe.start("q10", t, { keepalive: 25 });
  await warm(p, `${vm.ip}:8080`);
  const rtt = await p.ping(vm.ip, 20, 1000, 0, 50);
  const down: number[] = [], up: number[] = [];
  for (let i = 0; i < RUNS; i++) {
    down.push((await p.cmd({ op: "tput", dst: `${vm.ip}:5201`, dir: "down", seconds: SECS }, 60000)).mbps);
    up.push((await p.cmd({ op: "tput", dst: `${vm.ip}:5201`, dir: "up", seconds: SECS }, 60000)).mbps);
  }
  // The VM's own direct path (25 MB down, 50 MB up), 3 runs each.
  const vmDirect = await exec(
    vm.id,
    `for i in 1 2 3; do curl -s -o /dev/null -w 'down %{speed_download}\\n' 'https://speed.cloudflare.com/__down?bytes=25000000'; done; head -c 50000000 /dev/zero > /tmp/z; for i in 1 2 3; do curl -s -o /dev/null -w 'up %{speed_upload}\\n' --data-binary @/tmp/z https://speed.cloudflare.com/__up; done; curl -s -o /dev/null -w 'rtt %{time_connect}\\n' https://speed.cloudflare.com/`,
    180_000,
  );
  const parse = (txt: string, k: string) => txt.split("\n").filter((l) => l.startsWith(k)).map((l) => (Number(l.split(" ")[1]) * 8) / 1e6);
  const vmD = parse(String(vmDirect.stdout ?? ""), "down");
  const vmU = parse(String(vmDirect.stdout ?? ""), "up");
  const hostD: number[] = [], hostU: number[] = [];
  for (let i = 0; i < 3; i++) hostD.push((Number(await localCurl(["-w", "%{speed_download}", "https://speed.cloudflare.com/__down?bytes=25000000"])) * 8) / 1e6);
  await Bun.write(`${import.meta.dir}/out/z50m`, new Uint8Array(50_000_000));
  for (let i = 0; i < 3; i++) hostU.push((Number(await localCurl(["-w", "%{speed_upload}", "--data-binary", `@${import.meta.dir}/out/z50m`, "https://speed.cloudflare.com/__up"])) * 8) / 1e6);
  (await import("node:fs")).rmSync(`${import.meta.dir}/out/z50m`, { force: true });
  await p.stop();
  result("Q10", {
    tunnelRttMs: summary(rtt.rtts),
    gatewayRawMbit: { down, up, seconds: SECS },
    gatewayDownMbit: summary(down, ""),
    gatewayUpMbit: summary(up, ""),
    vmDirectCloudflareDownMbit: summary(vmD, ""),
    vmDirectCloudflareUpMbit: summary(vmU, ""),
    hostDirectCloudflareDownMbit: summary(hostD, ""),
    hostDirectCloudflareUpMbit: summary(hostU, ""),
    vmCloudflareConnect: String(vmDirect.stdout ?? "").split("\n").find((l) => l.startsWith("rtt")),
    client: "wgprobe userspace (wireguard-go + gVisor netstack) on cmux-lawrence-2, MTU 1280",
  });
});
