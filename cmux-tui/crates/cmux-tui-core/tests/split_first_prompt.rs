//! Issue #16184 (cx-6so.56): about one new split in eight showed no first
//! prompt. A split here runs a shell that draws one OSC 133 prompt and never
//! redraws it, so a prompt lost at spawn or on a resize stays lost; a client
//! pins its own grid right after the split (the app's first resize). Every
//! new pane, and the pane it split from, keeps its prompt on screen.

use cmux_tui_core::{Actor, Mux, SplitDir, Surface, SurfaceOptions};
use std::sync::Arc;
use std::time::Duration;
mod support;
use support::{DaemonMuxOps, wait_for};

const SPLITS: u16 = 60;
const SHELL: &str =
    r#"printf '\033]133;A\007prompt$ \033]133;B\007'; while :; do sleep 0.05; done"#;

/// Shuts the mux, and its shells, down on a failed assert too.
struct Shutdown(Arc<Mux>);
impl Drop for Shutdown {
    fn drop(&mut self) {
        self.0.shutdown();
    }
}

/// Whether the viewport, not the scrollback, shows the prompt within 5 s.
fn shows_prompt(surface: &Arc<Surface>) -> bool {
    wait_for(
        || {
            let text = surface.with_terminal(|t| t.viewport_text())?.ok()?;
            text.contains("prompt$").then_some(())
        },
        Duration::from_secs(5),
    )
    .is_some()
}

#[test]
fn every_new_split_shows_its_first_prompt() {
    let opts = SurfaceOptions {
        command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), SHELL.to_string()]),
        ..Default::default()
    };
    let mux = Mux::new(format!("test-split-first-prompt-{}", std::process::id()), opts);
    let _shutdown = Shutdown(mux.clone());
    let first = mux.new_workspace(None, Some((160, 48))).unwrap();
    assert!(shows_prompt(&first), "the first pane never showed its prompt");
    for i in 0..SPLITS {
        let pane = mux
            .with_state(|state| state.pane_of(first.id))
            .expect("the first pane left the layout");
        let dir = if i % 2 == 0 { SplitDir::Right } else { SplitDir::Down };
        let split = mux.split_as(&Actor::Daemon, pane, dir, None).unwrap();
        assert!(shows_prompt(&split), "split {i} never showed its first prompt");
        // The view's grid differs from the split's own, and arrives at once.
        let _ = split.resize(60 + i % 9, 16 + i % 7);
        assert!(shows_prompt(&split), "split {i} lost its prompt on the view's resize");
        assert!(shows_prompt(&first), "the first pane lost its prompt after split {i}");
        mux.close_surface(split.id).unwrap();
    }
}
