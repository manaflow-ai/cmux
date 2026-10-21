//! Terminal titles end to end (plans/cmux-next/osc-titles.md).
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
mod support;
use cmux_tui_core::{Mux, MuxEvent, SurfaceOptions};
use support::{DaemonMuxOps, wait_for};

fn shell_opts(script: &str) -> SurfaceOptions {
    SurfaceOptions {
        command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), script.to_string()]),
        ..Default::default()
    }
}

fn unique_session(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

/// A fake Claude Code (plans/cmux-next/osc-titles.md): spinner titles, one
/// frame printed twice, a title with a bidi override, and an xterm
/// title push/pop around a nested program. The daemon stores the sanitized
/// title, restores the pushed one, and never announces the same title twice
/// in a row.
#[test]
fn a_spinner_titled_agent_retitles_the_terminal_once_per_change() {
    let script = r#"
printf '\033]0;✳ Claude Code\007'; sleep 0.3
for f in ⠂ ⠐; do
  printf '\033]0;%s Fix the login bug\007' "$f"; sleep 0.1
  printf '\033]0;%s Fix the login bug\007' "$f"; sleep 0.3
done
printf '\033[22;0t'; printf '\033]2;vim\342\200\256 notes\007'; sleep 0.4
printf '\033[23;0t'; sleep 0.4
printf '\033]2;done\007'; sleep 30
"#;
    let mux = Mux::new(unique_session("test-agent-titles"), shell_opts(script));
    let events = mux.subscribe();
    let surface = mux.new_workspace(None, Some((40, 6))).unwrap();
    let mut seen: Vec<String> = Vec::new();
    let drain = |seen: &mut Vec<String>| {
        for event in events.try_iter() {
            if let MuxEvent::TitleChanged { surface: id, title } = event
                && id == surface.id
            {
                seen.push(title.to_string());
            }
        }
    };
    for expected in
        ["✳ Claude Code", "⠐ Fix the login bug", "vim notes", "⠐ Fix the login bug", "done"]
    {
        let reached = wait_for(
            || {
                drain(&mut seen);
                (surface.title() == expected).then_some(())
            },
            Duration::from_secs(10),
        );
        assert!(reached.is_some(), "title never became {expected:?}; events {seen:?}");
    }
    drain(&mut seen);
    assert!(
        seen.windows(2).all(|pair| pair[0] != pair[1]),
        "the same title was announced twice in a row: {seen:?}"
    );
    assert_eq!(seen.last().map(String::as_str), Some("done"));
    let _ = mux.close_surface(surface.id);
}
