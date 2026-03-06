#!/usr/bin/env python3
"""Regression guards for browser Cmd+F overlay layering in portal mode."""

from __future__ import annotations

from regression_helpers import extract_block, repo_root


def main() -> int:
    root = repo_root()
    view_path = root / "Sources" / "Panels" / "BrowserPanelView.swift"
    panel_path = root / "Sources" / "Panels" / "BrowserPanel.swift"
    overlay_path = root / "Sources" / "Find" / "BrowserSearchOverlay.swift"
    source = view_path.read_text(encoding="utf-8")
    panel_source = panel_path.read_text(encoding="utf-8")
    overlay_source = overlay_path.read_text(encoding="utf-8")
    failures: list[str] = []

    try:
        browser_panel_view_block = extract_block(
            source, "struct BrowserPanelView: View"
        )
    except ValueError as error:
        failures.append(str(error))
        browser_panel_view_block = ""

    try:
        body_block = extract_block(browser_panel_view_block, "var body: some View")
    except ValueError as error:
        failures.append(str(error))
        body_block = ""

    fallback_signature = (
        "if !panel.shouldRenderWebView, let searchState = panel.searchState {"
    )
    fallback_block = ""
    if body_block:
        try:
            fallback_block = extract_block(body_block, fallback_signature)
        except ValueError:
            failures.append(
                "BrowserPanelView must provide BrowserSearchOverlay fallback for new-tab state "
                "(when WKWebView is not mounted)"
            )
        if fallback_block and "BrowserSearchOverlay(" not in fallback_block:
            failures.append(
                "BrowserPanelView fallback branch must mount BrowserSearchOverlay for new-tab state"
            )

    try:
        webview_repr_block = extract_block(
            source, "struct WebViewRepresentable: NSViewRepresentable"
        )
    except ValueError as error:
        failures.append(str(error))
        webview_repr_block = ""

    if webview_repr_block:
        if "let browserSearchState: BrowserSearchState?" not in webview_repr_block:
            failures.append(
                "WebViewRepresentable must include browserSearchState so Cmd+F state changes trigger updates"
            )
        if (
            "var searchOverlayHostingView: NSHostingView<BrowserSearchOverlay>?"
            not in webview_repr_block
        ):
            failures.append(
                "WebViewRepresentable.Coordinator must own a BrowserSearchOverlay hosting view"
            )
        if "private static func updateSearchOverlay(" not in webview_repr_block:
            failures.append(
                "WebViewRepresentable must define updateSearchOverlay helper"
            )
        if "containerView: webView.superview" not in webview_repr_block:
            failures.append(
                "Portal updates must sync BrowserSearchOverlay against the web view container"
            )
        if "removeSearchOverlay(from: coordinator)" not in webview_repr_block:
            failures.append(
                "WebViewRepresentable must remove browser search overlays during teardown/rebind"
            )

    if "browserSearchState: panel.searchState" not in source:
        failures.append(
            "BrowserPanelView must pass panel.searchState into WebViewRepresentable"
        )

    try:
        update_ns_view_block = extract_block(
            webview_repr_block, "func updateNSView(_ nsView: NSView, context: Context)"
        )
    except ValueError as error:
        failures.append(str(error))
        update_ns_view_block = ""

    if "updateSearchOverlay(" in update_ns_view_block:
        failures.append(
            "updateNSView must not re-run updateSearchOverlay outside portal lifecycle paths"
        )

    try:
        suppress_focus_block = extract_block(
            panel_source, "func shouldSuppressWebViewFocus() -> Bool"
        )
    except ValueError as error:
        failures.append(str(error))
        suppress_focus_block = ""

    if "if searchState != nil {" not in suppress_focus_block:
        failures.append(
            "BrowserPanel.shouldSuppressWebViewFocus must suppress focus while find-in-page is active"
        )

    try:
        start_find_block = extract_block(panel_source, "func startFind()")
    except ValueError as error:
        failures.append(str(error))
        start_find_block = ""

    if start_find_block:
        if "postBrowserSearchFocusNotification()" not in start_find_block:
            failures.append(
                "BrowserPanel.startFind must publish browserSearchFocus notifications"
            )
        if "DispatchQueue.main.async {" not in start_find_block:
            failures.append(
                "BrowserPanel.startFind must re-post focus on next runloop to avoid mount races"
            )
        if "DispatchQueue.main.asyncAfter" not in start_find_block:
            failures.append(
                "BrowserPanel.startFind must re-post focus shortly after to avoid portal mount races"
            )

    try:
        init_block = extract_block(panel_source, "init(workspaceId: UUID")
    except ValueError as error:
        failures.append(str(error))
        init_block = ""

    if init_block:
        if (
            "self?.searchState = nil" in init_block
            or "self.searchState = nil" in init_block
        ):
            failures.append(
                "BrowserPanel navigation callbacks must not clear searchState entirely to avoid losing find bar focus"
            )
        if "restoreFindStateAfterNavigation(replaySearch: true)" not in init_block:
            failures.append(
                "BrowserPanel.didFinish must preserve find state and replay search on the new page"
            )
        if "restoreFindStateAfterNavigation(replaySearch: false)" not in init_block:
            failures.append(
                "BrowserPanel.didFailNavigation must preserve find state without replaying search"
            )

    try:
        restore_find_state_block = extract_block(
            panel_source, "private func restoreFindStateAfterNavigation(replaySearch: Bool)"
        )
    except ValueError as error:
        failures.append(str(error))
        restore_find_state_block = ""

    if restore_find_state_block:
        if "state.total = nil" not in restore_find_state_block:
            failures.append(
                "BrowserPanel restoreFindStateAfterNavigation must clear stale find total count"
            )
        if "state.selected = nil" not in restore_find_state_block:
            failures.append(
                "BrowserPanel restoreFindStateAfterNavigation must clear stale selected match"
            )
        if "if replaySearch, !state.needle.isEmpty {" not in restore_find_state_block:
            failures.append(
                "BrowserPanel restoreFindStateAfterNavigation must only replay search for successful navigations"
            )
        if "postBrowserSearchFocusNotification()" not in restore_find_state_block:
            failures.append(
                "BrowserPanel restoreFindStateAfterNavigation must reassert find field focus"
            )

    if "private func requestSearchFieldFocus(" not in overlay_source:
        failures.append(
            "BrowserSearchOverlay must define requestSearchFieldFocus retry helper"
        )
    if "requestSearchFieldFocus()" not in overlay_source:
        failures.append(
            "BrowserSearchOverlay must request text focus from appear/notification paths"
        )

    if failures:
        print("FAIL: browser find overlay portal regression guards failed")
        for failure in failures:
            print(f" - {failure}")
        return 1

    print("PASS: browser find overlay remains mounted in portal-hosted AppKit layer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
