// l10n-allow-file: test fixtures, not shipped UI.
//
// RFD 0132's confirm count (confirms.ts): read as the Swift initializer reads the Cloud page's declaration.
import { expect, test } from "bun:test";
import { measureCloudConfirms, readCloudConfirms } from "./confirms";

const swift = (args: string) => `
public extension PageDescriptor {
    static let other = PageDescriptor(id: "x", confirmedOps: ["cmux.x.a": .custom])
    static let cloud = PageDescriptor(
        id: "cmux.cloud", resource: "cloud", namespaces: ["cmux.cloud."],
${args})

    static let settings = PageDescriptor(id: "cmux.settings", confirmedOps: ["cmux.s.a": .custom])
}`;

test("a sheet a click still meets with no guard counts; click-run ops and guarded ones do not", () => {
  const report = readCloudConfirms(
    swift(`        confirmedOps: [
            "cmux.cloud.machine.delete": .delete, // a comment (with parens) and "a quoted": .thing
            "cmux.cloud.snapshot.restore": .custom, "cmux.cloud.auth.sign_in": .custom,
            "cmux.cloud.thing.open": .custom,
        ],
        clickRunsOps: ["cmux.cloud.auth.sign_in", "cmux.cloud.not.confirmed"],
        confirmGuards: ["cmux.cloud.machine.delete": .irreversible, "cmux.cloud.snapshot.restore": .spends,
                        "cmux.cloud.thing.open": .tidy])`),
  );
  expect(report).toEqual({
    confirms_total: 3,
    confirms_guarding_nothing: 1,
    confirms_click_runs: 1,
    confirms: [
      { op: "cmux.cloud.machine.delete", guard: "irreversible" },
      { op: "cmux.cloud.snapshot.restore", guard: "spends" },
      { op: "cmux.cloud.thing.open", guard: null },
    ],
  });
});

test("no Cloud declaration, or one with no confirmedOps, reads as unknown, never as zero", () => {
  expect(readCloudConfirms('static let settings = PageDescriptor(id: "cmux.settings")')).toBeNull();
  expect(readCloudConfirms(swift(`        nativeOps: []`))).toBeNull();
  expect(measureCloudConfirms("/nonexistent/PageDescriptor.swift")).toBeNull();
});

test("the checkout's own Cloud page: every sheet a click still meets names its guard", () => {
  const report = measureCloudConfirms();
  expect(report).not.toBeNull();
  expect(report?.confirms_total).toBeGreaterThan(0);
  expect(report?.confirms_click_runs).toBeGreaterThan(0);
});
