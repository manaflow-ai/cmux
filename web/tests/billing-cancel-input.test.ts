import { describe, expect, test } from "bun:test";
import { cancelInput } from "../dashboard-app/screens/billing/cancel-plan-dialog";

describe("cancel dialog input", () => {
  test("no reason picked sends no reason", () => {
    expect(cancelInput({ teamId: undefined, reason: null, detail: "ignored" })).toEqual({});
  });

  test("a picked reason is sent; detail only for Other", () => {
    expect(cancelInput({ teamId: "t1", reason: "too_expensive", detail: "x" })).toEqual({ teamId: "t1", reason: { code: "too_expensive" } });
    expect(cancelInput({ teamId: undefined, reason: "other", detail: "  moving on  " })).toEqual({ reason: { code: "other", detail: "moving on" } });
    expect(cancelInput({ teamId: undefined, reason: "other", detail: "   " })).toEqual({ reason: { code: "other" } });
  });
});
