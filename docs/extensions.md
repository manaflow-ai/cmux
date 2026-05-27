# cmux Extensions

## Swift sidebar files

cmux can load a custom left sidebar from a Swift file without rebuilding the app.
Right-click the sidebar icon, choose **Load Swift Sidebar...**, and select a
`.swift` file.

The file is compiled into a small executable in:

```text
~/Library/Application Support/cmux/SwiftSidebarExtensions/
```

The executable links against the `CmuxExtensionKit` source bundled in the cmux
app. The selected Swift file can import `CmuxExtensionKit`, provide a
`CmuxExtensionSidebarProvider`, then hand control to the executable bridge:

```swift
import CmuxExtensionKit

struct MySidebar: CmuxExtensionSidebarProvider {
    let descriptor = CmuxExtensionSidebarProviderDescriptor(
        id: "my.sidebar",
        title: CmuxExtensionLocalizedText(key: "my.sidebar.title", defaultValue: "My Sidebar"),
        subtitle: CmuxExtensionLocalizedText(key: "my.sidebar.subtitle", defaultValue: "Swift file"),
        systemImageName: "sidebar.left",
        isHostProvided: false
    )

    func render(snapshot: CmuxExtensionSidebarSnapshot) -> CmuxExtensionSidebarRenderModel {
        let section = CmuxExtensionSidebarRenderSection(
            id: "all",
            treeSection: CmuxExtensionWorkspaceTreeSection(
                id: "all",
                title: "Workspaces",
                subtitle: nil,
                systemImageName: "rectangle.stack",
                projectRootPath: nil,
                workspaceIds: snapshot.workspaceIds
            ),
            rows: snapshot.workspaces.map { workspace in
                CmuxExtensionSidebarRenderRow(
                    id: workspace.id,
                    title: workspace.title,
                    workspaceId: workspace.id,
                    accessory: .inspector
                )
            }
        )
        return CmuxExtensionSidebarRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: [section]
        )
    }
}

try CmuxExtensionSidebarExecutable.run(provider: MySidebar())
```

Use **Reload Swift Sidebar** from the same right-click menu after editing the
file. Use **Remove Swift Sidebar** to return to the built-in sidebar.

Apple ExtensionKit is still the native UI extension lane for signed app
extensions. A single Swift source file is compiled as a separate executable
instead, which keeps user code out of the cmux process and avoids a full cmux
rebuild.
