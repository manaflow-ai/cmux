//! Remote-terminal tabs (`remote-terminal-tabs-v1`) in the tree view: a
//! reference to a terminal on another session that only the cmux app
//! renders. Its `kind` is `Browser`, so nothing attaches it as a PTY, and the
//! pane shows a labeled placeholder.

use std::sync::Arc;

use serde_json::Value;

/// Whether an in-process surface is a remote-terminal placeholder.
pub(super) fn is_placeholder(surface: Option<&Arc<cmux_tui_core::Surface>>) -> bool {
    surface.is_some_and(|surface| {
        surface
            .browser_url()
            .is_some_and(|url| url.starts_with(cmux_tui_core::REMOTE_TERMINAL_URL_PREFIX))
    })
}

/// Whether a wire tab is a remote-terminal tab.
pub(super) fn is_remote_kind(tab: &Value) -> bool {
    tab.get("kind").and_then(Value::as_str) == Some("remote-terminal")
}

#[cfg(test)]
mod tests {
    use super::super::*;
    use serde_json::json;

    #[test]
    fn tree_parser_defaults_clear_fallback_support_to_false() {
        let pane = parse_pane(&json!({
            "id": 3,
            "tabs": [
                {"surface": 4},
                {"surface": 5, "supports_clear_history_key_fallback": true}
            ]
        }))
        .unwrap();

        assert!(!pane.tabs[0].supports_clear_history_key_fallback);
        assert!(pane.tabs[1].supports_clear_history_key_fallback);
    }

    #[test]
    fn cmux_next_remote_terminal_tab_parses_as_a_placeholder_never_a_pty() {
        let pane = parse_pane(&json!({
            "id": 3,
            "tabs": [
                {"surface": 4, "kind": "pty", "title": "zsh"},
                {
                    "surface": 5,
                    "kind": "remote-terminal",
                    "title": "Terminal on build-box",
                    "remote": {
                        "session_id": "0b7f2c1e-4d3a-4f6b-9c8d-1a2b3c4d5e6f",
                        "terminal_id": "5f0c3a9e2b7d4c1a8e6f0b3d2c1a9e8f",
                        "session_name": "build-box"
                    }
                }
            ]
        }))
        .unwrap();

        assert_eq!(pane.tabs[0].kind, SurfaceKind::Pty);
        assert!(!pane.tabs[0].remote_terminal);
        // Never attached as a PTY; the pane shows a labeled placeholder.
        assert_eq!(pane.tabs[1].kind, SurfaceKind::Browser);
        assert!(pane.tabs[1].remote_terminal);
        assert_eq!(pane.tabs[1].title, "Terminal on build-box");
    }

    #[test]
    fn tree_parser_preserves_browser_source_and_rejects_unknown_values() {
        let pane = parse_pane(&json!({
            "id": 3,
            "tabs": [
                {"surface": 4, "kind": "browser", "browser_source": "external"},
                {"surface": 5, "kind": "browser", "browser_source": "launched"},
                {"surface": 6, "kind": "browser", "browser_source": "remote"}
            ]
        }))
        .unwrap();

        assert_eq!(pane.tabs[0].browser_source, Some(BrowserSource::External));
        assert_eq!(pane.tabs[1].browser_source, Some(BrowserSource::Launched));
        assert_eq!(pane.tabs[2].browser_source, None);
    }
}
