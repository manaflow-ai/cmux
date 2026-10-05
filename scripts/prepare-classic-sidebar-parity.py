#!/usr/bin/env python3
"""Prepare an immutable private dogfood pair, preserving every owner worktree.

The output contains source archives, explicit integration patches and source
hashes. Git metadata belongs exclusively to the private build artifact, so the
canonical build scripts can stamp provenance and fetch its exact SDK snapshot.
This script does not build, install, launch, register an extension, or touch any
running app. Production activation remains outside this artifact.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile


def git(root, *arguments):
    return subprocess.run(["git", "-C", str(root), *arguments], check=True,
                          capture_output=True).stdout


def replace(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise ValueError(f"Integration anchor changed: {path.name}: {old[:60]!r}")
    path.write_text(text.replace(old, new))


def archive(source, destination):
    commit = git(source, "rev-parse", "HEAD").decode().strip()
    data = git(source, "archive", commit)
    destination.mkdir()
    with tarfile.open(fileobj=io.BytesIO(data)) as content:
        content.extractall(destination, filter="data")
    return commit


def make_snapshot_repository(stage, source, commit):
    metadata = stage.parent / (stage.name + ".git")
    subprocess.run(["git", "init", "--bare", str(metadata)], check=True, capture_output=True)
    common = Path(git(source, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip())
    (metadata / "objects/info/alternates").write_text(str(common / "objects") + "\n")
    (metadata / "HEAD").write_text(commit + "\n")
    (stage / ".git").write_text("gitdir: " + str(metadata) + "\n")
    git(stage, "config", "core.bare", "false")
    git(stage, "config", "core.worktree", str(stage))
    # An artifact snapshot has no repo hooks: it is not a delivery commit and
    # cannot consume another registered mission's locks or run production hooks.
    hooks = metadata / "artifact-hooks"
    hooks.mkdir()
    git(stage, "config", "core.hooksPath", str(hooks))
    git(stage, "read-tree", commit)


def copy_additions(source, stage, paths):
    for path in paths:
        destination = stage / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        original = source / path
        if not original.exists(): original = source / "integrations/native-sidebar-parity" / path
        shutil.copy2(original, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmux-base", type=Path, required=True)
    parser.add_argument("--cortex-base", type=Path, required=True)
    parser.add_argument("--cmux-additions", type=Path, required=True)
    parser.add_argument("--cortex-additions", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reuse-existing", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    if args.reuse_existing:
        previous = json.loads((output / "receipt.json").read_text())
        if previous.get("productionActivationAllowed") is not False or previous.get("sourceArchivesIncludeForeignWIP") is not False:
            raise ValueError("Only an isolated immutable source artifact can be reused")
        cmux, cortex = output / "cmux", output / "Cortex"
        cmux_sha, cortex_sha = previous["cmuxBaseSHA"], previous["cortexBaseSHA"]
        paths = {
            cmux: ["Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Manifest/CMUXExtensionScope.swift", "Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CMUXSidebarAction.swift", "Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CmuxSidebarHost.swift", "Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CMUXSidebarSnapshot.swift", "Sources/ContentView.swift", "cmux.xcodeproj/project.pbxproj", "Sources/SidebarExtensionManagementCoordinator.swift", "Sources/Sidebar/AppKitList/Cells/SidebarGroupHeaderRowView.swift", "Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowCommands.swift"],
            cortex: ["Sources/CortexSessionsExtension/CortexSessionsExtension.swift", "Sources/CortexSessionsExtension/SessionsSidebarModel.swift", "Sources/CortexSessionsExtension/SidebarRootView.swift", "Sources/CortexSessionsExtension/CompactWorkspaceRowView.swift", "Sources/CortexSessionsExtension/SidebarChrome.swift", "scripts/verify-sidebar-layout.sh", "Project.swift"]}
        paths[cmux].append("Sources/TerminalController.swift")
        for stage, files in paths.items():
            revision = cmux_sha if stage == cmux else cortex_sha
            for path in files: (stage / path).write_bytes(git(stage, "show", revision + ":" + path))
    else:
        output.mkdir(parents=True, exist_ok=False)
        cmux, cortex = output / "cmux", output / "Cortex"
        cmux_sha = archive(args.cmux_base, cmux)
        cortex_sha = archive(args.cortex_base, cortex)
        make_snapshot_repository(cmux, args.cmux_base, cmux_sha)
        make_snapshot_repository(cortex, args.cortex_base, cortex_sha)
    copy_additions(args.cmux_additions, cmux, [
        "Sources/SidebarClassicMenuParity.swift", "Sources/SidebarExtensionClassicMenuCoordinator.swift",
        "Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit/Sidebar/CmuxSidebarClassicMenu.swift",
        "tests_v2/test_cortex_classic_menu_contract.py", "tests_v2/test_cortex_classic_parity.py"])
    copy_additions(args.cortex_additions, cortex, [
        "Sources/SessionsContract/SidebarNativeStatusPresentation.swift",
        "Sources/SessionsContract/SidebarCanonicalTagCatalog.swift",
        "Sources/CortexSessionsExtension/NativeWorkspaceParityMenu.swift",
        "Sources/CortexSessionsExtension/SidebarManualTagPicker.swift",
        "Sources/CortexSessionsExtension/Resources/CanonicalSessionTags.json",
        "Tests/DomainTests/SessionsFeed/SidebarNativeParityTests.swift",
        "scripts/project-sidebar-tag-catalog.py", "scripts/tests/test_sidebar_native_parity.py"])

    sdk = cmux / "Packages/macOS/CmuxExtensionKit/Sources/CmuxExtensionKit"
    # The scope presents the host menu. It does not let an extension choose
    # an item or invoke a hidden command from that menu.
    permissions = sdk / "Manifest/CMUXExtensionScope.swift"
    replace(permissions, "    case bindAgentSession\n", "    case bindAgentSession\n    /// Present the native classic sidebar menu; choices remain user gestures.\n    case presentNativeSidebarMenu\n")
    replace(permissions, "        case .analyzeWorkspaceContext:\n", "        case .presentNativeSidebarMenu:\n            return .sidebarV2_3\n        case .analyzeWorkspaceContext:\n")
    action = sdk / "Sidebar/CMUXSidebarAction.swift"
    replace(action, "    public var requiredScopes:", "    /// Presents the existing host menu; cannot choose a native command.\n    case classicMenu(CmuxSidebarClassicMenuAction)\n\n    public var requiredScopes:")
    replace(action, "        switch self {\n", "        switch self {\n        case .classicMenu:\n            return [.presentNativeSidebarMenu]\n")
    host = sdk / "Sidebar/CmuxSidebarHost.swift"
    replace(host, "    /// Requests the latest sidebar snapshot", "    /// Presents an exact native sidebar menu through the existing reply gate.\n    public func performClassicMenu(_ action: CmuxSidebarClassicMenuAction) async throws {\n        try await send(.classicMenu(action))\n    }\n\n    /// Requests the latest sidebar snapshot")
    group = cmux / "Sources/Sidebar/AppKitList/Cells/SidebarGroupHeaderRowView.swift"
    replace(group, "    private func makeHeaderMenu() -> NSMenu {", "    /// Shared by classic cells and typed extension menu presentation.\n    func makeHeaderMenu() -> NSMenu {")
    commands = cmux / "Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowCommands.swift"
    replace(commands, "    func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {", "    /// Captured at menu-open time; no live relative-index recapture.\n    func closeCapturedPlan(_ plan: SidebarClassicMenuParity.ClosePlan) {\n        guard let tabManager, tabManager.tabs.contains(where: { $0.id == plan.anchorID }) else { return }\n        let ids = plan.survivingWorkspaceIDs(in: tabManager.tabs.map(\\.id))\n        guard !ids.isEmpty else { return }\n        closeTabs(ids, allowPinned: true)\n    }\n\n    func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {")
    replace(commands, "    private func addCloseItems(to menu: NSMenu, tabManager: TabManager) {", "    private func addCloseItems(to menu: NSMenu, tabManager: TabManager) {\n        guard let captured = SidebarClassicMenuParity(nativeOrder: tabManager.tabs.map(\\.id),\n            anchorID: commands.tab.id, selectedWorkspaceIDs: commands.contextMenuWorkspaceIds) else { return }\n        let selected = captured.closePlan(.selected), others = captured.closePlan(.others)\n        let above = captured.closePlan(.above), below = captured.closePlan(.below)")
    replace(commands, "            commands.closeTabs(commands.contextMenuWorkspaceIds, allowPinned: true)", "            commands.closeCapturedPlan(selected)")
    replace(commands, "            enabled: !(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count)\n        ) { [weak tabManager, commands] in\n            guard let tabManager else { return }\n            let keepIds = Set(commands.contextMenuWorkspaceIds)\n            let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }\n            commands.closeTabs(idsToClose, allowPinned: true)", "            enabled: !others.workspaceIDs.isEmpty\n        ) { [commands] in\n            commands.closeCapturedPlan(others)")
    replace(commands, "            enabled: commands.index < tabManager.tabs.count - 1\n        ) { [weak tabManager, commands] in\n            guard let tabManager,\n                  let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == commands.tab.id }) else { return }\n            let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }\n            commands.closeTabs(idsToClose, allowPinned: true)", "            enabled: !below.workspaceIDs.isEmpty\n        ) { [commands] in\n            commands.closeCapturedPlan(below)")
    replace(commands, "            enabled: commands.index != 0\n        ) { [weak tabManager, commands] in\n            guard let tabManager,\n                  let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == commands.tab.id }) else { return }\n            let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }\n            commands.closeTabs(idsToClose, allowPinned: true)", "            enabled: !above.workspaceIDs.isEmpty\n        ) { [commands] in\n            commands.closeCapturedPlan(above)")
    view = cmux / "Sources/ContentView.swift"
    replace(view, "actionHandler: { await handleCMUXSidebarExtensionAction($0) },", "actionHandler: { await handleCMUXSidebarExtensionAction($0, renderContext: renderContext) },")
    replace(view, "        _ action: CmuxSidebarAction\n    ) async -> CmuxSidebarActionResult {", "        _ action: CmuxSidebarAction,\n        renderContext: WorkspaceListRenderContext\n    ) async -> CmuxSidebarActionResult {\n        if case .classicMenu(let request) = action {\n            return SidebarExtensionClassicMenuCoordinator(\n                tabManager: tabManager, notificationStore: notificationStore,\n                colorScheme: renderContext.environment.colorScheme,\n                readSelectedIDs: { selectedTabIds }, writeSelectedIDs: { selectedTabIds = $0 },\n                readSelectionIndex: { lastSidebarSelectionIndex }, writeSelectionIndex: { lastSidebarSelectionIndex = $0 },\n                selectTabs: { selection = .tabs }, refreshSnapshot: { refreshExtensionSidebarSnapshot() },\n                groupConfiguration: { id in appKitWorkspaceTableRows(renderContext: renderContext).first { $0.groupId == id && $0.isGroupHeader } }\n            ).perform(request)\n        }")

    project = cmux / "cmux.xcodeproj/project.pbxproj"
    project_text = project.read_text()
    for name in ["SidebarClassicMenuParity.swift", "SidebarExtensionClassicMenuCoordinator.swift"]:
        reference = hashlib.sha256(("ceo-parity-ref:" + name).encode()).hexdigest()[:24].upper()
        build = hashlib.sha256(("ceo-parity-build:" + name).encode()).hexdigest()[:24].upper()
        project_text = project_text.replace("/* End PBXBuildFile section */", f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {reference} /* {name} */; }};\n/* End PBXBuildFile section */")
        project_text = project_text.replace("/* End PBXFileReference section */", f'\t\t{reference} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
        project_text = project_text.replace("\t\t\t\t499A3CA2EB3580820BEBDCBC /* SidebarExtensionManagementCoordinator.swift */,", f"\t\t\t\t{reference} /* {name} */,\n\t\t\t\t499A3CA2EB3580820BEBDCBC /* SidebarExtensionManagementCoordinator.swift */,")
        project_text = project_text.replace("\t\t\t\tC14BB250731A62C3CC38C034 /* SidebarExtensionManagementCoordinator.swift in Sources */,", f"\t\t\t\t{build} /* {name} in Sources */,\n\t\t\t\tC14BB250731A62C3CC38C034 /* SidebarExtensionManagementCoordinator.swift in Sources */,")
        if project_text.count(reference) != 3 or project_text.count(build) != 2: raise ValueError("Native source project wiring changed")
    project.write_text(project_text)

    extension = cortex / "Sources/CortexSessionsExtension"
    manifest = extension / "CortexSessionsExtension.swift"
    replace(manifest, ".colorWorkspace, .reorderWorkspace, .editWorkspaceContext, .analyzeWorkspaceContext, .bindAgentSession],", ".colorWorkspace, .reorderWorkspace, .editWorkspaceContext, .analyzeWorkspaceContext, .bindAgentSession, .presentNativeSidebarMenu],")
    model = extension / "SessionsSidebarModel.swift"
    replace(model, "import CmuxExtensionKit\n", "import AppKit\nimport CmuxExtensionKit\n")
    replace(model, "    var editor: SidebarEditorRequest?\n", "    var editor: SidebarEditorRequest?\n    var manualTagRequest: SidebarManualTagRequest?\n    var selectedWorkspaceIDs = Set<UUID>()\n    private var selectionAnchorID: UUID?\n    @ObservationIgnored let tagCatalog: SidebarCanonicalTagCatalog? = {\n        guard let url = Bundle.main.url(forResource: \"CanonicalSessionTags\", withExtension: \"json\"),\n              let data = try? Data(contentsOf: url) else { return nil }\n        return try? SidebarCanonicalTagCatalog.decode(data)\n    }()\n")
    replace(model, "        snapshot = incoming\n", "        snapshot = incoming\n        selectedWorkspaceIDs.formIntersection(Set(incoming.workspaces.map(\\.id)))\n")
    replace(model, "        let surface = surfaceId.flatMap(UUID.init(uuidString:))\n", "        let surface = surfaceId.flatMap(UUID.init(uuidString:))\n        if surface == nil {\n            let modifiers = NSEvent.modifierFlags\n            let order = snapshot?.workspaces.map(\\.id) ?? []\n            if modifiers.contains(.shift), let anchor = selectionAnchorID,\n               let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {\n                selectedWorkspaceIDs = Set(order[min(from, to)...max(from, to)])\n            } else if modifiers.contains(.command) {\n                if selectedWorkspaceIDs.contains(id) { selectedWorkspaceIDs.remove(id) }\n                else { selectedWorkspaceIDs.insert(id) }\n                selectionAnchorID = id\n            } else { selectedWorkspaceIDs = [id]; selectionAnchorID = id }\n        }\n")
    root = extension / "SidebarRootView.swift"
    replace(root, "        .sheet(item: $model.editor)", "        .sheet(item: $model.manualTagRequest) { request in\n            if let catalog = model.tagCatalog {\n                SidebarManualTagPicker(request: request, catalog: catalog, model: model, onClose: { model.manualTagRequest = nil })\n            }\n        }\n        .sheet(item: $model.editor)")
    replace(root, "                    isOrganizing: model.isOrganizing)", "                    onManualTag: model.allows(.editWorkspaceContext) && model.tagCatalog != nil ? {\n                        guard let snapshot = model.snapshot, let windowID = snapshot.windowID,\n                              let id = snapshot.selectedWorkspaceID, let workspace = model.workspace(id.uuidString) else { return }\n                        model.manualTagRequest = .init(workspaceID: id, windowID: windowID, revision: workspace.context?.revision ?? 0)\n                    } : nil,\n                    isOrganizing: model.isOrganizing)")
    replace(root, ".contextMenu { FolderActionsMenu(groupID: section.id, model: model) }", ".contextMenu { if !model.allows(.presentNativeSidebarMenu) { FolderActionsMenu(groupID: section.id, model: model) } }\n                                .overlay {\n                                    if model.allows(.presentNativeSidebarMenu), let id = model.group(section.id)?.id {\n                                        NativeWorkspaceParityMenu { model.perform(\"Menu natif indisponible\") { try await $0.performClassicMenu(.presentGroupMenu(groupID: id)) } }\n                                    }\n                                }")
    replace(root, "workspaceMenu: AnyView(WorkspaceActionsMenu(workspaceID: row.id, model: model)),", "workspaceMenu: AnyView(Group { if !model.allows(.presentNativeSidebarMenu) { WorkspaceActionsMenu(workspaceID: row.id, model: model) } }),\n                                    onNativeContextMenu: model.allows(.presentNativeSidebarMenu) ? {\n                                        guard let id = UUID(uuidString: row.id) else { return }\n                                        model.perform(\"Menu natif indisponible\") { try await $0.performClassicMenu(.presentWorkspaceMenu(workspaceID: id, selectedWorkspaceIDs: (model.snapshot?.workspaces ?? []).compactMap { model.selectedWorkspaceIDs.contains($0.id) ? $0.id : nil })) }\n                                    } : nil,")
    replace(root, "sidebarWidth: sidebarWidth\n", "sidebarWidth: sidebarWidth,\n                                    isMultiSelected: UUID(uuidString: row.id).map(model.selectedWorkspaceIDs.contains) ?? false\n")
    chrome = extension / "SidebarChrome.swift"
    replace(chrome, "    var isOrganizing = false", "    var onManualTag: (() -> Void)? = nil\n    var isOrganizing = false")
    replace(chrome, "                    if let onOrganize {", "                    if let onManualTag {\n                        Section(\"Classification\") { Button(\"Ajouter une classification au projet sélectionné…\", action: onManualTag) }\n                    }\n                    if let onOrganize {")
    row = extension / "CompactWorkspaceRowView.swift"
    replace(row, "    var workspaceMenu: AnyView? = nil\n", "    var workspaceMenu: AnyView? = nil\n    var onNativeContextMenu: (() -> Void)? = nil\n")
    replace(row, "    var sidebarWidth: CGFloat? = nil\n", "    var sidebarWidth: CGFloat? = nil\n    var isMultiSelected = false\n")
    replace(row, '.accessibilityIdentifier("workspace:\\(row.id)")', '.overlay { if let onNativeContextMenu { NativeWorkspaceParityMenu(onPresent: onNativeContextMenu) } }\n                .accessibilityIdentifier("workspace:\\(row.id)")')
    replace(row, ".background(row.workspace.isSelected ? SidebarPalette.accent.opacity(0.10)", ".background(row.workspace.isSelected || isMultiSelected ? SidebarPalette.accent.opacity(0.10)")
    replace(row, "        Circle().fill(badge == .unknown ? Color.clear : SidebarActivityPresentation.color(badge))", "        Image(systemName: SidebarNativeStatusPresentation(badge: badge).activitySymbol)\n            .font(.system(size: 7, weight: .semibold))\n            .foregroundStyle(SidebarActivityPresentation.color(badge))")
    replace(row, "            .overlay { if badge == .unknown { Circle().stroke(SidebarPalette.secondary, lineWidth: 1) } }\n", "")
    replace(row, "            .help(badge.label).accessibilityLabel(badge.label)", "            .help(SidebarNativeStatusPresentation(badge: badge).activityLabel)\n            .accessibilityLabel(SidebarNativeStatusPresentation(badge: badge).activityLabel)")
    replace(row, "SidebarActivityDot(badge: group.sessions.contains(where: \\.hasPendingUserAction) ? .needsInput : groupBadge)", "SidebarActivityDot(badge: groupBadge, pendingUserActionCount: group.sessions.filter(\\.hasPendingUserAction).count)")
    replace(row, "SidebarActivityDot(badge: session.hasPendingUserAction ? .needsInput : session.badge)", "SidebarActivityDot(badge: session.badge, pendingUserActionCount: session.pendingUserActionCount)")
    replace(row, "private struct SidebarActivityDot: View {\n    let badge: SidebarBadge", "private struct SidebarActivityDot: View {\n    let badge: SidebarBadge\n    var pendingUserActionCount: Int = 0")
    replace(row, "            .background(SidebarPalette.background, in: Circle())", "            .background(SidebarPalette.background, in: Circle())\n            .overlay(alignment: .bottomTrailing) {\n                if pendingUserActionCount > 0 && badge != .needsInput && badge != .planAwaitingValidation {\n                    Image(systemName: \"bell.fill\").font(.system(size: 5, weight: .semibold))\n                        .foregroundStyle(CortexVisualTokens.warning).offset(x: 2, y: 4)\n                        .accessibilityLabel(\"Needs input\")\n                }\n            }")
    row.write_text(row.read_text().replace("session.badge.label", "SidebarNativeStatusPresentation(badge: session.badge).activityLabel"))
    layout = cortex / "scripts/verify-sidebar-layout.sh"
    replace(layout, "    cat Sources/SessionsContract/SidebarAgentObservation.swift", "    cat Sources/SessionsContract/SidebarNativeStatusPresentation.swift\n    cat Sources/SessionsContract/SidebarAgentObservation.swift")
    replace(layout, "    sed '/^import SessionsContract$/d' Sources/CortexSessionsExtension/CompactWorkspaceRowView.swift", "    cat Sources/CortexSessionsExtension/NativeWorkspaceParityMenu.swift\n    sed '/^import SessionsContract$/d' Sources/CortexSessionsExtension/CompactWorkspaceRowView.swift")
    project = cortex / "Project.swift"
    replace(project, 'resources: ["Sources/App/Resources/Assets.xcassets"],', 'resources: ["Sources/App/Resources/Assets.xcassets", "Sources/CortexSessionsExtension/Resources/**"],')

    # The immutable recovery baseline exposes these diagnostics under the host
    # transport SPI; its TerminalController caller must import that same SPI.
    replace(cmux / "Sources/TerminalController.swift", "import CmuxSidebar\n",
            "@_spi(CmuxHostTransport) import CmuxSidebar\n")

    receipt = {"schemaVersion": 1, "cmuxBaseSHA": cmux_sha, "cortexBaseSHA": cortex_sha,
               "productionActivationAllowed": False, "sourceArchivesIncludeForeignWIP": False, "patches": {}}
    for name, stage in [("cmux", cmux), ("Cortex", cortex)]:
        git(stage, "add", "--all")
        patch = git(stage, "diff", "--cached", "--binary", "--full-index", cmux_sha if stage == cmux else cortex_sha)
        path = output / (name + "-integration.patch")
        path.write_bytes(patch)
        receipt["patches"][name] = {"sha256": hashlib.sha256(patch).hexdigest(), "path": str(path)}
        git(stage, "-c", "user.name=CEO parity build artifact", "-c", "user.email=artifact@localhost", "commit", "-m", "Private dogfood integration snapshot; not a delivery commit")
        receipt[name + "ArtifactSHA"] = git(stage, "rev-parse", "HEAD").decode().strip()
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
