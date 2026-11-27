//! Opening a Cloud machine's desktop is a view change the person asked for, from any origin.
//!
//! A CLI or agent run has no `focus` argument, so without `focuses` the app filed the new
//! desktop workspace quietly in the background: no pane showed the tab, the remote view page
//! was never built, and `remote_view.state` listed no desktop (cloud-desktop-agent probe,
//! 2026-11-26 15:07Z, `workspace_seen`).
use cmux_action_catalog::find;

#[test]
fn opening_a_desktop_shows_its_workspace() {
    for id in ["cloudOpenDesktop", "cloudSetupDesktop"] {
        let action = find(id).unwrap_or_else(|| panic!("{id} is in the catalog"));
        assert!(action.focuses, "{id} shows the desktop workspace it opens");
    }
}
