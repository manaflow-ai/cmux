// The composer's parts as tests and galleries find them in the DOM. One spelling per part;
// scripts/check-pane-selectors.ts refuses these strings typed raw in a test or gallery and names the
// constant to import.

/// The composer's editable prompt (the ProseMirror field inside .acpmux-composer-prompt).
export const COMPOSER_EDITOR = ".acpmux-composer-prompt [contenteditable='true']";
/// The Markdown field inside the composer box.
export const COMPOSER_MD = ".acpmux-composer-box .acpmux-md";
/// The Markdown field's custom element inside the composer box.
export const COMPOSER_MD_FIELD = ".acpmux-composer-box .acpmux-md-field";
/// The model picker's button in the composer foot.
export const MODEL_PICKER = ".acpmux-model .acpmux-picker-button";
/// The composer's + menu button.
export const PLUS_PICKER = ".acpmux-composer-plus .acpmux-picker-button";
/// The dock (composer and its trays) directly under the pane's main column.
export const MAIN_DOCK = ".acpmux-main > .acpmux-dock";
