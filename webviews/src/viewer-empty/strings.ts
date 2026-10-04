// Every string key of the viewer empty states and the path picker. Values live in
// `Localizable.xcstrings` next to this file; scripts/pages/gen-strings.mjs writes
// `generated/strings.json`.
import { createStrings, type Strings } from "../pages/shared/i18n";
import table from "./generated/strings.json";

export const E = {
  recentHeading: "recent.heading",
  recentReposLabel: "recent.reposLabel",
  recentFilesLabel: "recent.filesLabel",
  recentReposEmpty: "recent.reposEmpty",
  recentFilesEmpty: "recent.filesEmpty",
  diffTitle: "diff.title",
  diffSubtitle: "diff.subtitle",
  diffChoose: "diff.choose",
  markdownTitle: "markdown.title",
  markdownSubtitle: "markdown.subtitle",
  markdownChoose: "markdown.choose",
  dropFolder: "drop.folder",
  dropFile: "drop.file",
  errorNotRepo: "error.notRepo",
  errorNotMarkdown: "error.notMarkdown",
  errorOpen: "error.open",
  sourceHeading: "source.heading",
  sourceBranchHelp: "source.branchHelp",
  sourceUncommittedHelp: "source.uncommittedHelp",
  sourceStagedHelp: "source.stagedHelp",
  sourceUnstagedHelp: "source.unstagedHelp",
  sourceOpen: "source.open",
  sourceChange: "source.change",
  back: "action.back",
  opening: "action.opening",
  pickerFolderTitle: "picker.folderTitle",
  pickerFileTitle: "picker.fileTitle",
  pickerPlaceholder: "picker.placeholder",
  pickerEmptyFolder: "picker.emptyFolder",
  pickerEmptyFile: "picker.emptyFile",
  pickerNoMatches: "picker.noMatches",
  pickerFailed: "picker.failed",
  pickerLoading: "picker.loading",
  pickerMore: "picker.more",
  pickerChooseThis: "picker.chooseThis",
  pickerCancel: "picker.cancel",
  pickerHintOpen: "picker.hintOpen",
  pickerHintUp: "picker.hintUp",
  pickerHintChoose: "picker.hintChoose",
  pickerGit: "picker.git",
  pickerRecent: "picker.recent",
  pickerLocation: "picker.location",
} as const;

/** The empty-state strings in the page's language (`languages` overrides the navigator's). */
export function viewerEmptyStrings(languages?: readonly string[]): Strings {
  return createStrings(table, languages);
}
