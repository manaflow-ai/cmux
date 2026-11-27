// RFD 0140's status icon gallery is a contract: every semantic state appears in each design,
// with Spaces both hidden and shown. Keep the check browser-free so a missing matrix arm fails in
// the ordinary web test tier before an expensive capture run.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { AUTO_CLOUD_MATRIX_DESIGNS, AUTO_CLOUD_MATRIX_STATES } from "../src/sidebar/autocloudStatusMatrix";

const sidebar = path.resolve(import.meta.dir, "../src/sidebar");
const gallery = path.resolve(import.meta.dir, "../scripts/gallery/autocloud-status.capture.json");

test("AutoCloud status gallery covers every state, design, and Spaces arm", () => {
  const fixtures = JSON.parse(readFileSync(path.join(sidebar, "autocloudStatus.fixtures.json"), "utf8")) as {
    id: string;
  }[];
  const fixtureIds = new Set(fixtures.map(({ id }) => id));
  expect(new Set(AUTO_CLOUD_MATRIX_STATES).size).toBe(AUTO_CLOUD_MATRIX_STATES.length);
  expect(AUTO_CLOUD_MATRIX_STATES.every((state) => fixtureIds.has(state))).toBe(true);
  expect(AUTO_CLOUD_MATRIX_DESIGNS).toEqual(["glyph", "pill", "split", "strip"]);

  const spec = JSON.parse(readFileSync(gallery, "utf8")) as {
    shots: { name: string; entry: string; variant: string }[];
  };
  const matrixShots = spec.shots.filter((shot) => shot.entry === "sidebar.autocloud-status-matrix");
  expect(matrixShots.map(({ variant }) => variant).sort()).toEqual(["spaces-off", "spaces-on"]);
  expect(new Set(matrixShots.map(({ name }) => name)).size).toBe(2);

  const designShots = spec.shots.filter((shot) => shot.entry === "sidebar.autocloud-status");
  for (const design of AUTO_CLOUD_MATRIX_DESIGNS) {
    expect(designShots.some(({ variant }) => variant === `${design}-popover`)).toBe(true);
    expect(designShots.some(({ variant }) => variant === `${design}-spaces`)).toBe(true);
  }
});
