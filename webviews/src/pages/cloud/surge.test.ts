import { describe, expect, test } from "bun:test";
import table from "./generated/strings.json";
import type { CloudMachine, CloudSurge } from "./ops";
import { seconds, shownSurge, surgeParts } from "./surge";

const en = (table as Record<string, Record<string, string>>).en;
const t = (key: string) => en[key] ?? key;
const second = (value: number) =>
  new Intl.NumberFormat("en", { style: "unit", unit: "second", unitDisplay: "short" }).format(value);
const minute = (value: number) =>
  new Intl.NumberFormat("en", { style: "unit", unit: "minute", unitDisplay: "short" }).format(value);
const surge = (patch: Partial<CloudSurge> = {}): CloudSurge => ({
  started_at: 0,
  count: 25,
  ready: 25,
  starting: 0,
  failed: 0,
  drained: true,
  last_ready_ms: 32_480,
  machines: ["vm_surge01", "vm_surge02"],
  ...patch,
});
const listed = (id: string) => ({ id }) as CloudMachine;

describe("Cloud surge card", () => {
  test("a drained surge past 8 reads ready, last ready and queue drained", () => {
    expect(surgeParts(surge(), t, "en")).toEqual([
      "Ready: 25 of 25",
      `Last one ready in ${second(32)}`,
      "Queue drained",
    ]);
  });

  test("a queue still starting counts what is left and has no last-ready time", () => {
    const parts = surgeParts(
      surge({ ready: 17, starting: 7, failed: 1, drained: false, last_ready_ms: undefined }),
      t,
      "en",
    );
    expect(parts).toEqual(["Ready: 17 of 25", "Still starting: 7", "Failed: 1"]);
  });

  test("durations past a minute keep the seconds", () => {
    expect(seconds(297_400, "en")).toBe(`${minute(4)} ${second(57)}`);
    expect(seconds(120_000, "en")).toBe(minute(2));
    expect(seconds(0, "en")).toBe(second(1));
  });

  test("the card hides once none of the surge's machines is listed", () => {
    expect(shownSurge(surge(), [listed("vm_surge02")])).toBeDefined();
    expect(shownSurge(surge(), [listed("vm_other")])).toBeUndefined();
    expect(shownSurge(undefined, [listed("vm_surge01")])).toBeUndefined();
  });
});
