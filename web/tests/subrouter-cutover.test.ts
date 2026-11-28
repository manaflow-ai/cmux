import { describe, expect, test } from "bun:test";

import { hostedSubrouterCutoverReadyForTeam } from "../services/subrouter/cutover";

describe("hosted Subrouter cutover gate", () => {
  test("allows new teams with no legacy mapping", async () => {
    await expect(
      hostedSubrouterCutoverReadyForTeam("team-new", async () => undefined),
    ).resolves.toBe(true);
  });

  test("blocks a legacy mapping until the migration operator marks it ready", async () => {
    await expect(
      hostedSubrouterCutoverReadyForTeam(
        "team-legacy",
        async () => ({ hostedReadyAt: null }),
      ),
    ).resolves.toBe(false);
  });

  test("allows a legacy mapping after its hosted copy is verified", async () => {
    await expect(
      hostedSubrouterCutoverReadyForTeam(
        "team-ready",
        async () => ({ hostedReadyAt: new Date("2026-08-03T00:00:00Z") }),
      ),
    ).resolves.toBe(true);
  });
});
