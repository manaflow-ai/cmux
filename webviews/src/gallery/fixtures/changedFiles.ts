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

/** One file for each common language and file type, for the file icons. */
export const LANGUAGE_FILES: TurnFile[] = [
  changedFile("src/main.rs", 7, 0),
  changedFile("src/server.go", 8, 1),
  changedFile("app/models.py", 9, 2),
  changedFile("lib/tasks.rb", 10, 3),
  changedFile("src/Main.java", 11, 4),
  changedFile("app/src/MainActivity.kt", 12, 5),
  changedFile("Sources/App.swift", 13, 6),
  changedFile("Sources/Bridge.m", 14, 7),
  changedFile("Sources/Bridge.mm", 15, 8),
  changedFile("src/index.ts", 16, 0),
  changedFile("src/App.tsx", 17, 1),
  changedFile("src/legacy.js", 18, 2),
  changedFile("src/Widget.jsx", 19, 3),
  changedFile("src/config.mjs", 20, 4),
  changedFile("src/old.cjs", 21, 5),
  changedFile("native/core.c", 22, 6),
  changedFile("native/engine.cpp", 23, 7),
  changedFile("native/engine.h", 24, 8),
  changedFile("native/engine.hpp", 25, 0),
  changedFile("src/Program.cs", 26, 1),
  changedFile("src/Program.fs", 27, 2),
  changedFile("public/index.php", 28, 3),
  changedFile("scripts/plugin.lua", 29, 4),
  changedFile("src/allocator.zig", 30, 5),
  changedFile("lib/app.ex", 31, 6),
  changedFile("test/app_test.exs", 32, 7),
  changedFile("src/Main.hs", 33, 8),
  changedFile("src/Main.scala", 34, 0),
  changedFile("lib/main.dart", 35, 1),
  changedFile("src/main.cr", 36, 2),
  changedFile("src/main.nim", 37, 3),
  changedFile("src/main.v", 38, 4),
  changedFile("src/Main.elm", 39, 5),
  changedFile("src/core.clj", 40, 6),
  changedFile("src/app.erl", 41, 7),
  changedFile("src/main.ml", 42, 8),
  changedFile("analysis/model.r", 43, 0),
  changedFile("analysis/model.jl", 44, 1),
  changedFile("db/schema.sql", 45, 2),
  changedFile("db/migrate.prisma", 46, 3),
  changedFile("scripts/deploy.sh", 7, 4),
  changedFile("scripts/setup.zsh", 8, 5),
  changedFile("scripts/env.fish", 9, 6),
  changedFile("scripts/build.ps1", 10, 7),
  changedFile("scripts/run.bat", 11, 8),
  changedFile("config/app.yml", 12, 0),
  changedFile("config/app.yaml", 13, 1),
  changedFile("package.json", 14, 2),
  changedFile("tsconfig.jsonc", 15, 3),
  changedFile("Cargo.toml", 16, 4),
  changedFile("pyproject.toml", 17, 5),
  changedFile("settings.ini", 18, 6),
  changedFile(".env.example", 19, 7),
  changedFile("docs/guide.md", 20, 8),
  changedFile("docs/notes.mdx", 21, 0),
  changedFile("docs/spec.rst", 22, 1),
  changedFile("docs/README.txt", 23, 2),
  changedFile("web/index.html", 24, 3),
  changedFile("web/styles.css", 25, 4),
  changedFile("web/theme.scss", 26, 5),
  changedFile("web/theme.less", 27, 6),
  changedFile("web/App.vue", 28, 7),
  changedFile("web/App.svelte", 29, 8),
  changedFile("web/Page.astro", 30, 0),
  changedFile("proto/api.proto", 31, 1),
  changedFile("schema/api.graphql", 32, 2),
  changedFile("infra/main.tf", 33, 3),
  changedFile("infra/flake.nix", 34, 4),
  changedFile("Dockerfile", 35, 5),
  changedFile("Makefile", 36, 6),
  changedFile("CMakeLists.txt", 37, 7),
  changedFile("build.gradle", 38, 8),
  changedFile("pom.xml", 39, 0),
  changedFile("assets/logo.svg", 40, 1),
  changedFile("assets/hero.png", 41, 2),
  changedFile("assets/photo.jpg", 42, 3),
  changedFile("assets/demo.gif", 43, 4),
  changedFile("docs/report.pdf", 44, 5),
  changedFile("wasm/module.wasm", 45, 6),
  changedFile("data/records.csv", 46, 7),
  changedFile("data/events.jsonl", 7, 8),
  changedFile("data/blob.bin", 8, 0),
  changedFile("keys/cert.pem", 9, 1),
  changedFile(".gitignore", 10, 2),
  changedFile(".editorconfig", 11, 3),
  changedFile("LICENSE", 12, 4),
  changedFile("bun.lock", 13, 5),
];
