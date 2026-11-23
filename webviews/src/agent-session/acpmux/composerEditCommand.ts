// The host's editing commands for a composer's right-click menu (Composer.tsx `onEdit`). A leaf: a page that
// needs only the name (pages/home-channels/composerEdit.ts) imports it here, not the whole composer.
export type ComposerEditCommand = "cut" | "copy" | "paste" | "pasteAsPlainText";
