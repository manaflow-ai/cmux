// l10n-allow-file: test fixtures.
// What the server surfaces derive from the app's status: the pairing code rules, the health order,
// the overall line and the panel's facts. Add Server is a native card (AddServerDialogTests).
import { describe, expect, test } from "bun:test";
import { scenario, status } from "./fixtures";
import { HealthOrdering, overallOf, PairingCode, panelFacts } from "./model";
import type { HealthAlert } from "./types";

describe("pairing code", () => {
  test("normalizes what a person types", () => {
    expect(PairingCode.normalize("7kq4-m2xd")).toBe("7KQ4M2XD");
    expect(PairingCode.normalize("o1l I")).toBe("0111");
    expect(PairingCode.editing("7kq4m2xdextra")).toBe("7KQ4-M2XD");
    expect(PairingCode.editing("7kq")).toBe("7KQ");
    expect(PairingCode.editing("7k?q4")).toBe("7KQ4");
    expect(PairingCode.isComplete("7KQ4-M2XD")).toBe(true);
    expect(PairingCode.isComplete("7KQ4-M2XU")).toBe(false);
    expect(PairingCode.display("7KQ4M2XD")).toBe("7KQ4-M2XD");
  });
});

describe("health order", () => {
  const alert = (
    check: string,
    severity: HealthAlert["severity"],
    raisedAt: number,
    resolvedAt?: number,
  ): HealthAlert => ({
    check,
    severity,
    title: check,
    body: "",
    raisedAt,
    resolvedAt,
  });

  test("open alerts: critical first, newest first, check id breaks ties", () => {
    const alerts = [
      alert("b", "warning", 10),
      alert("a", "warning", 10),
      alert("c", "critical", 1),
      alert("d", "warning", 20, 30),
    ];
    expect(HealthOrdering.open(alerts).map((entry) => entry.check)).toEqual(["c", "a", "b"]);
    expect(HealthOrdering.worst(alerts)).toBe("critical");
    expect(HealthOrdering.worst([alert("x", "critical", 1, 2)])).toBeUndefined();
  });

  test("checklist: failing checks first, then passing ones in order, resolved never", () => {
    const rows = HealthOrdering.checklist(["p", "q", "r"], [alert("r", "warning", 5), alert("q", "critical", 1, 2)]);
    expect(rows.map((row) => [row.check, row.alert !== undefined])).toEqual([
      ["r", true],
      ["p", false],
      ["q", false],
    ]);
  });

  test("timeline: newest event first, a resolve counts at its resolve time", () => {
    const events = HealthOrdering.timeline([
      alert("a", "info", 100),
      alert("b", "warning", 50, 200),
      alert("c", "info", 150),
    ]);
    expect(events.map((entry) => entry.check)).toEqual(["b", "c", "a"]);
  });
});

describe("overall and panel facts", () => {
  test("the overall line follows the snapshot", () => {
    expect(overallOf(status("healthyMac"))).toEqual({ kind: "serving" });
    expect(overallOf(status("batteryLowDisk"))).toEqual({ kind: "attention", severity: "critical" });
    expect(overallOf(status("unpaired"))).toEqual({ kind: "unpaired" });
    expect(overallOf(status(null))).toEqual({ kind: "unavailable" });
    expect(overallOf(status("healthyMac", { snapshot: { ...scenario("healthyMac"), enabled: false } }))).toEqual({
      kind: "off",
    });
  });

  test("apps count only hosted apps; info alerts never count against health", () => {
    const facts = panelFacts(scenario("linuxHeadless"));
    expect(facts.appsValue).toBe("1/2");
    expect(facts.appsTroubled).toBe(true);
    expect(facts.issues.map((alert) => alert.check)).toEqual(["linger.off", "postgres.quota", "backup.stale"]);
    expect(panelFacts(scenario("healthyMac")).issues).toEqual([]);
    expect(panelFacts(scenario("unpaired")).appsValue).toBe("–");
  });
});
