//! Issue #2440: "When terminals are reorganized, terminal content disappears"
//! (two panes left and right, one moved so they are top and bottom). In
//! cmux NEXT the daemon owns every terminal; a reorganize is a layout commit
//! (the tab drag's `move_tab_to_split_as`, what a drop on a pane's edge
//! sends) and the app's views then resize to the new grid. Both panes keep
//! what they showed and their scrollback through the move and the resize,
//! repeated in both directions.

use cmux_tui_core::{Actor, Mux, SplitDir, Surface, SurfaceOptions, TabDropEdge};
use std::sync::Arc;
use std::time::Duration;
mod support;
use support::wait_for;

const ROUNDS: usize = 12;
/// 200 numbered history lines, then a marker that stays in the viewport; the shell never redraws.
/// `PANE` names the pane (the first pane leaves it unset: `left`).
const SHELL: &str = r#"n=${PANE:-left}; i=1; while [ $i -le 200 ]; do echo $n-history-$i; i=$((i+1)); done; printf "$n-on-screen\$ "; while :; do sleep 0.05; done"#;

struct Shutdown(Arc<Mux>);
impl Drop for Shutdown {
    fn drop(&mut self) {
        self.0.shutdown();
    }
}

/// Whether `surface` shows `name`'s marker on screen and still holds its first history line, within 5 s.
fn keeps_content(surface: &Arc<Surface>, name: &str) -> bool {
    let marker = format!("{name}-on-screen$");
    let first = format!("{name}-history-1\n");
    wait_for(
        || {
            let screen = surface.with_terminal(|t| t.viewport_text())?.ok()?;
            let all = surface.with_terminal(|t| t.plain_text())?.ok()?;
            (screen.contains(&marker) && all.contains(&first)).then_some(())
        },
        Duration::from_secs(5),
    )
    .is_some()
}

#[test]
fn moving_a_pane_between_side_by_side_and_stacked_keeps_both_terminals_content() {
    let mux = Mux::new(
        format!("test-reorganize-keeps-content-{}", std::process::id()),
        SurfaceOptions {
            command: Some(vec!["/bin/sh".into(), "-c".into(), SHELL.into()]),
            ..Default::default()
        },
    );
    let _shutdown = Shutdown(mux.clone());
    let left = mux.new_workspace(None, Some((160, 48))).unwrap();
    assert!(keeps_content(&left, "left"), "SETUP: the first pane never drew its output");
    let pane = mux.with_state(|state| state.pane_of(left.id)).unwrap();
    let env = vec![("PANE".to_string(), "right".to_string())];
    let right = mux
        .split_with_as(&Actor::Daemon, pane, SplitDir::Right, None, env, Some((80, 48)))
        .unwrap();
    let _ = left.resize(80, 48);
    let _ = right.resize(80, 48);
    assert!(keeps_content(&right, "right"), "SETUP: the split never drew its output");

    for round in 0..ROUNDS {
        // Even rounds: the right pane goes under the left one (stacked); odd: back beside it.
        let stacked = round % 2 == 0;
        let anchor =
            mux.with_state(|state| state.pane_of(left.id)).expect("the left pane left the layout");
        let edge = if stacked { TabDropEdge::Bottom } else { TabDropEdge::Right };
        mux.move_tab_to_split_as(&Actor::Daemon, right.id, anchor, edge, None, false, None)
            .unwrap_or_else(|error| panic!("round {round}: the move failed: {error:?}"));
        let (cols, rows) = if stacked { (160, 24) } else { (80, 48) };
        let _ = left.resize(cols, rows);
        let _ = right.resize(cols, rows);
        let how = if stacked { "stacked" } else { "side by side" };
        assert!(
            keeps_content(&right, "right"),
            "round {round}: the moved pane lost its content ({how})"
        );
        assert!(
            keeps_content(&left, "left"),
            "round {round}: the pane it moved beside lost its content ({how})"
        );
    }
}
