// settled-page-linux.sh rounds=5 passed ONLY="" to the settled-page bench, which then measured no scenario and
// printed settled_page.score_max 0, a pass with nothing measured (cmux CI run 45992773246). bench/scenarioFilter.ts.
import { describe, expect, test } from "bun:test";
import { pick } from "../bench/scenarioFilter";

const SCENARIOS = ["chat_switch", "workspace_switch", "open_recent", "restart"] as const;

describe("bench scenario filter", () => {
  test("unset or empty means every scenario", () => {
    expect(pick(SCENARIOS, undefined, "ONLY")).toEqual([...SCENARIOS]);
    expect(pick(SCENARIOS, "", "ONLY")).toEqual([...SCENARIOS]);
    expect(pick(SCENARIOS, " , ", "ONLY")).toEqual([...SCENARIOS]);
  });

  test("a list keeps the bench's order", () => {
    expect(pick(SCENARIOS, "restart,chat_switch", "ONLY")).toEqual(["chat_switch", "restart"]);
  });

  test("an unknown name refuses instead of measuring nothing", () => {
    expect(() => pick(SCENARIOS, "chat_swtich", "ONLY")).toThrow("ONLY: unknown chat_swtich");
  });
});
