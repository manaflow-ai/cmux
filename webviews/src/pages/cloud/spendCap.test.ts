import { describe, expect, test } from "bun:test";
import { pageError } from "../shared/pageClient";
import { refusalText, refusalTitle } from "./Notices";
import { CloudErrors, planRefusal, type CloudMachine } from "./ops";
import { capBanner, capBannerText, machineCapNote, type SpendCap } from "./spendCap";
import table from "./generated/strings.json";

const en = (table as Record<string, Record<string, string>>).en!;
const t = (key: string) => en[key] ?? key;

const read = { period_end: Date.UTC(2026, 11, 1), checked_at: Date.UTC(2026, 10, 18, 17, 30) };
const near: SpendCap = { state: "near", spent_usd: 412.5, cap_usd: 500, pause_at: null, paused_at: null, ...read };
const atCap: SpendCap = { ...near, state: "at_cap", spent_usd: 503.1 };
const PAUSE_AT = Date.UTC(2026, 10, 18, 17, 45);

describe("the team's spending cap banner", () => {
  test("shows nothing without the cap, under it, or before the first read", () => {
    expect(capBanner(undefined)).toBeUndefined();
    expect(capBanner({ ...near, state: "under", spent_usd: 10 })).toBeUndefined();
    expect(capBanner({ ...near, state: null, spent_usd: null, cap_usd: null })).toBeUndefined();
  });

  test("near, pausing, paused and reached, in that order of strength", () => {
    expect(capBanner(near)?.kind).toBe("near");
    expect(capBanner(atCap)?.kind).toBe("reached");
    expect(capBanner({ ...atCap, pause_at: PAUSE_AT })).toMatchObject({ kind: "pausing", pauseAt: PAUSE_AT });
    expect(capBanner({ ...atCap, pause_at: PAUSE_AT, paused_at: PAUSE_AT })?.kind).toBe("paused");
    // A raised cap after the pause: under the cap again, nothing to say.
    expect(capBanner({ ...near, state: "under", paused_at: PAUSE_AT })).toBeUndefined();
  });

  test("every banner says who can raise the cap", () => {
    for (const cap of [near, atCap, { ...atCap, pause_at: PAUSE_AT }, { ...atCap, paused_at: PAUSE_AT }]) {
      const banner = capBanner(cap)!;
      const { title, message } = capBannerText(banner, t, "en");
      expect(title.length).toBeGreaterThan(0);
      expect(message).toContain("A team admin can raise it");
      expect(message).not.toContain("{");
    }
    expect(capBannerText(capBanner(near)!, t, "en").message).toContain("$412.50 of $500.00");
  });
});

describe("a machine's cap note", () => {
  const machine = { id: "vm_1", status: "running" } as CloudMachine;
  test("a running machine with a pending pause says when", () => {
    expect(machineCapNote({ ...machine, spend_cap_pause_at: PAUSE_AT }, t, "en")).toStartWith("Pauses at ");
  });
  test("a machine the cap paused says so; any other machine says nothing", () => {
    expect(machineCapNote({ ...machine, status: "paused", paused_by: "spend_cap" }, t, "en")).toBe(
      "Paused at the spending cap",
    );
    expect(machineCapNote({ ...machine, status: "paused" }, t, "en")).toBeUndefined();
    expect(machineCapNote(machine, t, "en")).toBeUndefined();
  });
});

describe("spend refusals", () => {
  const capDetails = { spent_usd: 503.1, cap_usd: 500, period_end: Date.UTC(2026, 11, 1), pause_at: null };
  test("the team's cap: what was spent and that an admin can raise it, with no See plans", () => {
    const refusal = planRefusal(pageError(CloudErrors.spendCapReached, "raw", false, capDetails), "pro")!;
    expect(refusal).toEqual({ kind: "spend_cap", spentUsd: 503.1, capUsd: 500, periodEnd: capDetails.period_end });
    expect(refusalTitle(refusal, t)).toBe("Your team reached its spending cap");
    expect(refusalText(refusal, t, "en")).toContain("$503.10 of $500.00");
    expect(refusalText(refusal, t, "en")).toContain("A team admin can raise it");
  });

  test("an older app server's protocol_error keeps the backend code: still the cap", () => {
    const error = Object.assign(pageError("cmux.cloud.protocol_error", "raw", false, capDetails), {
      upstream_code: "cloud.spend_cap.reached",
    });
    expect(planRefusal(error)?.kind).toBe("spend_cap");
  });

  test("the member's own budget", () => {
    const error = pageError(CloudErrors.memberBudgetReached, "raw", false, { spent_usd: 50.2, limit_usd: 50 });
    const refusal = planRefusal(error)!;
    expect(refusal).toEqual({ kind: "member_budget", spentUsd: 50.2, capUsd: 50 });
    expect(refusalTitle(refusal, t)).toBe("You've spent your monthly budget");
    expect(refusalText(refusal, t, "en")).toBe("$50.20 of your $50.00 budget spent. A team admin can raise it.");
  });
});
