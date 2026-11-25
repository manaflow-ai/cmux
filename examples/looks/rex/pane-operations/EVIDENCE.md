# Pane-operation evidence

The action and handler locations below were checked at commit `d878dee81d42668078f9285bfb7c81fde23d2f0e`.

## Native routes

All paths are relative to the repository root.

| ID | Rust catalog | Registered native implementation |
| --- | --- | --- |
| `closePane` | `cmux-tui/crates/cmux-action-catalog/src/catalog/layout.rs:202` | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/PaneHandlers+Verbs.swift:54`; resolves pane, handles creation cancellation/pinned refusal, calls that pane's daemon `closePane`. |
| `pane.closeOthers` | `cmux-tui/crates/cmux-action-catalog/src/catalog/layout.rs:214` | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/PaneHandlers+Verbs.swift:81`; resolves containing screen, excludes focused and pinned panes, closes shown panes through existing close/undo handling and unshown panes on their owning daemon. |
| `pane.moveToNewWorkspace` | `cmux-tui/crates/cmux-action-catalog/src/catalog/workspace_verb.rs:384` | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/WorkspaceStructureHandlers.swift:49`; `movePane(..., newWindow: false)`, first tab creates the new workspace and the rest follow. |
| `pane.moveToNewWindow` | `cmux-tui/crates/cmux-action-catalog/src/catalog/workspace_verb.rs:397` | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/WorkspaceStructureHandlers.swift:50`; `movePane(..., newWindow: true)`, checks native promotion refusal, transfers existing workspace if it has only one pane. |
| `palette.copyPaneID` | `cmux-tui/crates/cmux-action-catalog/src/catalog/tab.rs:804` | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/TabHandlers+More.swift:228`; resolves the pane and copies `pane_id=<id>`. |

Custom keybinding routing uses
`Packages/macOS/CmuxNext/Sources/CmuxNextApp/Focus/KeyRouter+Resolution.swift`:
the resolved user binding names the registry command. The pack references those
commands directly; no shell wrappers, invented action IDs, or extra handlers are
introduced. Runtime dispatch on a particular installed build remains unverified.

Setup and preview follow the sibling packs: `cmux-setup.json`, an adjacent
`keybindings.json`, and a `cmuxProfile: 1` portable profile embedding that file.
The owning loaders are `cmux-tui/crates/cmux-customize/src/setup.rs`,
`setup/reference.rs`, and `library/keys.rs`. The latter composes keybinding entries
by normalized chord. Keep each chord distinct across the combined setup.

## Official release and reference

The supplied extracted release is `0.1.0-snapshot.2077`, source identity
`3ea01c01f5f8adde64bdca1f372009b8ef2a15c3`. The executable in the release contains the following action identifiers at the listed byte offsets.

| Source ID | Offset |
| --- | --- |
| `pane.close` | `1b42990` |
| `pane.copy_id` | `1b429d0` |
| `pane.move_to_tab` | `1d5f280` |
| `pane.move_to_new_tab` | `1d61fb0` |
| `pane.close_others` | `1d61fd0` |

The public [source action reference](https://www.superlogical.com/rex/docs/reference/mac-actions#pane)
is the navigation reference. Identifiers alone do not prove identical behavior
or default chords, so adaptations are labeled in the README.

`references/source-window.webp` is an unchanged copy of the supplied
[official workspace image](https://www.superlogical.com/rex-screenshot@2x.webp), SHA-256:

```text
a7514745119404951bbc14651121640e2d802e2f96da93cb0548d4123f03ab8c
```

The image is a source reference, not a cmux validation capture. No vendor source
code is copied into this package.
