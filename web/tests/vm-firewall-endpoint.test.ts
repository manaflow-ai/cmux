import { describe, expect, test } from "bun:test";
import { parseFirewallEndpoint } from "../services/vms/firewallEndpoint";

// Staging rehearsal 2026-10-04: destination.cidr "10.250.0.0/24" answered 400 "must be a CIDR range"
// because the prefix was compared with net.isIP() (the family, 4 or 6), not the address width.
const accepted = (cidr: string) => !(parseFirewallEndpoint({ cidr }, "destination") instanceof Response);

describe("firewall endpoint cidr", () => {
  test("accepts ordinary IPv4 and IPv6 prefixes", () => {
    for (const cidr of ["10.250.0.0/24", "10.16.162.5/32", "0.0.0.0/0", "fd0b:6ba2:c4bd::/64", "fd00::1/128"]) expect([cidr, accepted(cidr)]).toEqual([cidr, true]);
  });
  test("rejects prefixes wider than the address and bare addresses", () => {
    for (const cidr of ["10.0.0.0/33", "fd00::/129", "10.0.0.0", "10.0.0.0/", "10.0.0.0/x", "nope/8"]) expect([cidr, accepted(cidr)]).toEqual([cidr, false]);
  });
});
