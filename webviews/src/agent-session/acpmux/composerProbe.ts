// The composer's render count for `cmux app chat drive` (chatDrive.ts). `render` is null except
// while a drive runs: at rest a composer render pays one property read and no call.

/** Which part rendered: the composer (Composer.tsx's frame) or its box (ComposerBox.tsx). */
export type ComposerPart = "composer" | "box";

export const composerProbe: { render: ((part: ComposerPart) => void) | null } = { render: null };
