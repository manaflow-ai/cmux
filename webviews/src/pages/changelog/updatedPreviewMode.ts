// Where the "cmux Updated!" card shows the update's changes (UpdatedCardPreviewMode.swift, Debug
// Settings `sidebar.updatedCard.preview`). The host sends a look other than the shipped one in the
// theme's `updated-card-preview` slot; the shipped page reads no attribute.
//
// Lawrence 2026-11-07, on the list that grew up out of the bottom card over the sidebar: "i dont
// like how it expands upwards, also it looks very bad". The shipped look keeps the card still and
// opens its changes beside the sidebar, in the app's hover card window (the native host opens it;
// the page is `#/surface/updated-notes`, UpdatedNotes.tsx).

/**
 * - `beside`: the card rests as it is; its changes open beside the sidebar (shipped).
 * - `beside-titles`: the same, each change's title alone.
 * - `version`: the card's second line is the full version; its changes open beside the sidebar.
 * - `quiet`: no change list; the card's second line is See What's New.
 * - `above`: the list grows up out of the card over the sidebar's rows (the look before).
 */
export type UpdatedPreviewMode = "beside" | "beside-titles" | "version" | "quiet" | "above";

export const SHIPPED_PREVIEW_MODE: UpdatedPreviewMode = "beside";

const MODES: readonly UpdatedPreviewMode[] = ["beside", "beside-titles", "version", "quiet", "above"];

/** The look the theme's slot names; the shipped one without a slot or with a name it does not know. */
export function parsePreviewMode(value: string | null | undefined): UpdatedPreviewMode {
  return MODES.find((mode) => mode === value) ?? SHIPPED_PREVIEW_MODE;
}
