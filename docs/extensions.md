# cmux Extensions

## Custom sidebars

cmux can load a custom left sidebar from Swift source without rebuilding the app.
Right-click the sidebar icon, choose **Load Custom Sidebar**, and select either a
`.swift` file or a folder of Swift files.

cmux imports the selected source into the standard custom sidebar location:

```text
~/.config/cmux/sidebars/
```

The imported source is compiled into a small executable under:

```text
~/Library/Application Support/cmux/SwiftSidebarExtensions/
```

The executable links against the `CmuxExtensionKit` source bundled in the cmux
app. The selected Swift source can import `CmuxExtensionKit`, provide a
`CmuxExtensionSidebarProvider`, then hand control to the executable bridge:

```swift
import CmuxExtensionKit

struct MySidebar: CmuxExtensionSidebarProvider {
    let descriptor = CmuxExtensionSidebarProviderDescriptor(
        id: "my.sidebar",
        title: CmuxExtensionLocalizedText(key: "my.sidebar.title", defaultValue: "My Sidebar"),
        subtitle: CmuxExtensionLocalizedText(key: "my.sidebar.subtitle", defaultValue: "Custom sidebar"),
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

Use **Reload Custom Sidebar** from the same right-click menu after editing the
source under `~/.config/cmux/sidebars/`. Use **Remove Custom Sidebar** to return
to the built-in sidebar.

You can also load a sidebar from the CLI:

```bash
cmux custom-sidebar load ./Sidebar.swift
cmux custom-sidebar load ~/.config/cmux/sidebars/my-sidebar
cmux load-custom-sidebar ./Sidebar.swift
```

`cmux custom-sidebar path` prints the standard source directory, and
`cmux custom-sidebar docs` prints this docs URL.

For multiple files, put them in a folder and include either a `main.swift` file
with the executable bridge call or an `@main` type. cmux copies Swift source files
from the folder into the generated SwiftPM target and ignores `Package.swift`,
`.build`, `.git`, and `.swiftpm`.

Apple ExtensionKit is still the native UI extension lane for signed app
extensions. Custom sidebars use `CmuxExtensionKit` in a separate executable
instead, which keeps user code out of the cmux process and avoids a full cmux
rebuild.
