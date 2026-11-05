/// The soft band at a long draft's scrolled edges (markdownField.css reads it as
/// `--acpmux-md-fade-band`). The caret reveal keeps the caret this far from the field's edge, so the
/// caret's line never sits in the fade. The attachment row above the prompt fades its scrolled sides
/// by the same band (composer/attachmentIntake.tsx).
export const FADE_BAND_PX = 18;
