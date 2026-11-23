// l10n-allow-file: gallery fixtures (font names and notes), not shipped UI.
// cmux Sans's personalities beside the system font, cmux Sans itself and the reference, Folio's sans
// (Hanken Grotesk, the face Leo likes for looking a bit squat), one font each, on the chat
// (SansPersonality.gallery.ts, with the sidebar in the mock app) and on Settings
// (SansPersonalitySettings.gallery.ts). Leo, 2026-11-19: cmux Sans looks "a bit like generic school
// font ... It just doesn't have that like pizzazz"; he likes squat faces. Each font is a font study
// pairing (candidates.ts) and an Interface Font choice (`agentPane.display.font.ui`, chatUiFont.ts).
import { defineExperiment, experimentArm } from "../../experiments/experiment";
import type { Play } from "../play";

/// The six fonts: the variant (and compare arm) name, its font study pairing, its setting value
/// (absent: the default, the system font) and one line about it.
export const SANS_PERSONALITIES = {
  system: {
    pairing: "inter-tuned",
    value: undefined,
    label: "System font",
    note: "The default: the system font (macOS's own; Linux draws its own sans).",
  },
  hanken: {
    pairing: "hanken",
    value: "hanken",
    label: "Hanken Grotesk (Folio's sans, the reference)",
    note: "The reference: Folio's sans, the face Leo likes for looking a bit squat; bundled as the hanken choice.",
  },
  "cmux-sans": {
    pairing: "cmux-sans",
    value: "cmux-sans",
    label: "cmux Sans",
    note: "Today's cmux Sans: Source Sans 3 with an 8 % taller lowercase.",
  },
  squat: {
    pairing: "cmux-sans-squat",
    value: "cmux-sans-squat",
    label: "cmux Sans Squat",
    note: "Squat: 108 % wide, a bigger x-height, a touch heavier.",
  },
  candy: {
    pairing: "cmux-sans-candy",
    value: "cmux-sans-candy",
    label: "cmux Sans Candy",
    note: "Candy: single-storey a, tailed l, 105 % wide, heavier.",
  },
  open: {
    pairing: "cmux-sans-open",
    value: "cmux-sans-open",
    label: "cmux Sans Open",
    note: "Open: cmux Sans spaced like Quillet, looser sidebearings, 4 % wider, a wider word space.",
  },
} as const satisfies Record<string, { pairing: string; value: string | undefined; label: string; note: string }>;
export type SansPersonality = keyof typeof SANS_PERSONALITIES;
export const SANS_PERSONALITY_NAMES = Object.keys(SANS_PERSONALITIES) as SansPersonality[];

/// The compare view's arms (view `compare`): the same screen in each font, side by side. Gallery only:
/// nothing in the app reads this experiment; the pick ships as the Interface Font setting's default
/// or stays a choice.
export const sansPersonality = defineExperiment({
  id: "sans-personality",
  title: "cmux Sans personality",
  description:
    "The same screen in the system font, Folio's sans (Hanken Grotesk, the reference), cmux Sans and its Squat, Candy and Open cuts. Judge the reply, its table and code, the composer and the Settings rows.",
  arms: Object.fromEntries(
    SANS_PERSONALITY_NAMES.map((name) => [
      name,
      { label: SANS_PERSONALITIES[name].label, description: SANS_PERSONALITIES[name].note },
    ]),
  ) as Record<SansPersonality, { label: string; description: string }>,
  defaultArm: "system",
});

/// The compare cell's setup: draws the page in its arm's font (replacing a variant's own).
export const applyArmFont: Play = async (ctx) => {
  const { applyFontStudy } = await import("./apply");
  await applyFontStudy(SANS_PERSONALITIES[experimentArm(sansPersonality)].pairing, ctx.document);
};
