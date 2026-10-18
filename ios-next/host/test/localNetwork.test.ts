import { describe, expect, it } from "vitest";
import { checkLocalNetwork, describeLocalNetwork, parseDefaultGateway } from "../src/transport/localNetwork.ts";

const ROUTE = `   route to: default
destination: default
       mask: default
    gateway: 172.20.20.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
`;

describe("local network self-check", () => {
  it("parses the IPv4 default gateway", () => {
    expect(parseDefaultGateway(ROUTE)).toBe("172.20.20.1");
    expect(parseDefaultGateway("gateway: fe80::1%en0\n")).toBeUndefined();
    expect(parseDefaultGateway("route: writing to routing socket: not in table\n")).toBeUndefined();
  });

  it("reports blocked when the kernel refuses LAN sends", async () => {
    const s = await checkLocalNetwork({ platform: "darwin", gateway: async () => "172.20.20.1", send: async () => "EHOSTUNREACH" });
    expect(s).toEqual({ state: "blocked", target: "172.20.20.1", code: "EHOSTUNREACH" });
    expect(describeLocalNetwork(s)).toMatch(/BLOCKED.*TURN relay.*Local Network/);
  });

  it("reports ok, and skips off macOS or without a gateway", async () => {
    expect(await checkLocalNetwork({ platform: "darwin", gateway: async () => "10.0.0.1", send: async () => undefined })).toEqual({ state: "ok", target: "10.0.0.1" });
    expect((await checkLocalNetwork({ platform: "linux" })).state).toBe("unknown");
    expect((await checkLocalNetwork({ platform: "darwin", gateway: async () => undefined })).state).toBe("unknown");
    expect((await checkLocalNetwork({ platform: "darwin", gateway: async () => "10.0.0.1", send: async () => "ENOBUFS" })).state).toBe("unknown");
  });
});
