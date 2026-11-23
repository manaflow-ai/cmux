import { describe, expect, test } from "bun:test";
import { hintsRevealed, outcomeHintsFor, setHintsRevealed } from "./composerOutcomeHintsModel";

// Leo 2026-11-22 09:50Z: "50020 prob dont do as default ... but this is good as tips".
describe("composer outcome hints", () => {
  test("today's arm and the tip arms show nothing until asked", () => {
    for (const arm of ["now", "tip", "hint", "option"]) {
      expect(outcomeHintsFor(arm, false)).toEqual({ rows: false, placeholder: undefined });
    }
    // The tip arm's tip carries the words; its rows and placeholder stay today's.
    expect(outcomeHintsFor("tip", true)).toEqual({ rows: false, placeholder: undefined });
  });

  test("the ? and Option arms show the rows and the long placeholder on demand", () => {
    expect(outcomeHintsFor("hint", true)).toEqual({ rows: true, placeholder: "modes" });
    expect(outcomeHintsFor("option", true)).toEqual({ rows: true, placeholder: "modes" });
  });

  test("round 1's arms keep their looks", () => {
    expect(outcomeHintsFor("agent", false)).toEqual({ rows: false, placeholder: "agent" });
    expect(outcomeHintsFor("modes", false)).toEqual({ rows: false, placeholder: "modes" });
    expect(outcomeHintsFor("outcomes", false)).toEqual({ rows: true, placeholder: "modes" });
  });

  test("the ? toggles for the page", () => {
    expect(hintsRevealed()).toBe(false);
    setHintsRevealed(true);
    expect(hintsRevealed()).toBe(true);
    setHintsRevealed(false);
    expect(hintsRevealed()).toBe(false);
  });
});
