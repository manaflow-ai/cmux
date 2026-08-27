---
name: cmux-dev-workflow
description: "Contributor workflow rules for cmux setup, Xcode project normalization, tagged sidebar ExtensionKit development, and dev builds. Use when setting up the cmux repo, changing Xcode project files, adding sidebar extensions, or working with tagged debug builds."
---

# cmux Dev Workflow

## Initial setup

`./scripts/setup.sh` initializes submodules, builds GhosttyKit, and installs the pbxproj normalization pre-commit hook.

## Tagged local dev

Build the Debug app after every code change:

```bash
./scripts/reload.sh --tag <short-tag>
```

It builds without launching; pass `--launch` only when you need the app open. Never run bare `xcodebuild` or open an untagged `cmux DEV.app`: untagged builds share the default debug socket and bundle ID with other agents, causing conflicts and stealing focus.

For CLI or socket dogfood against a tagged Debug app:

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
```

Do not use `/tmp/cmux-cli` for tagged dogfood; that symlink points at the most recently reloaded build. See [references/tagged-builds.md](references/tagged-builds.md).

## Xcode toolchain

The team is pinned to Xcode 26.x. `.xcode-version` is the single source of truth for the major; `cmux.xcodeproj/project.pbxproj` carries `objectVersion = 60`, what Xcode 26 writes by default. (`objectVersion = 77` is reserved for synchronized folder groups, which cmux does not use.)

`scripts/setup.sh` installs the tracked `scripts/git-hooks/pre-commit`, which runs `scripts/normalize-pbxproj.py` on any staged `project.pbxproj` so Xcode's nondeterministic reordering never reaches a commit. The hook is idempotent. CI runs `scripts/check-pbxproj.sh` to enforce both the `objectVersion` pin and normalization, so skipping the hook gives a clear PR failure. Bumping the pin is a deliberate team decision: see [references/xcode-project-normalization.md](references/xcode-project-normalization.md).

## Sidebar extension point (dev tagging)

Each tagged dev build gets its own ExtensionKit sidebar extension point so concurrent dev builds do not collide. Three build settings drive it:

- `CMUX_SIDEBAR_EXTENSION_POINT_ID` (default `com.cmuxterm.app.cmux.sidebar`): the extension point identifier baked into Info.plist at build time.
- `CMUX_BUNDLE_ID_SUFFIX` (default empty): inserted into the app and appex bundle ids so a tagged extension gets a distinct identity that pkd records separately.
- `CMUX_DISPLAY_NAME_SUFFIX` (default empty): appended to the appex `CFBundleDisplayName`. The OS groups sidebar extensions by display name for the enable/disable and availability counts the host reads, so two same-named appexes installed side by side are treated as one logical extension and toggling one perturbs the other.

The host resolves its point id at runtime from the Info.plist key `CMUXSidebarExtensionPointIdentifier` via `CmuxSidebarExtensionPoint.identifier(in:)`. `./scripts/reload.sh --tag <tag>` scopes the host point to `com.cmuxterm.app.debug.<tag>.cmux.sidebar`. Build a matching tag-scoped sample extension with:

```bash
./scripts/reload-extension.sh --tag <tag> [--host-bundle-id <id>] [--example sample|tabs|both]
```

See [references/sidebar-extension-tagging.md](references/sidebar-extension-tagging.md) for the settings it passes, the no-re-signing rule, and the checklist for authoring a new tag-ready sample extension.
