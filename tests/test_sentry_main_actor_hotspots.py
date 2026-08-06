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
