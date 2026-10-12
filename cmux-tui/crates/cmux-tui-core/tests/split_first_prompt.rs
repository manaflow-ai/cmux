//! Issue #16184 (cx-6so.56): about one new split in eight showed no first
//! prompt. A split here runs a shell that draws an OSC 133 prompt and redraws
//! it on SIGWINCH, as zsh with shell integration does; a client pins its own
//! grid right after the split (the app's first resize). Every new pane, and
//! the pane it split from, must show its prompt.

use cmux_tui_core::{Actor, Mux, SplitDir, SurfaceOptions};
use std::sync::Arc;
use std::time::Duration;
mod support;
use support::{DaemonMuxOps, wait_for};

const SPLITS: u16 = 60;
const SHELL: &str = r#"p() { printf '\r\033[K\033]133;A\007prompt$ \033]133;B\007'; }; trap p WINCH; p; while :; do sleep 0.05; done"#;

fn shows_prompt(surface: &Arc<cmux_tui_core::Surface>) -> bool {
    wait_for(
        || {
            let text = surface.with_terminal(|t| t.plain_text())?.ok()?;
            text.contains("prompt$").then_some(())
        },
        Duration::from_secs(10),
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
    let first = mux.new_workspace(None, Some((160, 48))).unwrap();
    assert!(shows_prompt(&first), "the first pane never showed its prompt");
    let mut lost = Vec::new();
    for i in 0..SPLITS {
        let pane = mux
            .with_state(|state| state.pane_of(first.id))
            .expect("the first pane left the layout");
        let dir = if i % 2 == 0 { SplitDir::Right } else { SplitDir::Down };
        let split = mux.split_as(&Actor::Daemon, pane, dir, None).unwrap();
        // The view's grid differs from the split's own, and arrives at once.
        let _ = split.resize(60 + i % 9, 16 + i % 7);
        if !shows_prompt(&split) {
            lost.push(format!("split {i}"));
        }
        if !shows_prompt(&first) {
            lost.push(format!("first pane after split {i}"));
        }
        mux.close_surface(split.id).unwrap();
    }
    mux.close_surface(first.id).unwrap();
    assert!(lost.is_empty(), "{} of {SPLITS} splits lost a prompt: {lost:?}", lost.len());
}
