// l10n-allow-file: test fixtures.
// What the health indicator derives from a snapshot: quiet when healthy and nothing is queued, the
// worst part (oldest first among equals), its tone, and the one line, or the queued action's line.
import { describe, expect, test } from "bun:test";
import { createStrings } from "../pages/shared/i18n";
import { headline, indicatorHeadline, isQuiet, otherParts, toneOf, worstPart } from "./model";
import type { HealthPart, HealthSnapshot } from "./types";

const strings = createStrings(
  {
    en: {
      "appHealth.line": "%1$@: %2$@",
      "appHealth.state.failed": "Needs a repair",
      "appHealth.state.slow": "Slow",
      "appHealth.pending": "Reconnecting; will %@ when back",
      "appHealth.line.stuck": "%@ isn’t responding",
      "appHealth.line.repairing": "Repairing %@…",
      "appHealth.line.failed": "%@ needs a repair",
    },
  },
  ["en"],
);

const part = (id: string, state: HealthPart["state"], sinceMs = 0): HealthPart => ({
  id,
  kind: "page",
  label: id,
  state,
  sinceMs,
  detail: "",
  action: "none",
  attempt: 0,
  maxAttempts: 3,
  nextAtMs: null,
  canRepair: false,
});

describe("app health model", () => {
  test("healthy with nothing queued is quiet", () => {
    expect(isQuiet({ worst: "healthy", parts: [], receipts: [] })).toBe(true);
    expect(headline({ worst: "healthy", parts: [], receipts: [] }, strings)).toBeNull();
  });

  test("a queued action shows even when every part is healthy", () => {
    const snapshot: HealthSnapshot = {
      worst: "healthy",
      parts: [],
      receipts: [],
      pending: [{ id: "i", label: "close Background task", sinceMs: 1 }],
    };
    expect(isQuiet(snapshot)).toBe(false);
    expect(headline(snapshot, strings)).toEqual({
      tone: "muted",
      text: "Reconnecting; will close Background task when back",
      part: null,
    });
  });

  test("the worst part leads, the oldest among equals, and names the line", () => {
    const snapshot: HealthSnapshot = {
      worst: "failed",
      parts: [part("Slow page", "slow"), part("New", "failed", 9), part("Old", "failed", 2)],
      receipts: [],
    };
    const worst = worstPart(snapshot);
    expect(worst?.id).toBe("Old");
    expect(otherParts(snapshot, worst).map((p) => p.id)).toEqual(["New", "Slow page"]);
    expect(headline(snapshot, strings)?.text).toBe("Old: Needs a repair");
    expect(toneOf("failed")).toBe("danger");
    expect(toneOf("slow")).toBe("attention");
  });

  // Leo, 2026-11-11: "slow indicator on the bottom left is uselsss and layout shifts the space. it's bad".
  test("the indicator says nothing for a part that is only slow; the popover still names it", () => {
    const snapshot: HealthSnapshot = { worst: "slow", parts: [part("Agent chat", "slow")], receipts: [] };
    expect(indicatorHeadline(snapshot, strings)).toBeNull();
    expect(headline(snapshot, strings)?.text).toBe("Agent chat: Slow");
  });

  test("the indicator names the part and what is happening to it", () => {
    const one = (state: HealthPart["state"]) =>
      indicatorHeadline({ worst: state, parts: [part("Agent chat", state)], receipts: [] }, strings);
    expect(one("stuck")).toMatchObject({ tone: "danger", text: "Agent chat isn’t responding" });
    expect(one("repairing")).toMatchObject({ tone: "attention", text: "Repairing Agent chat…" });
    expect(one("failed")).toMatchObject({ tone: "danger", text: "Agent chat needs a repair" });
  });

  test("a slow part never hides a queued action behind it", () => {
    const snapshot: HealthSnapshot = {
      worst: "slow",
      parts: [part("Agent chat", "slow")],
      receipts: [],
      pending: [{ id: "i", label: "close Background task", sinceMs: 1 }],
    };
    expect(indicatorHeadline(snapshot, strings)?.text).toBe("Reconnecting; will close Background task when back");
  });
});
