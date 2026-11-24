import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { coversPublicIpv6, ipv6RouteProblems, ipv6RouteSmokeCommand, PUBLIC_IPV6_PROBE } from "../scripts/cmux-vm-image/ipv6-route";

// What a Freestyle clone prints: ULA address, router-advertised default route (RFD 0067).
const FREESTYLE = [
  "== default",
  "default via fe80::1 dev eth0 proto ra metric 1024 expires 1799sec hoplimit 64 pref medium",
  "== main",
  "fd00:0:0:12::/64 dev eth0 proto ra metric 1024 expires 86398sec pref medium",
  "fe80::/64 dev eth0 proto kernel metric 256 pref medium",
  "default via fe80::1 dev eth0 proto ra metric 1024 expires 1799sec hoplimit 64 pref medium",
  "== get",
  `${PUBLIC_IPV6_PROBE} from :: via fe80::1 dev eth0 proto ra src fd00:0:0:12::5 metric 1024 pref medium`,
  "== end",
].join("\n");

// A host with dead IPv6 after its fix (hq docs/handbook/fetch-shape-stalls-before-the-first-byte.md).
const HUGE_BLUE_FIX = [
  "== default",
  "default via fe80::1 dev eth0 proto ra metric 1024 pref medium",
  "== main",
  "unreachable 2000::/3 dev lo metric 1 pref medium",
  "fd7a:115c:a1e0::/48 dev tailscale0 metric 1024 pref medium",
  "default via fe80::1 dev eth0 proto ra metric 1024 pref medium",
  "== get",
  "RTNETLINK answers: No route to host",
  "== end",
].join("\n");

describe("ipv6RouteProblems", () => {
  test("a Freestyle clone with a router-advertised default route passes", () => {
    expect(ipv6RouteProblems(0, FREESTYLE)).toEqual([]);
  });

  test("a dead-IPv6 host's unreachable 2000::/3 fails, and so does the lookup it breaks", () => {
    const problems = ipv6RouteProblems(0, HUGE_BLUE_FIX);
    expect(problems.some((p) => p.includes("unreachable 2000::/3"))).toBe(true);
    expect(problems.some((p) => p.includes("names no device"))).toBe(true);
  });

  test("other block routes over public space fail; ULA and link-local ones do not", () => {
    const out = (line: string) => FREESTYLE.replace("== get", `${line}\n== get`);
    expect(ipv6RouteProblems(0, out("blackhole 2600::/12 dev lo metric 1 pref medium"))).toHaveLength(1);
    expect(ipv6RouteProblems(0, out("prohibit default dev lo metric 1 pref medium"))).toHaveLength(1);
    expect(ipv6RouteProblems(0, out("unreachable fd00::/8 dev lo metric 1 pref medium"))).toEqual([]);
  });

  test("no IPv6 default route fails", () => {
    const noDefault = FREESTYLE.replace(/^default .*$/gm, "");
    expect(ipv6RouteProblems(0, noDefault).some((p) => p.startsWith("no IPv6 default route"))).toBe(true);
  });

  test("a read that never finished fails", () => {
    expect(ipv6RouteProblems(124, "== default\n")[0]).toContain("did not finish");
  });
});

describe("coversPublicIpv6", () => {
  test("global unicast and wider prefixes", () => {
    for (const p of ["2000::/3", "2606:4700::/32", "3fff::/16", "default", "::/0", "::/2"]) expect(coversPublicIpv6(p)).toBe(true);
    for (const p of ["fd7a:115c:a1e0::/48", "fe80::/64", "ff00::/8", "::1", "fc00::/7", "4000::/2"]) expect(coversPublicIpv6(p)).toBe(false);
  });
});

test("the smoke command reads all three and ends with a marker", () => {
  const command = ipv6RouteSmokeCommand();
  for (const part of ["ip -6 route show default", "ip -6 route show 2>&1", `ip -6 route get ${PUBLIC_IPV6_PROBE}`, "== end"]) expect(command).toContain(part);
});

// The image's own sources never add a block route (`ip route add unreachable ...`, a networkd Type=unreachable), RFD 0067 item 5.
test("no image source adds a block route over public IPv6", () => {
  const roots = [path.resolve(import.meta.dirname, "../scripts/cmux-vm-image"), path.resolve(import.meta.dirname, "../../images/cmux-vm")];
  const offenders: string[] = [];
  const walk = (dir: string) => {
    for (const name of readdirSync(dir)) {
      const file = path.join(dir, name);
      if (statSync(file).isDirectory()) walk(file);
      else if (/route\s+(add|replace|append)\s+(unreachable|blackhole|prohibit)\b|^\s*Type\s*=\s*(unreachable|blackhole|prohibit)\b/m.test(readFileSync(file, "utf8"))) offenders.push(file);
    }
  };
  for (const root of roots) walk(root);
  expect(offenders).toEqual([]);
});
