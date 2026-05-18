# cmux Extensions

cmux sidebar customization is split into a small Swift SDK and a host-owned
state bridge.

`Packages/CmuxExtensionKit` contains the public data model:

- `CmuxExtensionSidebarSnapshot`: the exact workspace state the host exposes.
- `CmuxExtensionSidebarEvent`: retained state deltas for replay and testing.
- `CmuxExtensionSidebarProviderDescriptor`: selectable sidebar providers.
- `CmuxExtensionSidebarProvider`: a render contract from snapshot to rows.
- `CmuxExtensionSidebarContextualProvider`: an opt-in render contract for
  host-scheduled values such as relative dates.
- `CmuxExtensionSidebarMutation`: typed requests back into the host.

The host owns the source of truth. Extensions should not poll app internals or
invent their own workspace model. They receive a snapshot, optionally apply
events with `CmuxExtensionSidebarReducer`, render rows, then dispatch typed
mutations such as selecting a workspace, creating a worktree, or asking the host
to present UI.

## State Sync

`cmux events` remains the public audit and reconnect stream for external tools.
It is intentionally broader than ExtensionKit and is best for long-lived agents,
CLIs, and logs.

Sidebar extensions use an exact sidebar snapshot plus typed sidebar events. That
keeps UI state deterministic, gives the host one place to redact or normalize
workspace data, and avoids making every extension reconstruct state from a
general event log. Local UI state, such as collapsed sections or popover tab
selection, belongs inside the extension.

The eventual Apple ExtensionKit boundary should preserve the same contract:

1. Host creates the `CmuxExtensionSidebarSnapshot`.
2. Host launches or resumes the ExtensionKit process.
3. Extension renders from SDK types.
4. Extension dispatches `CmuxExtensionSidebarMutation`.
5. Host validates and performs the mutation.

## Current Prototype

The built-in providers are:

- `cmux.sidebar.default`
- `cmux.sidebar.project-tree`
- `cmux.sidebar.attention`
- `cmux.sidebar.servers`
- `cmux.sidebar.last-message`

Right-click the left sidebar button to switch providers. The command palette
also exposes `Sidebar: ...` commands, so `Command-Shift-P` can switch the active
sidebar.

The project-tree provider renders workspace rows through
`CmuxExtensionWorkspaceTreeProvider`. Each row includes a workspace inspector
accessory. The host currently implements the accessory as a popover with:

- `Notes`, persisted by workspace id in local defaults.
- `Browser`, a WebKit view with an omnibar. The first workspace PR URL is only
  used as an initial suggestion when one exists.
- `Open Window`, a host presentation action equivalent to
  `CmuxExtensionSidebarPresentationRequest.openWorkspaceWindow`.

All prototype ExtensionKit providers render through the same virtualized
sidebar path. Row text can be plain, localized, or a host-formatted relative
date. The last-message provider uses `latestSubmittedMessage` and
`latestSubmittedAt` from the workspace snapshot, groups recent messages ahead of
empty workspaces, and lets the host update visible relative timestamps with one
coarse `TimelineView` schedule.

## End-User Shape

A user-provided sidebar should be able to ship a Swift target that imports
`CmuxExtensionKit` and returns a provider:

```swift
import CmuxExtensionKit

struct MySidebar: CmuxExtensionSidebarProvider {
    let descriptor = CmuxExtensionSidebarProviderDescriptor(
        id: "dev.example.my-sidebar",
        title: .init(key: "mySidebar.title", defaultValue: "My Sidebar"),
        subtitle: .init(key: "mySidebar.subtitle", defaultValue: "Local Extension"),
        systemImageName: "square.grid.2x2",
        mode: nil,
        isHostProvided: false
    )

    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        CmuxExtensionSidebarRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }
}
```

Providers that need live host-formatted values can also conform to
`CmuxExtensionSidebarContextualProvider`:

```swift
func render(
    snapshot: CmuxExtensionSidebarSnapshot,
    context: CmuxExtensionSidebarRenderContext
) -> CmuxExtensionSidebarRenderModel {
    // Return .relativeDate(...) text for values the host should refresh.
}
```

The host side still needs the real Apple ExtensionKit loader and sandbox
packaging. The SDK boundary is designed so that loader can be added without
changing the data model end users code against.
