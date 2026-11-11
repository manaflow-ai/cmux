//! What the App Store lists (plans/cmux-next/extensibility-DESIGN.md
//! section 7, "Trim"): apps, never the parts of cmux itself. Home and the
//! App Store are places in cmux that ship as first-party packages; they are
//! not removable and not apps, so `catalog.list` and `catalog.get` leave them
//! out and every `installed.list` row says `listed: false` for them. The
//! store page, the CLI and MCP read this one rule; no client keeps its own
//! list.

/// The packages that are cmux itself.
const UNLISTED: [&str; 2] = ["cmux/app-store", "cmux/home"];

/// Whether the App Store shows `app`.
pub(super) fn listed(app: &str) -> bool {
    !UNLISTED.contains(&app)
}

#[cfg(test)]
mod tests {
    use super::listed;

    #[test]
    fn cmux_itself_is_not_listed() {
        assert!(!listed("cmux/home"));
        assert!(!listed("cmux/app-store"));
    }

    #[test]
    fn apps_are_listed() {
        for app in ["cmux/cloud", "cmux/coderouter", "cmux/demo", "acme/tool", "local/spy"] {
            assert!(listed(app), "{app}");
        }
    }
}
