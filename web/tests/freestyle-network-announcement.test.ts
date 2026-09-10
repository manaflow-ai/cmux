import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { Effect } from "effect";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { announceFreestyleNetwork, freestyleNetworkAnnouncementCommand } from "../services/vms/drivers/freestyleNetworkAnnouncement";

function captureAnnouncements(addresses: string[], failingFamily = "") {
  const directory = mkdtempSync(join(tmpdir(), "cmux-network-test-"));
  const capture = join(directory, "packets.json");
  // Execute the shipped guest command with only its OS boundary substituted.
  // No raw socket, subprocess, or host network operation can escape this fixture.
  writeFileSync(join(directory, "sitecustomize.py"), `import atexit,json,os,socket,subprocess
packets=[]
class Socket:
    def __init__(self,*args): self.bound=None; self.options=[]
    def __enter__(self): return self
    def __exit__(self,*args): pass
    def bind(self,value): self.bound=value
    def setsockopt(self,*args): self.options.append(args)
    def send(self,packet):
        if os.environ['FAILING_FAMILY'] in ['ipv4','both']: raise OSError('IPv4 unavailable')
        packets.append(dict(bound=self.bound,packet=packet.hex(),options=self.options))
    def sendto(self,packet,target):
        if os.environ['FAILING_FAMILY'] in ['ipv6','both']: raise OSError('IPv6 unavailable')
        packets.append(dict(bound=self.bound,packet=packet.hex(),target=target,options=self.options))
socket.socket=Socket
socket.AF_PACKET=17
links=[dict(ifname='eth0.181',ifindex=8,link_type='ether',flags=['UP'],address='02:00:0a:10:00:02',addr_info=[dict(local='10.16.0.2'),dict(local='fd00::2'),dict(local='fe80::2')])]
subprocess.check_output=lambda *args,**kwargs: json.dumps(links).encode()
atexit.register(lambda: open(os.environ['CAPTURE_PATH'],'w').write(json.dumps(packets)))
`);
  try {
    const result = spawnSync("/bin/sh", ["-c", freestyleNetworkAnnouncementCommand(addresses)], {
      env: { ...process.env, PYTHONPATH: directory, CAPTURE_PATH: capture, FAILING_FAMILY: failingFamily }, encoding: "utf8",
    });
    return { status: result.status, packets: JSON.parse(readFileSync(capture, "utf8")) as Array<{
      bound: Array<string | number>; packet: string; target?: Array<string | number>; options: number[][];
    }> };
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

describe("Freestyle private network readiness", () => {
  test.each([
    { operation: "create", hasAddresses: true },
    { operation: "create", hasAddresses: false },
    { operation: "restore", hasAddresses: true },
    { operation: "restore", hasAddresses: false },
  ])("publishes only after network readiness or rolls back: %j", async ({ operation, hasAddresses }) => {
    const events: string[] = [];
    const data = {
      id: "vm-network-test", state: "running", snapshotId: "sh-fixture",
      resources: { cpu: 64, memory: 131072, storage: 1048576 },
      vpcs: hasAddresses ? [{ ipv4: "10.16.0.2", ipv6: "fd00::2" }] : [],
    };
    const vm = {
      exec: async ({ command }: { command: string }) => {
        events.push(command.startsWith("python3 -c ") ? "guest-network" : "guest-daemon");
        return { statusCode: 0, stdout: "", stderr: "" };
      },
      fs: {
        writeTextFile: async () => {},
        remove: async () => {},
      },
      delete: async () => { events.push("delete"); },
    };
    const client = { vms: {
      create: async () => { events.push("allocated"); return { vm, vmId: data.id, data }; },
      get: async () => data,
    } } as unknown as Freestyle;
    const provider = new FreestyleProvider({
      client: () => client,
      resolveDaemonSource: async () => { throw new Error("No daemon install is needed"); },
    });

    const allocation = operation === "create"
      ? provider.create({ image: "sh-fixture", network: { id: "vpc-fixture" } })
      : provider.restore("sh-fixture", { network: { id: "vpc-fixture" } });
    const preparation = operation === "restore"
      ? ["allocated", "guest-daemon", "guest-daemon"]
      : ["allocated", "guest-daemon"];
    if (hasAddresses) {
      await allocation;
      events.push("published");
      expect(events).toEqual([...preparation, "guest-network", "published"]);
    } else {
      await expect(allocation).rejects.toThrow();
      expect(events).toEqual([...preparation, "delete"]);
    }
  });

  test("the guest announces assigned IPv4 and IPv6 without touching other addresses", () => {
    const { status, packets } = captureAnnouncements(["10.16.0.2", "fd00::2"]);
    expect(status).toBe(0);
    expect(packets).toHaveLength(2);
    const arp = Buffer.from(packets[0].packet, "hex");
    expect(packets[0].bound).toEqual(["eth0.181", 0]);
    expect(arp.subarray(0, 6).toString("hex")).toBe("ffffffffffff");
    expect(arp.readUInt16BE(12)).toBe(0x0806);
    expect(arp.readUInt16BE(20)).toBe(1);
    expect([...arp.subarray(28, 32)]).toEqual([10, 16, 0, 2]);
    expect(arp.subarray(38, 42)).toEqual(arp.subarray(28, 32));
    const neighbor = Buffer.from(packets[1].packet, "hex");
    expect(neighbor[0]).toBe(136);
    expect(neighbor.readUInt32BE(4)).toBe(0x20000000);
    expect(neighbor.subarray(8, 24).toString("hex")).toBe("fd000000000000000000000000000002");
    expect(neighbor.subarray(24).toString("hex")).toBe("020102000a100002");
    expect(packets[1].target).toEqual(["ff02::1", 0, 0, 8]);
    expect(packets[1].options.some((option) => option[2] === 255)).toBe(true);
  });

  test("an address absent from the guest is never advertised and fails readiness", () => {
    const { status, packets } = captureAnnouncements(["10.16.0.99"]);
    expect(status).not.toBe(0);
    expect(packets).toEqual([]);
  });

  test("one assigned family remains usable while the other address is still pending", () => {
    const { status, packets } = captureAnnouncements(["10.16.0.2", "fd00::99"]);
    expect(status).toBe(0);
    expect(packets).toHaveLength(1);
    expect(Buffer.from(packets[0].packet, "hex").readUInt16BE(12)).toBe(0x0806);
  });

  test.each(["ipv4", "ipv6"])("an unavailable %s socket preserves the working family", (family) => {
    const { status, packets } = captureAnnouncements(["10.16.0.2", "fd00::2"], family);
    expect(status).toBe(0);
    expect(packets).toHaveLength(1);
    expect(packets[0].target !== undefined).toBe(family === "ipv4");
  });

  test("failure of both families still rejects network readiness", () => {
    const { status, packets } = captureAnnouncements(["10.16.0.2", "fd00::2"], "both");
    expect(status).not.toBe(0);
    expect(packets).toEqual([]);
  });

  test("a guest failure prevents reporting that its network is ready", async () => {
    const vm = { exec: async () => ({ statusCode: 1, stdout: "", stderr: "not assigned" }) };
    await expect(Effect.runPromise(announceFreestyleNetwork(vm as never, ["10.16.0.2"]))).rejects.toThrow();
  });

  test.each([{ addresses: [] }, { addresses: ["invalid-address"] }])("missing usable addresses fail before guest execution: %j", async ({ addresses }) => {
    let executed = false;
    const vm = { exec: async () => { executed = true; return { statusCode: 0, stdout: "", stderr: "" }; } };
    await expect(Effect.runPromise(announceFreestyleNetwork(vm as never, addresses))).rejects.toThrow("Private network has no valid assigned address");
    expect(executed).toBe(false);
  });
});
