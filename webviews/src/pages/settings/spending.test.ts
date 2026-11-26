// Settings > Cloud > Spending's model: the dollar field (positive amount, empty is off) and the banner each cap
// read gets. The thresholds are the server's (`spend_cap.state`); the model only words them.
import { expect, test } from "bun:test";
import type { SpendCap } from "../cloud/spendCap";
import {
  DEFAULT_SPENDING,
  limitText,
  parseLimitUsd,
  parseShapeKey,
  shapeKey,
  shapeLabel,
  spendingModel,
} from "./spending";

test("an empty field is off", () => {
  expect(parseLimitUsd("")).toEqual({ ok: true, usd: null });
  expect(parseLimitUsd("   ")).toEqual({ ok: true, usd: null });
  expect(parseLimitUsd("$")).toEqual({ ok: true, usd: null });
});

test("positive amounts parse, with a dollar sign, spaces, commas and cents", () => {
  expect(parseLimitUsd("40")).toEqual({ ok: true, usd: 40 });
  expect(parseLimitUsd(" $40.50 ")).toEqual({ ok: true, usd: 40.5 });
  expect(parseLimitUsd("$ 1,200")).toEqual({ ok: true, usd: 1200 });
  expect(parseLimitUsd(".5")).toEqual({ ok: true, usd: 0.5 });
});

test("zero, negatives, text and fractions of a cent are refused", () => {
  for (const text of ["0", "0.00", "-5", "$-5", "abc", "40.505", "4e3", "1.2.3", "Infinity"]) {
    const parsed = parseLimitUsd(text);
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error.length).toBeGreaterThan(0);
  }
});

test("the field text round-trips a saved limit", () => {
  expect(limitText(null)).toBe("");
  expect(limitText(40)).toBe("40");
  expect(limitText(40.5)).toBe("40.50");
  expect(parseLimitUsd(limitText(40.5))).toEqual({ ok: true, usd: 40.5 });
});

test("shapes word and key both ways", () => {
  expect(shapeLabel({ vcpu: 8, memory_gib: 16 })).toBe("8 vCPU · 16 GB");
  expect(parseShapeKey(shapeKey({ vcpu: 16, memory_gib: 32 }))).toEqual({ vcpu: 16, memory_gib: 32 });
  expect(parseShapeKey("0x16")).toBeUndefined();
  expect(parseShapeKey("big")).toBeUndefined();
});

const cap = (state: SpendCap["state"], spent: number, paused = false): SpendCap => ({
  state,
  spent_usd: spent,
  cap_usd: 50,
  period_end: null,
  checked_at: null,
  pause_at: null,
  paused_at: paused ? 1 : null,
});
const on = { ...DEFAULT_SPENDING, overage_limit_usd: 50 };

test("the placeholder default is overage off, ask above 8 vCPU · 16 GB", () => {
  const model = spendingModel(DEFAULT_SPENDING, null, "en");
  expect(model.overageOn).toBe(false);
  expect(model.limitText).toBe("");
  expect(model.askAbove).toBe("8x16");
  expect(model.meter).toBeNull();
  expect(model.banner).toBeNull();
});

test("off shows no meter or banner even when a read says near", () => {
  const model = spendingModel(DEFAULT_SPENDING, cap("near", 40), "en");
  expect(model.meter).toBeNull();
  expect(model.banner).toBeNull();
});

test("on under the limit: a meter, no banner", () => {
  const model = spendingModel(on, cap("under", 20), "en");
  expect(model.meter).toEqual({ fraction: 0.4, label: "$20.00 of $50.00 this month" });
  expect(model.banner).toBeNull();
});

test("near: the server's state draws the 80% banner", () => {
  const model = spendingModel(on, cap("near", 40), "en");
  expect(model.banner?.kind).toBe("near");
  expect(model.banner?.title).toBe("80% of this month's overage limit used");
});

test("at the cap: paused, never stopped, local agents keep running", () => {
  const model = spendingModel(on, cap("at_cap", 50, true), "en");
  expect(model.banner?.kind).toBe("paused");
  expect(model.banner?.title).toBe("Paused at your overage limit");
  expect(model.banner?.message).toContain("paused, not stopped");
  expect(model.banner?.message).toContain("Agents on This Mac keep running.");
  expect(model.meter?.fraction).toBe(1);
});

test("a saved threshold outside the picker's list still shows as the picked option", () => {
  const model = spendingModel({ ...DEFAULT_SPENDING, ask_above: { vcpu: 6, memory_gib: 12 } }, null, "en");
  expect(model.askAbove).toBe("6x12");
  expect(model.askOptions.map((option) => option.value)).toContain("6x12");
});

test("overage off with the pool used up: a pool_spent banner, no meter", () => {
  const model = spendingModel(
    DEFAULT_SPENDING,
    {
      state: "at_cap",
      spent_usd: null,
      cap_usd: null,
      period_end: null,
      checked_at: null,
      pause_at: null,
      paused_at: 1,
    },
    "en",
  );
  expect(model.banner?.kind).toBe("pool_spent");
  expect(model.meter).toBeNull();
  expect(spendingModel(DEFAULT_SPENDING, null, "en").banner).toBeNull();
});
