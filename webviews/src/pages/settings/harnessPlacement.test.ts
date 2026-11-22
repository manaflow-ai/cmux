import { expect, test } from "bun:test";
import { HARNESS_PLACEMENT_KEY as key, resolveHarnessPlacement } from "../../ui/harnessPlacement";
import { composeState } from "./store";
import { optimistic, scopeData } from "./queries";
import type { HostLists } from "./ops";

const initial = () =>
  scopeData({
    rows: [{ key, value: "symbols", default: "symbols", stored: null, customized: false, managed: null }],
    snapshot: { revision: 1, schema_hash: "", effective: {}, managed: {}, diagnostics: [] },
  });
const row = (scope: ReturnType<typeof initial>, legacy = "left") =>
  composeState(
    { connected: true, errors: new Map() },
    {
      scope,
      scopeSettled: true,
      host: { harness_placement: legacy } as HostLists,
      accounts: undefined,
      devices: undefined,
      themeColors: undefined,
    },
  ).rows.get(key)!;

test("inherited placement and explicit symbols agree with the picker, Changed and Reset", () => {
  const before = initial();
  expect(row(before).value).toBe(resolveHarnessPlacement(null, "left"));
  expect(row(before).customized).toBe(false);
  const changed = optimistic(before, { kind: "set", key, value: "symbols" });
  expect(row(changed).value).toBe(resolveHarnessPlacement("symbols", "left"));
  expect(row(changed).customized).toBe(true);
  // Confirmation preserves the raw explicit default, even though the schema calls it uncustomized.
  const confirmed = {
    ...changed,
    rows: new Map(changed.rows).set(key, { ...changed.rows.get(key)!, customized: false }),
  };
  expect(row(confirmed).customized).toBe(true);
  const reset = optimistic(confirmed, { kind: "reset", key });
  expect(row(reset).value).toBe("left");
  expect(row(reset).customized).toBe(false);
  expect(row(optimistic(confirmed, { kind: "resetAll" })).value).toBe("left");
});

test("legacy changes update an inherited row while explicit and managed choices keep precedence", () => {
  const before = initial();
  expect(row(before, "compact").value).toBe("compact");
  const explicit = optimistic(before, { kind: "set", key, value: "top" });
  expect(row(explicit, "compact").value).toBe("top");
  const managed = {
    ...explicit,
    rows: new Map(explicit.rows).set(key, {
      ...explicit.rows.get(key)!,
      value: "symbols",
      managed: { source: "mdm", reason: "managed" },
    }),
  };
  expect(row(managed).value).toBe(resolveHarnessPlacement("top", "left", "symbols"));
});

test("an explicit choice matching Debug stays resettable and stops following later Debug changes", () => {
  const explicit = optimistic(initial(), { kind: "set", key, value: "left" });
  expect(row(explicit, "left").value).toBe("left");
  expect(row(explicit, "left").customized).toBe(true);
  expect(row(explicit, "top").value).toBe("left");
  const reset = optimistic(explicit, { kind: "reset", key });
  expect(row(reset, "top").value).toBe("top");
  expect(row(reset, "top").customized).toBe(false);
});
