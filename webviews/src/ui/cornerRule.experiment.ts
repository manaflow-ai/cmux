// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/// Corners by one rule (Instrument v0.1, design debate 2026-11-22): a card 12, the composer 16, a
/// popup and a toast 12, and a corner inside another is the inner corner plus the gap between them
/// (popup 12 = row 8 + inset 4, composer 16 = control 8 + inset 8). desktop.ts puts the arm on
/// `<html>` as data-corner-rule; the classic arm draws the corners from before the rule (card 14 and
/// the surface card 10, composer 12 in the grid and 18 on the design scale, popup 8, toast 9 by its
/// role and 16 drawn). To switch back, set `cmux.experiments` to `{"corner-rule":"classic"}` in the
/// page's web inspector and reload.
export const cornerRule = defineExperiment({
  id: "corner-rule",
  title: "Corner rule",
  description:
    "The corner every card, composer, popup and toast draws. Instrument puts them on one rule (card 12, composer 16, popup and toast 12, a nested corner the inner corner plus the gap); Classic draws the corners from before it.",
  arms: {
    instrument: {
      label: "Instrument",
      description: "Card 12, composer 16, popup 12 with 8 rows, toast 12.",
    },
    classic: {
      label: "Classic",
      description: "Card 14 (surface card 10), composer 12 (design scale 18), popup 8 with 4 rows, toast 9 by role and 16 drawn.",
    },
  },
  defaultArm: "instrument",
});

export const CORNER_RULE_ATTRIBUTE = "data-corner-rule";
