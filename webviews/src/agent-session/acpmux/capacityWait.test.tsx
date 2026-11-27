// l10n-allow-file: test fixtures (agent errors), not shipped UI.
// A chat acpmux holds for capacity reads as one calm wait (RFD model-overload-smoothing §3.8; Leo,
// 2026-11-24: "fix 529s properly with better designs"): the countdown from acpmux's resume time, the
// raw 529 or 503 only under Details, and never the failure red.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { translate } from "./i18n";
import type { AcpmuxRow } from "./model";
import {
  aboutTime,
  capacityEta,
  capacityProgress,
  groupedCapacityHelpersFor,
  readCapacityWait,
  waitsFor,
} from "./capacityWait";
import { CapacityWaitCard } from "./conversation/CapacityWaitCard";

const OVERLOAD = "API Error: Repeated 529 Overloaded errors";
const t = (key: Parameters<typeof translate>[0], values?: Parameters<typeof translate>[1]) =>
  translate(key, values, "en");

test("acpmux's capacityWait reads back, and anything else is no wait", () => {
  expect(
    readCapacityWait({ reason: "capacity", resumesAt: 41_000, turnId: "t1", since: 1_000, error: OVERLOAD }),
  ).toEqual({ reason: "capacity", resumesAt: 41_000, turnId: "t1", since: 1_000, error: OVERLOAD });
  expect(readCapacityWait({ reason: "rate_limit" })).toEqual({ reason: "rate_limit" });
  expect(readCapacityWait({ reason: "transport", turnId: "t1" })).toBeUndefined();
  expect(readCapacityWait(undefined)).toBeUndefined();
  expect(readCapacityWait("capacity")).toBeUndefined();
});

test("a wait stands in for its own turn's failure only", () => {
  const wait = { reason: "capacity" as const, turnId: "t1" };
  expect(waitsFor(wait, "t1")).toBe(true);
  expect(waitsFor(wait, "t0")).toBe(false);
  expect(waitsFor({ reason: "capacity" }, undefined)).toBe(false);
  expect(waitsFor(undefined, "t1")).toBe(false);
});

test("a paused helper group only hides the card for its own held turn", () => {
  const paused = {
    id: "helpers-old",
    version: 1,
    at: 1,
    kind: "subagents",
    subagents: [
      {
        id: "old-helper",
        parent: null,
        name: "Old helper",
        state: "failed",
        startedAt: 1,
        capacityWait: { reason: "capacity" },
      },
    ],
  } as AcpmuxRow;
  const oldSummary = { id: "old-summary", version: 1, at: 2, kind: "turnSummary", turnId: "old-turn" } as AcpmuxRow;
  const heldSummary = { id: "held-summary", version: 1, at: 3, kind: "turnSummary", turnId: "held-turn" } as AcpmuxRow;
  const rows = [paused, oldSummary, heldSummary];
  expect(groupedCapacityHelpersFor(rows, { reason: "capacity", turnId: "held-turn" })).toBe(false);
  expect(groupedCapacityHelpersFor(rows, { reason: "capacity", turnId: "old-turn" })).toBe(true);

  const currentGroup = { ...paused, id: "helpers-current" } as AcpmuxRow;
  expect(
    groupedCapacityHelpersFor([oldSummary, currentGroup, heldSummary], { reason: "capacity", turnId: "held-turn" }),
  ).toBe(true);

  const nextPrompt = { id: "next-prompt", version: 1, at: 2, kind: "user", turnId: "held-turn" } as AcpmuxRow;
  expect(
    groupedCapacityHelpersFor([paused, nextPrompt, heldSummary], { reason: "capacity", turnId: "held-turn" }),
  ).toBe(false);

  const taggedMismatch = {
    ...paused,
    subagents: [{ ...paused.subagents![0]!, capacityWait: { reason: "capacity", turnId: "other-turn" } }],
  } as AcpmuxRow;
  expect(groupedCapacityHelpersFor([taggedMismatch, heldSummary], { reason: "capacity", turnId: "held-turn" })).toBe(
    false,
  );
});

test("the countdown reads in rounded steps", () => {
  expect(aboutTime(38.2)).toBe("40s");
  expect(aboutTime(0.4)).toBe("1s");
  expect(aboutTime(195)).toBe("3m 15s");
  expect(aboutTime(12 * 60)).toBe("12m");
  expect(aboutTime(2 * 3600)).toBe("2h");
  const wait = { reason: "capacity" as const, since: 0, resumesAt: 70_000 };
  expect(capacityEta(t, wait, 30_000)).toBe("Waiting for capacity, about 40s");
  expect(capacityEta(t, wait, 70_500)).toBe("Waiting for capacity, any moment now");
  expect(capacityEta(t, { reason: "capacity" }, 0)).toBe("Waiting for capacity, any moment now");
  expect(capacityProgress(wait, 35_000)).toBe(0.5);
  expect(capacityProgress({ reason: "capacity" }, 0)).toBeUndefined();
});

test("every look is calm: the countdown in the body, the raw error under Details, no failure mark", () => {
  const wait = { reason: "capacity" as const, since: 0, resumesAt: 70_000, turnId: "t1", error: OVERLOAD };
  for (const look of ["line", "card", "bar"] as const) {
    const html = renderToStaticMarkup(<CapacityWaitCard wait={wait} look={look} now={30_000} />);
    expect(html).toContain("Waiting for capacity, about 40s");
    expect(html).toContain('<output class="cv-capacity-wait__line">');
    expect(html).not.toContain("cv-turn-error__icon");
    expect(html).not.toContain("agent-status-failure");
    // The 529 only inside the closed Details.
    const body = html.slice(0, html.indexOf("<details"));
    expect(body).not.toContain("529");
    expect(html).toContain(OVERLOAD);
  }
  const bar = renderToStaticMarkup(<CapacityWaitCard wait={wait} look="bar" now={35_000} />);
  expect(bar).toContain("inline-size:50%");
  const card = renderToStaticMarkup(<CapacityWaitCard wait={wait} look="card" now={30_000} />);
  expect(card).toContain("The chat goes on by itself.");
});
