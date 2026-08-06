from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_menu_notification_time_style_is_not_rebuilt_per_row():
    source = (ROOT / "Sources/App/MenuBarExtraController.swift").read_text()
    start = source.index("enum MenuBarNotificationLineFormatter")
    end = source.index("static func menuTitle", start)
    formatter = source[start:end]

    assert "static let menuTimeFormatStyle" in formatter
    assert ".formatted(menuTimeFormatStyle)" in formatter
    assert ".formatted(date: .omitted, time: .shortened)" not in formatter
