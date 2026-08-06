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
