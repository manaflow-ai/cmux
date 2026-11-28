import { describe, expect, test } from "bun:test";
import { disabledReasonLayout } from "../dashboard-app/components/settings-ui/action-menu";

const item = (id: string, disabledReason?: string) => ({ id, label: id, onSelect: () => {}, disabled: disabledReason !== undefined, disabledReason });

// Regression: the only admin's menu repeated "A team needs at least one admin"
// under both disabled items.
describe("action menu disabled reasons", () => {
  test("a reason shared by several disabled items shows once, at the end", () => {
    const layout = disabledReasonLayout([item("makeMember", "Need an admin"), item("leave", "Need an admin")]);
    expect(layout.inline).toEqual({});
    expect(layout.footer).toEqual(["Need an admin"]);
  });

  test("a reason unique to one item stays under that item", () => {
    const layout = disabledReasonLayout([item("a", "Only a"), item("b"), item("c", "Shared"), item("d", "Shared")]);
    expect(layout.inline).toEqual({ a: "Only a" });
    expect(layout.footer).toEqual(["Shared"]);
  });
});
