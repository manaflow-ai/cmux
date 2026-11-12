// l10n-allow-file: test fixtures.
// What the server surfaces derive from the app's status: the pairing code rules, the health order,
// the overall line, the panel's facts, and the Add Server card's buttons and keys (every step has a
// Return and an Escape answer that a click on the same button also runs). Ported from the Swift
// AddServerCardTests and the model's ordering tests; the steps themselves stay with the app's
// ServerModel (AddServerFlowTests).
import { describe, expect, test } from "bun:test";
import { scenario, status } from "./fixtures";
import {
  addServerButtons,
  buttonForKey,
  escapeTitleKey,
  HealthOrdering,
  isClickOnly,
  layoutOf,
  overallOf,
  PairingCode,
  panelFacts,
  returnTitleKey,
  showsCandidate,
} from "./model";
import type { AddServerStepName, HealthAlert } from "./types";

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

describe("Add Server buttons and keys", () => {
  const steps: AddServerStepName[] = ["enterCode", "lookingUp", "codeRefused", "review", "approving", "approveFailed"];

  test("every step but added has Cancel on Escape and Approve or Try Again on Return", () => {
    for (const step of steps) {
      const buttons = addServerButtons({ step, canApprove: false });
      expect(buttons[0]).toEqual({ action: "cancel", isDefault: false, enabled: true });
      expect(buttons[1]).toEqual({
        action: step === "approveFailed" ? "retry" : "approve",
        isDefault: true,
        enabled: false,
      });
      expect(buttonForKey(buttons, "Escape")?.action).toBe("cancel");
    }
  });

  test("Return never approves or retries: only a click on the button does", () => {
    expect(buttonForKey(addServerButtons({ step: "review", canApprove: false }), "Enter")).toBeUndefined();
    expect(buttonForKey(addServerButtons({ step: "review", canApprove: true }), "Enter")).toBeUndefined();
    expect(buttonForKey(addServerButtons({ step: "approveFailed", canApprove: true }), "Enter")).toBeUndefined();
    expect(buttonForKey(addServerButtons({ step: "review", canApprove: true }), "a")).toBeUndefined();
    expect(["approve", "retry", "done", "cancel"].map((action) => isClickOnly(action as "approve"))).toEqual([
      true,
      true,
      false,
      false,
    ]);
  });

  test("added has only Done on Return", () => {
    const buttons = addServerButtons({ step: "added", canApprove: false });
    expect(buttons).toEqual([{ action: "done", isDefault: true, enabled: true }]);
    expect(buttonForKey(buttons, "Escape")).toBeUndefined();
    expect(buttonForKey(buttons, "Enter")?.action).toBe("done");
  });

  test("titles: Deny once a server is on the card, the default's title by step", () => {
    expect(steps.map(escapeTitleKey)).toEqual([
      "approver.cancel",
      "approver.cancel",
      "approver.cancel",
      "approver.deny",
      "approver.deny",
      "approver.deny",
    ]);
    expect(
      ["review", "approving", "approveFailed", "added"].map((step) => returnTitleKey(step as AddServerStepName)),
    ).toEqual(["approver.approve", "approver.adding", "approver.retry", "approver.done"]);
  });

  test("the card's layout changes only between steps that show different content", () => {
    expect(steps.map(layoutOf)).toEqual(["code", "code", "code", "review", "review", "failed"]);
    expect(steps.map(showsCandidate)).toEqual([false, false, false, true, true, true]);
  });
});
