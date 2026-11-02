import { describe, expect, test } from "bun:test";
import table from "./generated/strings.json";
import { costLine, costTicks } from "./cost";
import type { CloudMachine } from "./ops";

const en = (table as Record<string, Record<string, string>>).en;
const t = (key: string) => en[key] ?? key;
const NOW = Date.UTC(2026, 9, 31, 12, 0);
const machine = (patch: Partial<CloudMachine>): CloudMachine => ({
  id: "vm_a1",
  status: "running",
  revision: "1",
  ...patch,
});

describe("Cloud page cost line (the sidebar's wording)", () => {
  test("a running machine: rate, time running and the estimate so far", () => {
    const m = machine({ hourly_rate_usd: 0.2645, running_since: NOW - (2 * 60 + 14) * 60_000 });
    expect(costLine(m, NOW, t, "en")).toBe("$0.26/h · Running 2h 14m · About $0.59 so far");
    expect(costTicks(m)).toBe(true);
  });

  test("days show as at most two units; under a minute reads as one", () => {
    const days = machine({ hourly_rate_usd: 0.1, running_since: NOW - (3 * 1440 + 4 * 60 + 5) * 60_000 });
    expect(costLine(days, NOW, t, "en")).toBe("$0.10/h · Running 3d 4h · About $7.61 so far");
    const fresh = machine({ hourly_rate_usd: 0.2645, running_since: NOW - 5_000 });
    expect(costLine(fresh, NOW, t, "en")).toBe("$0.26/h · Running 1m · Under $0.01 so far");
  });

  test("a paused machine shows only its rate when running, and does not tick", () => {
    const m = machine({ status: "paused", hourly_rate_usd: 0.1322, running_since: null });
    expect(costLine(m, NOW, t, "en")).toBe("$0.13/h when running");
    expect(costTicks(m)).toBe(false);
  });

  test("no rate: the running time alone; nothing at all while paused", () => {
    expect(costLine(machine({ running_since: NOW - 3_600_000 }), NOW, t, "en")).toBe("Running 1h");
    expect(costLine(machine({ status: "paused" }), NOW, t, "en")).toBeUndefined();
    expect(costLine(machine({}), NOW, t, "en")).toBeUndefined();
  });
});
