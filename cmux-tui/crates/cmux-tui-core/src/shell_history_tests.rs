use super::{CommandScreen, CommandTracker, ShellMark, clean_command};

/// A screen whose submitted input is `input`.
struct Typed(&'static str);

impl CommandScreen for Typed {
    fn input_text(&mut self) -> Option<String> {
        Some(self.0.to_owned())
    }

    fn cwd(&mut self) -> Option<String> {
        None
    }
}

#[test]
fn the_tracker_keeps_the_last_command_with_a_line_until_reset() {
    let mut tracker = CommandTracker::default();
    tracker.apply(ShellMark::CommandStart, 1_000, &mut Typed("npm test"));
    tracker.apply(ShellMark::CommandEnd { exit_code: Some(1) }, 4_000, &mut Typed(""));
    let last = tracker.last().expect("a finished command is kept");
    assert_eq!(last.command.as_deref(), Some("npm test"));
    assert_eq!((last.exit_code, last.started_at_ms, last.duration_ms), (Some(1), 1_000, 3_000));
    // A command with no line (a leading space hides it) keeps the older one.
    tracker.apply(ShellMark::CommandStart, 5_000, &mut Typed(" secret"));
    tracker.apply(ShellMark::CommandEnd { exit_code: Some(0) }, 6_000, &mut Typed(""));
    assert_eq!(tracker.last().and_then(|last| last.command.as_deref()), Some("npm test"));
    tracker.reset();
    assert!(tracker.last().is_none(), "turning recording off forgets the last command");
}

#[test]
fn leading_space_commands_are_not_recorded() {
    assert_eq!(clean_command(" pnpm test"), None);
    assert_eq!(clean_command("\tpnpm test"), None);
    assert_eq!(clean_command("pnpm test"), Some("pnpm test".to_owned()));
}
