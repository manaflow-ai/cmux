import { type StringKey } from "./i18n";

export const COMPOSER_LABELS = {
  placeholder: "composer.placeholder",
  placeholderQueued: "composer.placeholderQueued",
  steerQueueTooltip: "composer.steerQueueTooltip",
  suggestFailing: "composer.suggestFailing",
  suggestDraft: "composer.suggestDraft",
  suggestOpen: "composer.suggestOpen",
  suggestionKey: "composer.suggestionKey",
  suggestionHint: "composer.suggestionHint",
  placeholderSteerQuick: "composer.placeholderSteerQuick",
  add: "composer.add",
  mention: "composer.mention",
  attach: "composer.attach",
  attachScreenshot: "composer.attachScreenshot",
  attachWindow: "composer.attachWindow",
  prompt: "composer.prompt",
  send: "composer.send",
  stop: "composer.stop",
  stopping: "composer.stopping",
  escapeAgainToStop: "composer.escapeAgainToStop",
  commands: "composer.commands",
  noCommands: "composer.noCommands",
  loadingCommands: "composer.loadingCommands",
  noMatchingCommands: "composer.noMatchingCommands",
  attachments: "composer.attachments",
  removeAttachment: "composer.removeAttachment",
  openAttachment: "composer.openAttachment",
  dropFiles: "composer.dropFiles",
  sentAsFileForCodex: "composer.sentAsFileForCodex",
  tooLarge: "composer.tooLarge",
  unsupported: "composer.unsupported",
  imagesUnsupported: "composer.imagesUnsupported",
  cut: "composer.menu.cut",
  copy: "composer.menu.copy",
  paste: "composer.menu.paste",
  pasteAsPlainText: "composer.menu.pasteAsPlainText",
  undo: "composer.menu.undo",
  redo: "composer.menu.redo",
  selectAll: "composer.menu.selectAll",
  attachFiles: "composer.menu.attachFiles",
  insertMention: "composer.menu.insertMention",
  scrollToBottomOnSend: "composer.menu.scrollToBottomOnSend",
  attachmentsInline: "composer.menu.attachmentsInline",
  attachmentsTop: "composer.menu.attachmentsTop",
} as const satisfies Record<string, StringKey>;

/// The `/` menu's line when no command matches: "Loading commands…" while the chat's own list is
/// not read yet (`commandsPending`, or no list at all), "No commands" for a read list that is
/// empty, else "No matching commands". An empty-state line shows only after the read.
/// Only the agent's own commands count: the chat and New Tab lists also hold cmux's commands
/// (cmuxCommands.ts `mergedCommands`, `source: "cmux"`), which are there before any read, so a
/// list of those alone is the agent's empty list ("No commands"), not a list with no match.
export function slashMenuEmptyLabel(
  commands: readonly { source?: string }[] | undefined,
  pending: boolean | undefined,
): (typeof COMPOSER_LABELS)["loadingCommands" | "noCommands" | "noMatchingCommands"] {
  if (pending || commands === undefined) return COMPOSER_LABELS.loadingCommands;
  return commands.some((command) => command.source !== "cmux")
    ? COMPOSER_LABELS.noMatchingCommands
    : COMPOSER_LABELS.noCommands;
}
