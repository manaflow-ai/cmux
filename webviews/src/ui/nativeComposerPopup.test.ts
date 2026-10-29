import { expect, test } from "bun:test";
import { popupAction } from "./popupDescriptors";
import { popupChoice, popupIdentity, popupSection } from "../agent-session/acpmux/nativeComposerPopup";

test("composer native menu rows match the generated host action contract", () => {
  const rows = [
    ...popupSection(
      popupIdentity("mode-heading"),
      "Modes",
      [
        popupChoice(popupIdentity("mode", "full-access"), "Full access", {
          checked: true,
          shortcut: "1",
        }),
      ],
    ),
    ...popupSection(
      popupIdentity("mode-heading", "options"),
      "Options",
      [
        popupChoice(popupIdentity("option", "full-access", "fast"), "Fast", {
          checked: false,
        }),
      ],
    ),
  ];
  const ids = rows.map((row) => row.id);
  expect(new Set(ids).size).toBe(ids.length);
  expect(rows.every((row) => row.id.length > 0 && row.id.length <= 128)).toBe(true);
  expect(rows.filter((row) => row.kind === "section")).toHaveLength(2);
  expect(rows.filter((row) => row.kind === "action")).toHaveLength(2);
  expect(rows.every((row) => row.children === undefined && row.options === undefined)).toBe(true);
  const model = { rows };
  for (const row of rows.filter((candidate) => candidate.kind === "action")) {
    expect(popupAction(model, row.id)).toMatchObject({ id: row.id, keepOpen: false });
  }
});
