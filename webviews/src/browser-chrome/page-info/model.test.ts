import { describe, expect, test } from "bun:test";
import { splitSiteName } from "./model";

describe("splitSiteName", () => {
  test("a long host keeps its registrable domain in the part that always shows", () => {
    expect(splitSiteName("trusted.example.com.account-verification.attacker.test")).toEqual([
      "trusted.example.com.account-verification.",
      "attacker.test",
    ]);
  });

  test("a short public second level keeps three labels", () => {
    expect(splitSiteName("login.bank.example.co.uk")).toEqual(["login.bank.", "example.co.uk"]);
  });

  test("the port stays with the domain", () => {
    expect(splitSiteName("a.b.example.com:8443")).toEqual(["a.b.", "example.com:8443"]);
  });

  test("a bare domain is all tail", () => {
    expect(splitSiteName("example.com")).toEqual(["", "example.com"]);
  });

  test("a path keeps its end", () => {
    const [head, tail] = splitSiteName("/Users/someone/Documents/reports/2026/summary.pdf");
    expect(tail).toBe("2026/summary.pdf");
    expect(head + tail).toBe("/Users/someone/Documents/reports/2026/summary.pdf");
  });
});
