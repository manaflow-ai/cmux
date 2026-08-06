from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def source_slice(path: str, start: str, end: str) -> str:
    source = (ROOT / path).read_text()
    return source[source.index(start) : source.index(end, source.index(start))]


def test_sidebar_cursor_release_uses_event_state_instead_of_core_graphics_polling():
    release = source_slice(
        "Sources/ContentView.swift",
        "private func releaseSidebarResizerCursorIfNeeded",
        "private func scheduleSidebarResizerCursorRelease",
    )

    assert "CGEventSource.buttonState" not in release
    assert "sidebarResizerPointerButtonState.isLeftButtonDown" in release


def test_port_publication_delivery_is_materialized_before_the_main_actor_drain():
    drain = source_slice(
        "Sources/PortScanner+Publication.swift",
        "private func drainPortPublications",
        "private func nextPublicationBatch",
    )
    buffer = (ROOT / "Sources/PortScanPublicationBuffer.swift").read_text()

    assert "Array(batch.agentPublicationsByWorkspace.values)" not in drain
    assert "PortScanPublicationDeliveryBatch" in buffer


def test_omnibar_update_skips_redundant_placeholder_field_editor_work():
    update = source_slice(
        "Sources/Panels/BrowserPanelView.swift",
        "func updateNSView(_ nsView: OmnibarNativeTextField",
        "if nsView.font?.pointSize != fontSize",
    )

    assert "if nsView.placeholderString != placeholder" in update
    assert "nsView.placeholderString = placeholder" in update


def test_right_sidebar_chrome_reads_cached_shortcut_snapshot():
    sidebar = source_slice(
        "Sources/RightSidebarPanelView.swift",
        "struct RightSidebarPanelView: View",
        "private struct RightSidebarKeyboardFocusBridge",
    )

    assert "KeyboardShortcutSettings.shortcut(for:" not in sidebar
    assert "shortcut: shortcut" in sidebar


def test_sidebar_mutation_scheduler_uses_native_main_actor_task():
    scheduler = (ROOT / "Sources/Sidebar/AppKitList/SidebarWorkspaceTableMutationScheduler.swift").read_text()

    assert "RunLoop.main.perform" not in scheduler
    assert "MainActor.assumeIsolated" not in scheduler
    assert "Task { @MainActor [self] in" in scheduler
    assert "await Task.yield()" in scheduler


def test_sidebar_row_actions_have_reference_identity():
    model = (ROOT / "Sources/Sidebar/AppKitList/Cells/SidebarWorkspaceRowModel.swift").read_text()

    assert "final class SidebarAppKitRowActions" in model
    assert "struct SidebarAppKitRowActions" not in model


def test_browser_background_preload_uses_os_safe_window_ordering():
    panel = source_slice(
        "Sources/Panels/BrowserPanel.swift",
        "private func ensureBackgroundPreloadHostIfNeeded",
        "private func shouldDeferPromptUntilInteractiveHost",
    )

    assert "window.orderFrontRegardless()" not in panel
    assert "BrowserBackgroundPreloadHost.orderOnScreenIfSafe(window)" in panel


def test_split_divider_cursor_refresh_does_not_destroy_kvo_observers():
    invalidator = (ROOT / "Sources/PortalSplitDividerCacheInvalidator.swift").read_text()
    teardown = source_slice(
        "Sources/PortalSplitDividerCacheInvalidator.swift",
        "private nonisolated func invalidateObservations()",
        "\n    }\n}",
    )
    terminal_cursor_refresh = source_slice(
        "Sources/TerminalWindowPortal.swift",
        "override func resetCursorRects()",
        "override func updateTrackingAreas()",
    )
    browser_cursor_refresh = source_slice(
        "Sources/BrowserWindowPortal.swift",
        "override func resetCursorRects()",
        "override func updateTrackingAreas()",
    )

    assert "observations.forEach { $0.invalidate() }" in teardown
    assert teardown.index("observations.forEach { $0.invalidate() }") < teardown.index("observations.removeAll()")
    assert "invalidateSplitDividerRegionCache()" not in terminal_cursor_refresh
    assert "invalidateSplitDividerRegionCache()" not in browser_cursor_refresh
    assert "private nonisolated func invalidateObservations()" in invalidator


def test_terminal_key_state_indicator_reuses_localized_accessibility_label():
    terminal = (ROOT / "Sources/GhosttyTerminalView.swift").read_text()
    synchronization = source_slice(
        "Sources/GhosttyTerminalView.swift",
        "func syncKeyStateIndicator(text: String?)",
        "func refreshHostBackgroundAfterGhosttyConfigReload()",
    )

    assert "private var terminalKeyTableIndicatorAccessibilityLabel" not in terminal
    assert "private let keyTableIndicatorAccessibilityLabel = String(" in terminal
    assert "setAccessibilityLabel(keyTableIndicatorAccessibilityLabel)" in synchronization


def test_sidebar_drag_end_does_not_forward_optional_appkit_selector():
    drag_end = source_slice(
        "Sources/Sidebar/AppKitList/SidebarWorkspaceTableViewImpl.swift",
        "override func draggingEnded",
        "private func updatePointer",
    )

    assert "super.draggingEnded" not in drag_end
    assert "workspaceController?.reorderDropSessionEnded()" in drag_end


def test_quicklook_retirement_does_not_close_inactive_preview():
    retirement = source_slice(
        "Sources/Panels/FilePreviewQuickLookContainerView.swift",
        "private func retireLivePreview",
        "\n    }\n}",
    )

    assert "previewView.previewItem = nil" in retirement
    assert "previewView.removeFromSuperview()" in retirement
    assert "previewView.close()" not in retirement


def test_portal_geometry_sync_defers_layout_to_appkit():
    synchronization = source_slice(
        "Sources/TerminalWindowPortal.swift",
        "private func synchronizeLayoutHierarchy()",
        "@discardableResult\n    private func synchronizeHostFrameToReference()",
    )

    assert ".layoutSubtreeIfNeeded()" not in synchronization
    assert "installedContainerView?.needsLayout = true" in synchronization
    assert "installedReferenceView?.needsLayout = true" in synchronization


def test_closed_panel_history_uses_read_only_terminal_capture():
    close_history = source_slice(
        "Sources/Workspace.swift",
        "private func closedPanelHistoryEntry(",
        "private func consumeCloseHistoryEligibility",
    )
    session_snapshot = source_slice(
        "Sources/Workspace.swift",
        "private func sessionPanelSnapshot(",
        "private func terminalSnapshotScrollback(",
    )

    assert "allowVTExport: false" in close_history
    assert "allowTerminalVTExport: Bool = true" in session_snapshot
    assert "allowVTExport: allowTerminalVTExport" in session_snapshot
