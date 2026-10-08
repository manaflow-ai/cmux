// l10n-allow-file: gallery fixtures (sample paths), not shipped UI.
// Changed-file lists for the changes tree's gallery entries: plain data of the real TurnFile.
import type { TurnFile } from "../../agent-session/acpmux/diff";

/** One changed file with fixed counts (no edits: the tree reads only paths and counts). */
export function changedFile(path: string, additions: number, deletions: number): TurnFile {
  return { path, displayPath: path, edits: [], additions, deletions, created: deletions === 0 };
}

/** Counts that vary by index but are the same in every run. */
const counts = (index: number): [number, number] => [
  ((index * 37) % 90) + 1,
  (index * 11) % 7 === 0 ? 0 : (index * 13) % 40,
];

const files = (folder: string, names: string[], from: number) =>
  names.map((name, offset) => changedFile(`${folder}/${name}`, ...counts(from + offset)));

const numbered = (prefix: string, count: number, extension: string) =>
  Array.from({ length: count }, (_, index) => `${prefix}${String(index + 1).padStart(2, "0")}${extension}`);

/**
 * 200 files. `app/components` (folder A in the scripts) holds 14 files, `forms` (folder B, 8 files)
 * and `icons` (10 files), so opening it pushes rows out of a 600 px column.
 */
export const MANY_FILES: TurnFile[] = [
  ...files("app/components", numbered("Panel", 14, ".tsx"), 0),
  ...files("app/components/forms", numbered("Field", 8, ".tsx"), 14),
  ...files("app/components/icons", numbered("Icon", 10, ".tsx"), 22),
  ...files("app/lib", numbered("util", 30, ".ts"), 32),
  ...files("app/pages", numbered("route", 26, ".tsx"), 62),
  ...files("app/server/api", numbered("handler", 30, ".ts"), 88),
  ...files("tests/unit", numbered("case", 34, ".test.ts"), 118),
  ...files("tests/e2e", numbered("flow", 18, ".spec.ts"), 152),
  ...files("docs", numbered("guide", 20, ".md"), 170),
  ...files("scripts", numbered("task", 10, ".sh"), 190),
];

/** Long file and folder names: clipped with a fade at the end, scrolled on hover or focus. */
export const LONG_NAMES: TurnFile[] = [
  changedFile("src/components/forms/AccountRecoveryVerificationCodeInputField.test.tsx", 124, 18),
  changedFile("src/components/forms/AccountRecoveryVerificationCodeInputField.tsx", 61, 9),
  changedFile("src/components/forms/Field.tsx", 3, 1),
  changedFile("src/integrations/third-party-identity-provider-configuration/oauth-callback-handler.ts", 48, 30),
  changedFile("src/integrations/third-party-identity-provider-configuration/saml.ts", 12, 0),
  changedFile("docs/architecture/2026-10-07-decision-record-for-the-agent-pane-changes-tree.md", 210, 0),
  changedFile("README.md", 4, 2),
  changedFile("src/very_long_snake_case_module_name_that_keeps_going_and_going.py", 77, 41),
];

/** Only names far wider than any pane: the fade and the marquee at their limits. */
export const VERY_LONG_NAMES: TurnFile[] = [
  changedFile(
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneReplyLinkChipOutsideRootsConfirmationSheetPresentationController+AccessibilityAndKeyboardNavigation.swift",
    1204,
    388,
  ),
  changedFile(
    "Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPaneReplyLinkChipOutsideRootsConfirmationSheetPresentationControllerAccessibilityAndKeyboardNavigationTests.swift",
    96,
    0,
  ),
  changedFile(
    "webviews/src/agent-session/acpmux/changes/an-extremely-long-folder-name-that-is-wider-than-the-whole-changes-column-on-purpose/and-another-nested-folder-with-an-even-longer-descriptive-name-for-testing/component.tsx",
    15,
    7,
  ),
  changedFile(
    "fixtures/screenshots/2026-10-07T21-43-12.884Z-agent-pane-transcript-long-reply-with-many-tool-calls-and-edited-files-card-dark-theme-monokai-classic-1280x800@2x.png",
    0,
    0,
  ),
  changedFile(
    "src/ReallyLongCamelCaseNameWithoutAnySeparatorsOrSpacesSoTheBrowserCannotBreakItAnywhereAtAll.ts",
    33,
    2,
  ),
  changedFile(
    "docs/日本語のとても長いファイル名でフェードとマーキーが正しく動くかを確認するためのテスト用ドキュメント.md",
    8,
    1,
  ),
  changedFile(
    "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z/deeply-nested-file-at-the-end-of-twenty-six-folders.rs",
    1,
    1,
  ),
];
