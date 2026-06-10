# Decision Document

Maintain a persistent `xcode-security-settings.md` that records every setting considered, its status, and the rationale. This file is version-controlled and serves as the single source of truth for security build setting decisions.

## Step 1: Locate or Create the File

The skill searches for an existing `xcode-security-settings.md` early in the workflow. If found, its path is known.

1. If the file was already found, use that path. Skip to Step 2.
2. If not found, explain the value of tracking these decisions: "I'd like to create a decision document that records which security settings were enabled, disabled, or deferred, and why. This helps future audits build on past decisions instead of re-evaluating from scratch." Then ask via `AskUserQuestion`: "Where should I place it?" Options: "Project root (next to .xcodeproj)", "docs/ subdirectory", or let the user type a custom path.
3. Create the file with the initial structure (see Document Structure below).
4. Add the file to the Xcode project

## Step 2: Merge Decisions

If an existing document was found, its content is already known. Preserve all user-added content, custom notes, and section organization.

For each setting considered in this run:

- **New entry** (setting not in document) — add to the appropriate section.
- **Status unchanged** — leave the entry untouched.
- **Status changed** (e.g., moved from Deferred to Enabled) — move the entry to the correct section. Preserve the old rationale as context (e.g., "Previously deferred because too noisy. Now enabled after codebase cleanup.").

Never remove entries. The document is append/update only.

All settings must be recorded in this document — it is the single source of truth for security build setting decisions.

Sections:
- **Enabled settings** — settings that are active.
- **Disabled settings** — settings the team decided not to adopt. Always include rationale explaining why.
- **Deferred** — settings considered but not yet enabled. Always include rationale explaining what would need to change.

## Step 3: Write the File

Write the merged document. Report the path: "Decision document updated at `<path>`."

## Document Structure

Use this layout for new files. If the file already exists, follow its existing style.

```markdown
# Xcode Security Settings

Security build settings decisions for [ProjectName].

## Enabled settings

- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`
- `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`
- `ENABLE_ENHANCED_SECURITY`

## Disabled settings

- `GCC_WARN_SIGN_COMPARE`: A lot of `for` loops trigger this.
  The team decided to not adopt this warning because it would involve too many changes.

## Deferred

Settings considered but not yet enabled. Revisit them later.

- `CLANG_WARN_ASSIGN_ENUM`: The findings seem relevant.
- `CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`:
  Too noisy with current generated code.
  Revisit after generated code is excluded from analysis.
- `ENABLE_C_BOUNDS_SAFETY`:
  Requires annotation-based programming model.
  It needs careful adoption planning.
```

Entry format: "- `SETTING_NAME` [to `VALUE`]: Rationale"

Omit the `to VALUE` part for settings that are enabled, unless we have some relevant rationale to state.
For example, if the setting was disabled in the past, we can mention that and why it was enabled now.
Usually, disabled settings or deferred settings need explanation.
