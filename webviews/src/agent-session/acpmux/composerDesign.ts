// The composer's layout designs (UI tournament round 1b, bead cx-9hje; Lawrence 2026-10-09: "i want to see more
// variations of composer ... but i want more minimal versions too"). One composer, several layouts: every design
// keeps every function (prompt, / and @, attachments, dictation, model and effort, access mode, location, context
// ring, send and stop); only where the controls sit and how loud they are changes (composerDesigns.css).
// The host picks one with the `ready` answer's `composerDesign` (the DEV/NIGHTLY setting
// `agentPane.composer.design`); anything unknown is the default.
export const COMPOSER_DESIGNS = ["default", "quiet-line", "two-row", "bare", "stacked"] as const;
export type ComposerDesign = (typeof COMPOSER_DESIGNS)[number];

export function composerDesign(value: unknown): ComposerDesign {
  return COMPOSER_DESIGNS.find((design) => design === value) ?? "default";
}
