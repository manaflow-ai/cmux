//! What cut a turn off, for the continuation that goes on with it (`restart_resume.rs`): the
//! `reason` its records carry and how its text opens.

const STAYED: &str = "This chat did not move: a move to another machine stopped your previous \
                      turn and then did not happen. You are still on this machine, with the same \
                      files; processes you started may have ended with the turn.";

/// What cut the turn off.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::hub) enum Cut {
    /// The daemon restarted (an update or a crash).
    Restart,
    /// The chat moved to another machine (`transfer_out.rs`).
    Move,
    /// It moved at a tool boundary, with nothing of the turn left running: a [`Cut::Move`] whose
    /// continuation says so (`"silent": true` in its provenance), so a harness that can go on
    /// from its own transcript does, and the text is never written
    /// (`claude_stdio/resume_cut.rs`). Any other harness gets the text as after `Cut::Move`.
    MoveAtBoundary,
    /// Auto mode: the machine the turn ran on went away, and this one took the chat over from
    /// its Cloud copy (`auto_import.rs`).
    Takeover,
}

impl Cut {
    /// The `reason` of its records and provenance.
    pub(in crate::hub) fn reason(self) -> &'static str {
        match self {
            Cut::Restart => "daemon_restart",
            Cut::Move | Cut::MoveAtBoundary => "moved",
            Cut::Takeover => "machine_takeover",
        }
    }

    /// Whether `reason` is a queued continuation's, which goes ahead of what waited behind the
    /// cut turn and is no waiting retry (`queue.rs`, `auto_resume/restore.rs`).
    pub(in crate::hub) fn queued(reason: Option<&str>) -> bool {
        matches!(reason, Some("daemon_restart" | "moved" | "machine_takeover"))
    }

    /// A [`Cut::Move`] continuation's text for a move that did not happen (`transfer_out.rs`
    /// `queue_carried`): the same turn, told it is still on this machine. `None` for any other
    /// text.
    pub(in crate::hub) fn unmoved(text: &str) -> Option<String> {
        text.strip_prefix(Cut::Move.opening()).map(|rest| format!("{STAYED}{rest}"))
    }

    pub(super) fn opening(self) -> &'static str {
        match self {
            Cut::Restart => {
                "acpmux restarted (an update or a crash) while your previous turn was running, \
                 and the turn was cut off."
            }
            Cut::Move | Cut::MoveAtBoundary => {
                "This chat moved to another machine while your previous turn was running, and the \
                 turn was cut off. The files and git state came with it, but processes you \
                 started (dev servers, watchers, background shells) did not: start again any \
                 that you still need."
            }
            Cut::Takeover => {
                "The machine this chat ran on went away while your previous turn was running, \
                 and the turn was cut off. The chat now runs on another machine, from its last \
                 saved copy: the files and git state are as of that copy, so the turn's last \
                 seconds of work may be missing, and processes you started (dev servers, \
                 watchers, background shells) did not come along: start again any that you \
                 still need."
            }
        }
    }
}

/// Auto mode: the tool call a takeover's snapshot says was running when the copy was taken
/// (the manifest's `openTurn.tool`). The log may have ended before the call shows in it.
///
/// Adds the call (its `name` and `args`) to a continuation's `text`, right after its opening
/// (`at` bytes in). The arguments are masked and cut as an unfinished tool's input is.
pub(super) fn tell_in_flight(text: &mut String, at: usize, name: &str, args: &str) {
    let name: String = name.chars().filter(|c| !c.is_control()).take(80).collect();
    let args: String = super::masked_scan(args).chars().take(super::MAX_TOOL_INPUT_CHARS).collect();
    let shown = if args.trim().is_empty() { String::new() } else { format!(" with input: {args}") };
    let told = format!(
        " The tool call running when the copy was taken was {name}{shown}. It may have finished, \
         partly run or not run at all."
    );
    text.insert_str(at.min(text.len()), &told);
}
